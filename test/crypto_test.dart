import 'package:flutter_test/flutter_test.dart';
import 'package:bun1_app/services/crypto_service.dart';

// Reference values: AES-256-CBC, default key, IV AABBCCDDEEFF00112233445566778899,
// PKCS#7 padding, lowercase hex - the format of the Bun-1 Communicator firmware.
void main() {
  const key = MessageCrypto.defaultKeyHex;

  test('matches firmware ciphertext for known messages', () {
    expect(MessageCrypto.encrypt('Hello', key),
        '08bc16fbc97c6e39e2b074800cc91daf');
    expect(MessageCrypto.encrypt('a' * 16, key),
        '20038b45506c11fe9e15578bd4dbcef2e97861494f3ac2382395f36b16e6d506');
    expect(MessageCrypto.encrypt('Zażółć gęślą', key),
        'c210c2ee6f0601534c323d06cd0f67eb82c571c1b1131e458fce33068dab7390');
  });

  test('different key gives different ciphertext', () {
    expect(MessageCrypto.encrypt('Hello', 'ff' * 32),
        'd266fabf07dc9d47298ec2235c721641');
  });

  test('decrypt round trip, including the longest message', () {
    for (final s in ['Hello', 'Zażółć gęślą', 'x' * 111]) {
      expect(MessageCrypto.decrypt(MessageCrypto.encrypt(s, key), key), s);
    }
  });

  test('rejects too long messages and bad keys', () {
    expect(() => MessageCrypto.encrypt('x' * 112, key), throwsA(isA<String>()));
    expect(() => MessageCrypto.encrypt('Hello', 'abc'), throwsA(isA<String>()));
  });

  test('decrypt returns null for wrong key or garbage', () {
    final c = MessageCrypto.encrypt('Hello', key);
    expect(MessageCrypto.decrypt(c, 'ff' * 32), isNull);
    expect(MessageCrypto.decrypt('not hex', key), isNull);
    expect(MessageCrypto.decrypt('', key), isNull);
    expect(MessageCrypto.decrypt('abcd', key), isNull);
  });

  test('generated key is valid', () {
    expect(MessageCrypto.validateKey(MessageCrypto.generateKey()), isNull);
  });
}
