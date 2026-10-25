import 'dart:convert';
import 'dart:io';

bool _privateAddress(String text) {
  final ip = InternetAddress.tryParse(text);
  if (ip?.type != InternetAddressType.IPv4) return false;
  final b = ip!.rawAddress;
  return b[0] == 10 ||
      (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
      (b[0] == 192 && b[1] == 168);
}

class PrivateServiceTarget {
  PrivateServiceTarget.fromJson(Map<String, dynamic> value)
    : id = value['id'] as String,
      name = value['name'] as String? ?? 'Private service',
      deviceId = value['device_id'] as String?,
      kind =
          value['kind'] as String? ??
          (value['id'] == 'core.probe' ? 'probe' : 'files'),
      address = value['address'] as String,
      port = value['port'] as int,
      expiresAt = value['expires_at'] == null
          ? null
          : DateTime.parse(value['expires_at'] as String) {
    if (!_privateAddress(address) ||
        (id != 'core.probe' &&
            !RegExp(r'^receiver\.[0-9a-f]{32}$').hasMatch(id)) ||
        (id != 'core.probe' && expiresAt == null) ||
        (id == 'core.probe' ? port != 41930 : port != 41931) ||
        name.length > 160 ||
        !{'probe', 'files', 'drive'}.contains(kind) ||
        (id == 'core.probe' ? kind != 'probe' : kind == 'probe')) {
      throw const FormatException('Invalid private service destination.');
    }
  }
  final String id, name, address, kind;
  final String? deviceId;
  final int port;
  final DateTime? expiresAt;
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'address': address,
    'port': port,
    'kind': kind,
    if (deviceId != null) 'device_id': deviceId,
    if (expiresAt != null) 'expires_at': expiresAt!.toUtc().toIso8601String(),
  };
}

class PrivateNetworkProfile {
  PrivateNetworkProfile.fromJson(Map<String, dynamic> value)
    : publicKey = value['public_key'] as String,
      endpoint = value['endpoint'] as String,
      address = value['address'] as String,
      subnet = value['subnet'] as String,
      probe = PrivateServiceTarget.fromJson(
        Map<String, dynamic>.from(value['probe'] as Map),
      ) {
    final addressParts = address.split('/'), subnetParts = subnet.split('/');
    final endpointUri = Uri.tryParse('https://$endpoint');
    if (value['protocol'] != 1 ||
        value['mtu'] != 1280 ||
        value['keepalive'] != 25 ||
        base64Decode(publicKey).length != 32 ||
        base64Decode(publicKey).every((b) => b == 0) ||
        addressParts.length != 2 ||
        addressParts[1] != '32' ||
        !_privateAddress(addressParts[0]) ||
        subnetParts.length != 2 ||
        subnetParts[1] != '24' ||
        !_privateAddress(subnetParts[0]) ||
        !subnetParts[0].endsWith('.0') ||
        !contains(addressParts[0]) ||
        !contains(probe.address) ||
        probe.id != 'core.probe' ||
        probe.address == addressParts[0] ||
        endpointUri == null ||
        endpointUri.host.isEmpty ||
        !endpointUri.hasPort ||
        endpointUri.port < 1 ||
        endpointUri.port > 65535 ||
        endpointUri.userInfo.isNotEmpty ||
        endpointUri.path.isNotEmpty ||
        endpointUri.query.isNotEmpty ||
        endpointUri.fragment.isNotEmpty) {
      throw const FormatException(
        'Update the core node for private-service connections.',
      );
    }
  }
  final String publicKey, endpoint, address, subnet;
  final PrivateServiceTarget probe;
  String get localAddress => address.split('/').first;
  bool contains(String target) =>
      _privateAddress(target) &&
      target.split('.').take(3).join('.') ==
          subnet.split('/').first.split('.').take(3).join('.');
  void validateTarget(PrivateServiceTarget target) {
    if (!contains(target.address) ||
        target.address == localAddress ||
        (target.expiresAt != null &&
            !DateTime.now().isBefore(target.expiresAt!))) {
      throw const FormatException(
        'Private service access has expired or is outside this core network.',
      );
    }
  }

  void validateTargetForReceiver(PrivateServiceTarget target) {
    if (!target.id.startsWith('receiver.') ||
        target.address != localAddress ||
        target.expiresAt == null ||
        !DateTime.now().isBefore(target.expiresAt!) ||
        target.expiresAt!.difference(DateTime.now()) >
            const Duration(minutes: 3)) {
      throw const FormatException('Invalid private receiver lease.');
    }
  }
}
