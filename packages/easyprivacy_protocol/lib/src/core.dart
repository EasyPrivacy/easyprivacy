String normalizeFingerprint(String value) {
  var text = value.replaceAll(RegExp(r'\s'), '');
  if (text.toUpperCase().startsWith('SHA256:')) text = text.substring(7);
  text = text.replaceAll(':', '').toUpperCase();
  if (!RegExp(r'^[0-9A-F]{64}$').hasMatch(text)) {
    throw const FormatException(
      'Copy the full SHA256 fingerprint from core setup.',
    );
  }
  return 'SHA256:$text';
}

class CoreAddress {
  const CoreAddress(this.host, this.port);
  final String host;
  final int port;

  factory CoreAddress.parse(String value) {
    final text = value.trim();
    final explicitScheme = text.contains('://');
    final uri = Uri.tryParse(explicitScheme ? text : 'https://$text');
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const FormatException(
        'Enter your core address, such as server.example:7444.',
      );
    }
    final port = uri.hasPort ? uri.port : (explicitScheme ? 443 : 7444);
    if (port < 1 || port > 65535) {
      throw const FormatException('Enter a port between 1 and 65535.');
    }
    return CoreAddress(uri.host, port);
  }

  Uri uri(String path) =>
      Uri(scheme: 'https', host: host, port: port, path: path);
  String get label => uri('/').authority;
}

class CoreException implements Exception {
  const CoreException(this.message, [this.statusCode]);
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}

class CoreStatus {
  const CoreStatus({
    required this.name,
    required this.version,
    required this.uptimeSeconds,
    required this.expiresAt,
  });
  final String name;
  final String version;
  final int uptimeSeconds;
  final DateTime expiresAt;
  factory CoreStatus.fromJson(Map<String, dynamic> value) {
    final name = value['core_name'];
    final version = value['version'];
    final uptime = value['uptime_seconds'];
    final expiry = DateTime.tryParse(
      value['session_expires_at']?.toString() ?? '',
    );
    if (name is! String ||
        name.isEmpty ||
        name.length > 80 ||
        version is! String ||
        uptime is! int ||
        uptime < 0 ||
        expiry == null) {
      throw const FormatException('The core returned an invalid status.');
    }
    return CoreStatus(
      name: name,
      version: version,
      uptimeSeconds: uptime,
      expiresAt: expiry,
    );
  }
}

class PairingCode {
  const PairingCode(this.code, this.expiresAt);
  final String code;
  final DateTime expiresAt;
  factory PairingCode.fromJson(Map<String, dynamic> value) {
    final code = value['code'],
        expires = DateTime.tryParse(value['expires_at']?.toString() ?? '');
    if (code is! String ||
        !RegExp(r'^[0-9]{8}$').hasMatch(code) ||
        expires == null) {
      throw const FormatException('The core returned an invalid pairing code.');
    }
    return PairingCode(code, expires);
  }
}

class PairedDevice {
  const PairedDevice(this.id, this.name, this.revoked);
  final String id, name;
  final bool revoked;
  factory PairedDevice.fromJson(Map<String, dynamic> value) {
    final id = value['id'], name = value['name'], revoked = value['revoked'];
    if (id is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(id) ||
        name is! String ||
        name.isEmpty ||
        name.length > 80 ||
        revoked is! bool) {
      throw const FormatException('The core returned an invalid device list.');
    }
    return PairedDevice(id, name, revoked);
  }
}
