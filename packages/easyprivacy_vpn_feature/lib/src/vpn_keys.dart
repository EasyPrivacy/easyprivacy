import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:easyprivacy_protocol/easyprivacy_protocol.dart';

class VPNKey {
  const VPNKey(this.privateKey, this.publicKey);
  final String privateKey, publicKey;
  static Future<VPNKey> create() async {
    final pair = await X25519().newKeyPair();
    final bytes = List<int>.from(await pair.extractPrivateKeyBytes());
    bytes[0] &= 248;
    bytes[31] = (bytes[31] & 127) | 64;
    return fromPrivate(base64Encode(bytes));
  }

  static Future<VPNKey> fromPrivate(String text) async {
    final bytes = base64Decode(text);
    if (bytes.length != 32) {
      throw const FormatException('Invalid saved VPN key.');
    }
    final pair = await X25519().newKeyPairFromSeed(bytes);
    final pub = await pair.extractPublicKey();
    return VPNKey(text, base64Encode(pub.bytes));
  }
}

extension NativeVPNProfile on VPNProfile {
  Map<String, Object> nativeConfig(VPNKey key) => {
    'private_key': key.privateKey,
    'public_key': publicKey,
    'endpoint': endpoint,
    'address': address,
    'address_v6': addressV6,
    'dns': dns,
    'mtu': mtu,
    'keepalive': keepalive,
    'management_routes': managementRoutes,
  };
}
