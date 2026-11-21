import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:pointycastle/export.dart' show SHA256Digest;

/// A parsed "hello" packet from a device that is pairing.
class Hello {
  final Uint8List pub;
  final String name;
  const Hello(this.pub, this.name);
}

/// Header of an encrypted message, readable without any key.
class DirectPacket {
  final Uint8List raw;
  const DirectPacket(this.raw);

  Uint8List get senderId => Uint8List.sublistView(raw, 1, 5);
  Uint8List get recipientId => Uint8List.sublistView(raw, 5, 9);
}

/// A decrypted message.
class DirectMessage {
  final String name;
  final String text;
  const DirectMessage(this.name, this.text);
}

/// Account-based encryption.
///
/// * Every user has an X25519 key pair; the public key is their identity.
/// * Two users pair once (see [sas]); from then on both derive the same
///   AES-256 key from X25519 + HKDF-SHA256 and use AES-GCM with a random
///   nonce for every message.
///
/// Packets are plain text so the board can forward them as before:
///   `#H<base64>`  hello:   [1][pub 32][name utf8]
///   `#M<base64>`  message: [2][senderId 4][recipientId 4][nonce 12][cipher][tag 16]
/// where the ids are the first 4 bytes of SHA-256(public key) and the
/// header (first 9 bytes) is authenticated. The plaintext is
/// [nameLen 1][name][text], so the receiver always sees the sender's
/// current username.
class IdentityCrypto {
  IdentityCrypto._();

  static final _x25519 = X25519();
  static final _aes = AesGcm.with256bits();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static final Uint8List _info = Uint8List.fromList(utf8.encode('bun1-msg-v1'));

  static const maxNameBytes = 16;

  /// Largest binary packet that fits in the board's 224-character limit
  /// once base64-encoded and prefixed with "#M" (222 chars).
  static const _maxPacketBytes = 165;
  static const _overhead = 1 + 4 + 4 + 12 + 16;
  static const _maxPlain = _maxPacketBytes - _overhead; // 128

  // ── Names ──────────────────────────────────────────────────────────────────

  /// Returns an error message, or null if [name] is an acceptable username.
  static String? validateName(String name) {
    final n = name.trim();
    if (n.isEmpty) return 'Name cannot be empty';
    if (utf8.encode(n).length > maxNameBytes) {
      return 'Max $maxNameBytes bytes (fewer for non-ASCII letters)';
    }
    if (n.runes.any((r) => r < 0x20 || r == 0x7f)) {
      return 'No control characters';
    }
    return null;
  }

  /// Longest text (UTF-8 bytes) that fits in one message from [name].
  static int maxTextBytes(String name) =>
      _maxPlain - 1 - utf8.encode(name.trim()).length;

  // ── Keys and ids ───────────────────────────────────────────────────────────

  static Uint8List _randomBytes(int n) {
    final rnd = Random.secure();
    return Uint8List.fromList(List<int>.generate(n, (_) => rnd.nextInt(256)));
  }

  /// New private key (32 random bytes). This is all that needs to be stored.
  static Uint8List generateSeed() => _randomBytes(32);

  static Future<Uint8List> publicKey(Uint8List seed) async {
    final pair = await _x25519.newKeyPairFromSeed(seed);
    final pub = await pair.extractPublicKey();
    return Uint8List.fromList(pub.bytes);
  }

  static Uint8List _sha256(List<int> data) =>
      SHA256Digest().process(Uint8List.fromList(data));

  /// 4-byte id of a public key, sent in message headers.
  static Uint8List keyId(Uint8List pub) =>
      Uint8List.sublistView(_sha256(pub), 0, 4);

  static String keyIdHex(Uint8List pub) => _hex(keyId(pub));

  static bool sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static int _compare(List<int> a, List<int> b) {
    final n = min(a.length, b.length);
    for (var i = 0; i < n; i++) {
      if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
    }
    return a.length.compareTo(b.length);
  }

  /// Both public keys in a fixed order, so both sides get identical bytes.
  static List<int> _sortedPair(Uint8List a, Uint8List b) =>
      _compare(a, b) <= 0 ? [...a, ...b] : [...b, ...a];

