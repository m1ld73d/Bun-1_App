import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:bun1_app/services/identity_crypto.dart';

String hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

// Reference values come from an independent implementation of the same
// protocol (Python, "cryptography" package): X25519 + HKDF-SHA256 + AES-GCM.
void main() {
  final seedA = Uint8List.fromList(List.filled(32, 1));
  final seedB = Uint8List.fromList(List.filled(32, 2));
  final seedC = Uint8List.fromList(List.filled(32, 3));
  final nonce = List<int>.generate(12, (i) => i);
  late Uint8List pubA, pubB, pubC;

  setUpAll(() async {
    pubA = await IdentityCrypto.publicKey(seedA);
    pubB = await IdentityCrypto.publicKey(seedB);
    pubC = await IdentityCrypto.publicKey(seedC);
  });

  test('public keys, ids and pairing code match the reference', () {
    expect(hex(pubA),
        'a4e09292b651c278b9772c569f5fa9bb13d906b46ab68c9df9dc2b4409f8a209');
    expect(hex(pubB),
        'ce8d3ad1ccb633ec7b70c17814a5c76ecd029685050d344745ba05870e587d59');
    expect(IdentityCrypto.keyIdHex(pubA), '1a92f238');
    expect(IdentityCrypto.keyIdHex(pubB), 'cfa570c6');
    expect(IdentityCrypto.sas(pubA, pubB), '4539');
    expect(IdentityCrypto.sas(pubB, pubA), '4539');
  });

  test('hello packet matches the reference and parses back', () {
    final p = IdentityCrypto.helloPayload(pubA, 'Ala');
    expect(p, '#HAaTgkpK2UcJ4uXcsVp9fqbsT2Qa0araMnfncK0QJ+KIJQWxh');
    final h = IdentityCrypto.parseHello(p)!;
    expect(h.name, 'Ala');
    expect(hex(h.pub), hex(pubA));
  });

  test('message packet matches the reference', () async {
    final m = await IdentityCrypto.encryptMessage(
      seed: seedA,
      myPub: pubA,
      theirPub: pubB,
      name: 'Ala',
      text: 'Hello',
      nonce: nonce,
    );
    expect(m,
        '#MAhqS8jjPpXDGAAECAwQFBgcICQoLTvFjheNuU2WNE3mMGaaDf0F4yHzi03+Qrw==');
  });

  test('receiver decrypts and sees header ids', () async {
    final m = await IdentityCrypto.encryptMessage(
      seed: seedA,
      myPub: pubA,
      theirPub: pubB,
      name: 'Ala',
      text: 'Zażółć gęślą',
    );
    final packet = IdentityCrypto.parseMessage(m)!;
    expect(hex(packet.senderId), '1a92f238');
    expect(hex(packet.recipientId), 'cfa570c6');

    final r = await IdentityCrypto.decryptMessage(
        seed: seedB, myPub: pubB, theirPub: pubA, packet: packet);
    expect(r?.name, 'Ala');
    expect(r?.text, 'Zażółć gęślą');
  });

  test('wrong sender key or tampering is rejected', () async {
    final m = await IdentityCrypto.encryptMessage(
      seed: seedA,
      myPub: pubA,
      theirPub: pubB,
      name: 'Ala',
      text: 'Hello',
    );
    final packet = IdentityCrypto.parseMessage(m)!;

    final wrong = await IdentityCrypto.decryptMessage(
        seed: seedB, myPub: pubB, theirPub: pubC, packet: packet);
    expect(wrong, isNull);

    final damaged = Uint8List.fromList(packet.raw)..[20] ^= 1;
    final tampered = await IdentityCrypto.decryptMessage(
        seed: seedB, myPub: pubB, theirPub: pubA, packet: DirectPacket(damaged));
    expect(tampered, isNull);
  });

  test('longest message fits the 224 character limit', () async {
    final name = 'x' * 16;
    final max = IdentityCrypto.maxTextBytes(name);
    expect(max, 111);
    final m = await IdentityCrypto.encryptMessage(
      seed: seedA,
      myPub: pubA,
      theirPub: pubB,
      name: name,
      text: 'y' * max,
    );
    expect(m.length, lessThanOrEqualTo(224));
    expect(
      () => IdentityCrypto.encryptMessage(
        seed: seedA,
        myPub: pubA,
        theirPub: pubB,
        name: name,
        text: 'y' * (max + 1),
      ),
      throwsA(isA<String>()),
    );
  });

  test('username validation', () {
    expect(IdentityCrypto.validateName('Ala'), isNull);
    expect(IdentityCrypto.validateName('   '), isNotNull);
    expect(IdentityCrypto.validateName('x' * 17), isNotNull);
  });
}
