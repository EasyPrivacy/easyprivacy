export 'vpn_node_client.dart';
export 'package:easyprivacy_protocol/easyprivacy_protocol.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:easyprivacy_core/runtime/identity/device_identity.dart';
import 'package:easyprivacy_protocol/easyprivacy_protocol.dart';
import 'package:easyprivacy_vpn_feature/easyprivacy_vpn.dart';
import 'package:easyprivacy_core/runtime/api/vpn_node_client.dart';
import 'private_node_client.dart';

abstract interface class NodeClient {
  Future<String> signIn(String username, String password);
  Future<CoreStatus> status(String token);
  Future<void> signOut(String token);
}

abstract interface class DeviceNodeClient implements NodeClient {
  Future<String> signInDevice(DeviceIdentity identity);
  Future<PairingCode> createPairingCode(String token);
  Future<List<PairedDevice>> devices(String token);
  Future<void> revokeDevice(String token, String deviceId);
}

class CoreClient implements DeviceNodeClient, VPNNodeClient, PrivateNodeClient {
  CoreClient(this.address, String fingerprint)
    : fingerprint = normalizeFingerprint(fingerprint);
  final CoreAddress address;
  final String fingerprint;
  @override
  Future<PrivateNetworkProfile> privateRegister(
    String token,
    String publicKey,
  ) async => PrivateNetworkProfile.fromJson(
    await _request(
      'POST',
      '/api/v2/network/private/peer',
      token: token,
      body: {'public_key': publicKey},
    ),
  );
  @override
  Future<void> privateDisconnect(String token) async {
    await _request('POST', '/api/v2/network/private/disconnect', token: token);
  }

  @override
  Future<List<PrivateServiceTarget>> privateServices(String token) async {
    final value = await _request(
      'GET',
      '/api/v2/network/private/services',
      token: token,
    );
    if (value['protocol'] != 1 ||
        value['services'] is! List ||
        (value['services'] as List).length > 17) {
      throw const FormatException('Invalid private services response.');
    }
    return (value['services'] as List)
        .map(
          (v) => PrivateServiceTarget.fromJson(
            Map<String, dynamic>.from(v as Map),
          ),
        )
        .toList();
  }

  @override
  Future<PrivateServiceTarget> privateReceiver(String token) async =>
      PrivateServiceTarget.fromJson(
        await _request(
          'POST',
          '/api/v2/network/private/receiver',
          token: token,
          body: {'capability': 'files'},
        ),
      );
  @override
  Future<void> privateReceiverDisconnect(String token) async {
    await _request(
      'POST',
      '/api/v2/network/private/receiver/disconnect',
      token: token,
    );
  }

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
        if (response.statusCode == 404 && path.startsWith('/api/v2/network/')) {
          throw const CoreException(
            'Update the core node before enabling private-service connections.',
            404,
          );
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