  /// 4-digit code derived from both public keys. Both devices show the same
  /// code, and people compare it before confirming. It protects against
  /// someone in radio range swapping the keys during pairing - but 4 digits
  /// is only a modest barrier, so pair with people you can see.
  static String sas(Uint8List a, Uint8List b) {
    final d = _sha256(_sortedPair(a, b));
    final n = (d[0] << 24) | (d[1] << 16) | (d[2] << 8) | d[3];
    return (n % 10000).toString().padLeft(4, '0');
  }

  // ── Hello packets (pairing) ────────────────────────────────────────────────

  static String helloPayload(Uint8List pub, String name) =>
      '#H${base64.encode([1, ...pub, ...utf8.encode(name.trim())])}';

  static Hello? parseHello(String payload) {
    try {
      if (!payload.startsWith('#H')) return null;
      final b = base64.decode(payload.substring(2));
      if (b.length < 33 || b[0] != 1) return null;
      return Hello(
        Uint8List.fromList(b.sublist(1, 33)),
        utf8.decode(b.sublist(33), allowMalformed: true),
      );
    } catch (_) {
      return null;
    }
  }

  // ── Messages ───────────────────────────────────────────────────────────────

  static Future<SecretKey> _deriveKey(
      Uint8List seed, Uint8List myPub, Uint8List theirPub) async {
    final pair = await _x25519.newKeyPairFromSeed(seed);
    final secret = await _x25519.sharedSecretKey(
      keyPair: pair,
      remotePublicKey: SimplePublicKey(theirPub, type: KeyPairType.x25519),
    );
    return _hkdf.deriveKey(
      secretKey: secret,
      nonce: _sortedPair(myPub, theirPub),
      info: _info,
    );
  }

  /// Encrypts [text] for the owner of [theirPub]. Returns the `#M...` line.
  /// Throws a [String] message if the text is too long. [nonce] is only for
  /// tests; leave it out so a random one is used.
  static Future<String> encryptMessage({
    required Uint8List seed,
    required Uint8List myPub,
    required Uint8List theirPub,
    required String name,
    required String text,
    List<int>? nonce,
  }) async {
    final nameBytes = utf8.encode(name.trim());
    final textBytes = utf8.encode(text);
    final limit = maxTextBytes(name);
    if (textBytes.length > limit) {
      throw 'Message too long (${textBytes.length} bytes, max $limit)';
    }

    final plain =
        Uint8List.fromList([nameBytes.length, ...nameBytes, ...textBytes]);
    final header =
        Uint8List.fromList([2, ...keyId(myPub), ...keyId(theirPub)]);
    final n = nonce ?? _randomBytes(12);
    final key = await _deriveKey(seed, myPub, theirPub);
    final box = await _aes.encrypt(plain, secretKey: key, nonce: n, aad: header);

    final out = BytesBuilder()
      ..add(header)
      ..add(n)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return '#M${base64.encode(out.toBytes())}';
  }

  /// Parses the header of a `#M...` line. Returns null if it is malformed.
  static DirectPacket? parseMessage(String payload) {
    try {
      if (!payload.startsWith('#M')) return null;
      final b = base64.decode(payload.substring(2));
      if (b.length < 9 + 12 + 1 + 16 || b[0] != 2) return null;
      return DirectPacket(Uint8List.fromList(b));
    } catch (_) {
      return null;
    }
  }

  /// Decrypts [packet] sent by the owner of [theirPub]. Returns null if the
  /// packet was not authentic (wrong sender key or damaged).
  static Future<DirectMessage?> decryptMessage({
    required Uint8List seed,
    required Uint8List myPub,
    required Uint8List theirPub,
    required DirectPacket packet,
  }) async {
    try {
      final raw = packet.raw;
      final header = raw.sublist(0, 9);
      final nonce = raw.sublist(9, 21);
      final cipher = raw.sublist(21, raw.length - 16);
      final tag = raw.sublist(raw.length - 16);

      final key = await _deriveKey(seed, myPub, theirPub);
      final plain = await _aes.decrypt(
        SecretBox(cipher, nonce: nonce, mac: Mac(tag)),
        secretKey: key,
        aad: header,
      );
      if (plain.isEmpty) return null;
      final nameLen = plain[0];
      if (1 + nameLen > plain.length) return null;
      return DirectMessage(
        utf8.decode(plain.sublist(1, 1 + nameLen)),
        utf8.decode(plain.sublist(1 + nameLen)),
      );
    } catch (_) {
      return null;
    }
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
