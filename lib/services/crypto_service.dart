import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Message encryption compatible with the Bun-1 Communicator firmware:
/// AES-256-CBC, fixed IV, PKCS#7 padding, ciphertext sent as lowercase hex.
///
/// The IV is fixed (same as in the old firmware, so boards and apps stay
/// interoperable). That makes the same message always produce the same
/// ciphertext and gives no integrity protection - fine for a hobby link,
/// not for anything serious.
class MessageCrypto {
  MessageCrypto._();

  /// Public default key from the old firmware. Not secret - change it.
  static const defaultKeyHex =
      '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';

  static final Uint8List _iv = Uint8List.fromList(const [
    0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x11,
    0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99,
  ]);

  /// Longest plaintext (in UTF-8 bytes) that still fits in one LoRa packet:
  /// 111 bytes -> 112 bytes padded -> 224 hex characters (LoRa limit is 255).
  static const maxPlainBytes = 111;

  /// Returns an error message, or null if [hex] is a valid AES-256 key
  /// (exactly 64 hex characters).
  static String? validateKey(String hex) {
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hex.trim())) {
      return 'Need exactly 64 hex characters (0-9, a-f)';
    }
    return null;
  }

  /// Random AES-256 key as 64 hex characters.
  static String generateKey() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(32, (_) => rnd.nextInt(256));
    return _toHex(bytes);
  }

  /// Encrypts [text] and returns the ciphertext as lowercase hex.
  /// Throws a [String] message if [keyHex] is invalid or [text] is too long.
  static String encrypt(String text, String keyHex) {
    final keyError = validateKey(keyHex);
    if (keyError != null) throw keyError;

    final plain = utf8.encode(text);
    if (plain.length > maxPlainBytes) {
      throw 'Message too long (${plain.length} bytes, max $maxPlainBytes)';
    }
    return _toHex(_run(true, _fromHex(keyHex.trim()), Uint8List.fromList(plain)));
  }

  /// Decrypts a hex ciphertext. Returns null if it is not valid ciphertext
  /// for [keyHex] (wrong key, damaged packet, or not encrypted at all).
  static String? decrypt(String hexCipher, String keyHex) {
    try {
      final hex = hexCipher.trim();
      if (validateKey(keyHex) != null) return null;
      if (hex.isEmpty ||
          hex.length % 32 != 0 ||
          !RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) {
        return null;
      }
      final plain = _run(false, _fromHex(keyHex.trim()), _fromHex(hex));
      // A wrong key can still produce valid padding by chance (about 1 in
      // 256); random bytes are almost never valid UTF-8, so this catches it.
      return utf8.decode(plain, allowMalformed: false);
    } catch (_) {
      return null;
    }
  }

  static Uint8List _run(bool encrypt, Uint8List key, Uint8List data) {
    final cipher = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
      ..init(
        encrypt,
        PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
          ParametersWithIV<KeyParameter>(KeyParameter(key), _iv),
          null,
        ),
      );
    return cipher.process(data);
  }

  static String _toHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _fromHex(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}
