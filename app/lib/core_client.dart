import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'device_identity.dart';
import 'vpn_types.dart';

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

abstract interface class NodeClient {
  Future<String> signIn(String username, String password);
  Future<CoreStatus> status(String token);
  Future<void> signOut(String token);
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

abstract interface class DeviceNodeClient implements NodeClient {
  Future<String> signInDevice(DeviceIdentity identity);
  Future<PairingCode> createPairingCode(String token);
  Future<List<PairedDevice>> devices(String token);
  Future<void> revokeDevice(String token, String deviceId);
}

class CoreClient implements DeviceNodeClient, VPNNodeClient {
  CoreClient(this.address, String fingerprint)
    : fingerprint = normalizeFingerprint(fingerprint);
  final CoreAddress address;
  final String fingerprint;
  @override
  Future<List<VPNExit>> vpnExits(String token) async {
    final result = await _request('GET', '/api/v1/vpn/exits', token: token);
    return (result['exits'] as List)
        .map((v) => VPNExit.fromJson(v as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<VPNProfile> vpnRegister(
    String token,
    String exit,
    String publicKey,
  ) async => VPNProfile.fromJson(
    await _request(
      'POST',
      '/api/v1/vpn/peer',
      token: token,
      body: {'exit_id': exit, 'public_key': publicKey},
    ),
  );
  @override
  Future<void> vpnDisconnect(String token) async {
    await _request('POST', '/api/v1/vpn/disconnect', token: token);
  }

  @override
  Future<TunnelStatus> vpnStatus(String token) async => TunnelStatus.fromJson(
    await _request('GET', '/api/v1/vpn/status', token: token),
  );

  @override
  Future<String> signInDevice(DeviceIdentity identity) async {
    final challenge = await _request(
      'POST',
      '/api/v1/device/challenge',
      body: {'device_id': identity.id},
    );
    final id = challenge['challenge_id'];
    if (id is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(id)) {
      throw const FormatException(
        'The core returned an invalid device challenge.',
      );
    }
    final signature = await identity.sign(
      'easyprivacy.device-login.v1\n$fingerprint\n${identity.id}\n$id',
    );
    final value = await _request(
      'POST',
      '/api/v1/device/login',
      body: {
        'device_id': identity.id,
        'challenge_id': id,
        'signature': base64Encode(signature),
      },
    );
    final token = value['access_token'];
    if (token is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(token)) {
      throw const FormatException('The core returned an invalid session.');
    }
    return token;
  }

  @override
  Future<PairingCode> createPairingCode(String token) async =>
      PairingCode.fromJson(
        await _request('POST', '/api/v1/pairing/code', token: token),
      );

  Future<void> enrollDevice(
    String exchangeId,
    List<int> proof,
    String deviceId,
    String username,
    String password,
  ) async {
    final result = await _request(
      'POST',
      '/api/v1/pairing/enroll',
      body: {
        'exchange_id': exchangeId,
        'proof': base64Encode(proof),
        'username': username,
        'password': password,
      },
    );
    if (result['device_id'] != deviceId) {
      throw const FormatException(
        'The core returned an invalid enrollment result.',
      );
    }
  }

  @override
  Future<List<PairedDevice>> devices(String token) async {
    final result = await _request('GET', '/api/v1/devices', token: token);
    final list = result['devices'];
    if (list is! List || list.length > 128) {
      throw const FormatException('Invalid device list.');
    }
    return list
        .map((value) => PairedDevice.fromJson(value as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<void> revokeDevice(String token, String deviceId) async {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(deviceId)) {
      throw const FormatException('Invalid device identity.');
    }
    final result = await _request(
      'POST',
      '/api/v1/devices/$deviceId/revoke',
      token: token,
    );
    if (result['warning'] is String) {
      throw CoreException(result['warning'] as String);
    }
  }

  bool _matches(X509Certificate cert) {
    final now = DateTime.now();
    final actual =
        'SHA256:${sha256.convert(cert.der).toString().toUpperCase()}';
    return actual == fingerprint &&
        !now.isBefore(cert.startValidity) &&
        now.isBefore(cert.endValidity);
  }

  @override
  Future<String> signIn(String username, String password) async {
    final value = await _request(
      'POST',
      '/api/v1/login',
      body: {'username': username, 'password': password},
    );
    final token = value['access_token'];
    if (token is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(token)) {
      throw const FormatException('The core returned an invalid session.');
    }
    return token;
  }

  @override
  Future<CoreStatus> status(String token) async => CoreStatus.fromJson(
    await _request('GET', '/api/v1/status', token: token),
  );

  @override
  Future<void> signOut(String token) async {
    await _request('POST', '/api/v1/logout', token: token);
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, Object?>? body,
    String? token,
  }) async {
    final context = SecurityContext(withTrustedRoots: false)
      ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3;
    final client = HttpClient(context: context);
    client.connectionTimeout = const Duration(seconds: 8);
    client.findProxy = (_) => 'DIRECT';
    client.badCertificateCallback = (cert, host, port) =>
        host.toLowerCase() == address.host.toLowerCase() &&
        port == address.port &&
        _matches(cert);
    try {
      return await (() async {
        // The pinned TLS handshake completes before any credentials are sent.
        final request = await client.openUrl(method, address.uri(path));
        request.followRedirects = false;
        if (token != null) {
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        }
        if (body != null) {
          request.headers.set(
            HttpHeaders.contentTypeHeader,
            'application/json',
          );
          request.write(jsonEncode(body));
        }
        final response = await request.close();
        final cert = response.certificate;
        if (cert == null || !_matches(cert)) {
          throw const CoreException(
            'The core identity does not match. Check its fingerprint in the setup terminal.',
          );
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 65536) {
            throw const CoreException('The core response was too large.');
          }
          bytes.addAll(chunk);
        }
        if (response.statusCode == 404 && path.startsWith('/api/v1/vpn/')) {
          throw const CoreException(
            'Update your core package, then run sudo easyprivacy-node vpn-setup.',
            404,
          );
        }
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('The core returned an invalid response.');
        }
        if (response.statusCode != 200) {
          final error = decoded['error'];
          throw CoreException(
            error is String && error.length < 300
                ? error
                : 'The core rejected the request.',
            response.statusCode,
          );
        }
        return decoded;
      })().timeout(const Duration(seconds: 12));
    } on HandshakeException {
      throw const CoreException(
        'Could not verify the core identity. Check its fingerprint and the device clock.',
      );
    } on SocketException {
      throw const CoreException(
        'Could not reach the core. Check its address, port, and firewall.',
      );
    } on TimeoutException {
      throw const CoreException('The core did not respond in time.');
    } finally {
      client.close(force: true);
    }
  }
}
