import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';

class VPNExit {
  const VPNExit(this.id, this.name, this.ready, this.message);
  final String id, name, message;
  final bool ready;
  factory VPNExit.fromJson(Map<String, dynamic> v) {
    if (v['id'] is! String || v['name'] is! String || v['ready'] is! bool) {
      throw const FormatException('Invalid VPN exit.');
    }
    return VPNExit(
      v['id'] as String,
      v['name'] as String,
      v['ready'] as bool,
      v['message'] as String? ?? '',
    );
  }
}

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

class VPNProfile {
  VPNProfile.fromJson(Map<String, dynamic> v)
    : exitId = v['exit_id'] as String,
      exitName = v['exit_name'] as String,
      publicKey = v['public_key'] as String,
      endpoint = v['endpoint'] as String,
      address = v['address'] as String,
      addressV6 = v['address_v6'] as String,
      dns = List<String>.from(v['dns'] as List),
      mtu = v['mtu'] as int,
      keepalive = v['keepalive'] as int {
    managementRoutes = List<String>.from(
      v['management_routes'] as List? ?? const [],
    );
    if (managementRoutes.length > 16 ||
        managementRoutes.toSet().length != managementRoutes.length ||
        managementRoutes.any((route) {
          final parts = route.split('/');
          final ip = InternetAddress.tryParse(parts.first);
          if (parts.length != 2 ||
              parts.last != '32' ||
              ip?.type != InternetAddressType.IPv4) {
            return true;
          }
          final bytes = ip!.rawAddress;
          return !(bytes[0] == 10 ||
              (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
              (bytes[0] == 192 && bytes[1] == 168));
        })) {
      throw const FormatException('Invalid home management routes.');
    }
    final parsed = Uri.tryParse('https://$endpoint');
    if (base64Decode(publicKey).length != 32 ||
        parsed == null ||
        parsed.host.isEmpty ||
        parsed.userInfo.isNotEmpty ||
        parsed.path.isNotEmpty ||
        !parsed.hasPort ||
        parsed.port < 1 ||
        parsed.port > 65535 ||
        !address.endsWith('/32') ||
        InternetAddress.tryParse(address.split('/').first)?.type !=
            InternetAddressType.IPv4 ||
        !addressV6.endsWith('/128') ||
        InternetAddress.tryParse(addressV6.split('/').first)?.type !=
            InternetAddressType.IPv6 ||
        dns.isEmpty ||
        dns.length > 3 ||
        dns.any(
          (a) => InternetAddress.tryParse(a)?.type != InternetAddressType.IPv4,
        ) ||
        mtu != 1280 ||
        keepalive != 25 ||
        jsonEncode(v['allowed_ips']) != jsonEncode(['0.0.0.0/0', '::/0'])) {
      throw const FormatException('The core returned an invalid VPN profile.');
    }
  }
  final String exitId, exitName, publicKey, endpoint, address, addressV6;
  final List<String> dns;
  late final List<String> managementRoutes;
  final int mtu, keepalive;
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

class TunnelStatus {
  const TunnelStatus({
    this.installed = true,
    this.active = false,
    this.handshake = 0,
    this.received = 0,
    this.sent = 0,
  });
  final bool installed, active;
  final int handshake, received, sent;
  factory TunnelStatus.fromJson(Map<String, dynamic> v) => TunnelStatus(
    installed: v['installed'] as bool? ?? true,
    active: v['active'] as bool? ?? false,
    handshake: (v['last_handshake'] as num?)?.toInt() ?? 0,
    received: (v['received'] as num?)?.toInt() ?? 0,
    sent: (v['sent'] as num?)?.toInt() ?? 0,
  );
  bool get hasRecentHandshake =>
      handshake > 0 &&
      DateTime.now().millisecondsSinceEpoch ~/ 1000 - handshake < 180;
}

abstract interface class VPNNodeClient {
  Future<List<VPNExit>> vpnExits(String token);
  Future<VPNProfile> vpnRegister(String token, String exit, String publicKey);
  Future<void> vpnDisconnect(String token);
  Future<TunnelStatus> vpnStatus(String token);
}
