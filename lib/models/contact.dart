import 'dart:convert';
import 'dart:typed_data';

import '../services/identity_crypto.dart';

/// Someone you have paired with: their name and public key.
class Contact {
  final String name;
  final Uint8List pub;

  Contact({required this.name, required this.pub});

  /// 4-byte key id as 8 hex characters (also shown in the UI).
  String get idHex => IdentityCrypto.keyIdHex(pub);

  Contact withName(String newName) => Contact(name: newName, pub: pub);

  Map<String, dynamic> toJson() => {'name': name, 'pub': base64.encode(pub)};

  factory Contact.fromJson(Map<String, dynamic> j) => Contact(
        name: j['name'] as String,
        pub: Uint8List.fromList(base64.decode(j['pub'] as String)),
      );
}
