import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as cryptography;

class DeviceIdentity {
  DeviceIdentity._(this.encodedSeed, this.publicKey, this._keyPair);
  final String encodedSeed;
  final List<int> publicKey;
  final cryptography.SimpleKeyPair _keyPair;
  String get id => sha256.convert(publicKey).toString();
  static Future<DeviceIdentity> create() async {
    final pair = await cryptography.Ed25519().newKeyPair();
    return DeviceIdentity._(
      base64Encode(await pair.extractPrivateKeyBytes()),
      (await pair.extractPublicKey()).bytes,
      pair,
    );
  }

  static Future<DeviceIdentity> fromSeed(String seed) async {
    final bytes = base64Decode(seed);
    if (bytes.length != 32) {
      throw const FormatException('Invalid saved device key.');
    }
    final pair = await cryptography.Ed25519().newKeyPairFromSeed(bytes);
    return DeviceIdentity._(seed, (await pair.extractPublicKey()).bytes, pair);
  }

  Future<List<int>> sign(String message) async =>
      (await cryptography.Ed25519().sign(
        utf8.encode(message),
        keyPair: _keyPair,
      )).bytes;
}
