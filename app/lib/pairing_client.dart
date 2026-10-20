import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'core_client.dart';
import 'device_identity.dart';
import 'native_pake.dart';

String normalizePairingCode(String text) {
  final code = text.replaceAll(RegExp(r'[\s-]'), '');
  if (!RegExp(r'^[0-9]{8}$').hasMatch(code)) {
    throw const FormatException('Enter the eight-digit pairing code.');
  }
  return code;
}

class VerifiedCore {
  const VerifiedCore(
    this.fingerprint,
    this.identity, {
    required this.address,
    required this.exchangeId,
    required this.enrollmentProof,
    required this.expiresAt,
  });
  final String fingerprint;
  final DeviceIdentity identity;
  final CoreAddress address;
  final String exchangeId;
  final List<int> enrollmentProof;
  final DateTime expiresAt;
  void clear() => enrollmentProof.fillRange(0, enrollmentProof.length, 0);
}

Future<void> enrollVerifiedCore(
  VerifiedCore core,
  String username,
  String password,
) => CoreClient(core.address, core.fingerprint).enrollDevice(
  core.exchangeId,
  core.enrollmentProof,
  core.identity.id,
  username,
  password,
);

List<int> _mac(List<int> key, String role, List<int> context, String id) =>
    Hmac(sha256, key).convert([
      ...utf8.encode('easyprivacy.pairing.v2.$role\n'),
      ...context,
      ...utf8.encode('\n$id'),
    ]).bytes;
bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var different = 0;
  for (var i = 0; i < a.length; i++) {
    different |= a[i] ^ b[i];
  }
  return different == 0;
}

Future<VerifiedCore> pairCore(
  CoreAddress address,
  String rawCode,
  String name,
) async {
  final code = normalizePairingCode(rawCode);
  if (name.trim().isEmpty ||
      utf8.encode(name).length > 80 ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) {
    throw const FormatException('Enter a device name of at most 80 bytes.');
  }
  final identity = await DeviceIdentity.create();
  final start = await _pairingRequest(address, _PairingPhase.start, {
    'target': address.label,
    'device_name': name,
    'public_key': base64Encode(identity.publicKey),
  });
  if (start['protocol'] != 'easyprivacy.pairing.v2') {
    throw const CoreException(
      'Upgrade the core package before enrolling this device.',
    );
  }
  final id = start['exchange_id'];
  if (id is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(id)) {
    throw const FormatException('Invalid pairing exchange.');
  }
  final fingerprint = normalizeFingerprint(start['core_fingerprint'] as String);
  final peer = base64Decode(start['message'] as String);
  final context = sha256
      .convert(
        utf8.encode(
          'easyprivacy.pairing.v2\n$id\n${address.label}\n$name\n${base64Encode(identity.publicKey)}\n$fingerprint',
        ),
      )
      .bytes;
  final exchange = NativePake(code, context);
  List<int>? key;
  try {
    key = exchange.finish(peer);
    final result = await _pairingRequest(address, _PairingPhase.finish, {
      'exchange_id': id,
      'message': base64Encode(exchange.message),
      'proof': base64Encode(_mac(key, 'app', context, identity.id)),
    });
    final proof = base64Decode(result['proof'] as String);
    if (result['device_id'] != identity.id ||
        !_equal(proof, _mac(key, 'core', context, identity.id))) {
      throw const CoreException(
        'Could not verify the core during pairing. No core identity was saved.',
      );
    }
    final expiry = DateTime.tryParse(result['expires_at']?.toString() ?? '');
    if (expiry == null) {
      throw const FormatException('Invalid verification expiry.');
    }
    // No device has been enrolled and no profile may be saved yet. The proof
    // stays in memory and is sent only over a new, fingerprint-pinned TLS connection.
    return VerifiedCore(
      fingerprint,
      identity,
      address: address,
      exchangeId: id,
      enrollmentProof: _mac(key, 'enroll', context, identity.id),
      expiresAt: expiry,
    );
  } finally {
    key?.fillRange(0, key.length, 0);
    exchange.close();
  }
}

enum _PairingPhase { start, finish }

// Provisional TLS is scoped to these two PAKE-only endpoints. This transport
// has no password, pairing-code or bearer-token field, never follows redirects,
// and never establishes trust from the certificate presented by the network.
Future<Map<String, dynamic>> _pairingRequest(
  CoreAddress address,
  _PairingPhase phase,
  Map<String, Object> body,
) async {
  final security = SecurityContext(withTrustedRoots: false)
    ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3;
  final client = HttpClient(context: security)
    ..connectionTimeout = const Duration(seconds: 8);
  client.findProxy = (_) => 'DIRECT';
  client.badCertificateCallback = (_, host, port) =>
      host.toLowerCase() == address.host.toLowerCase() && port == address.port;
  try {
    return await (() async {
      final request = await client.postUrl(
        address.uri('/api/v1/pairing/${phase.name}'),
      );
      request.followRedirects = false;
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.write(jsonEncode(body));
      final response = await request.close();
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > 16384) {
          throw const CoreException('The pairing response was too large.');
        }
        bytes.addAll(chunk);
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid pairing response.');
      }
      if (response.statusCode != 200) {
        throw CoreException(switch (response.statusCode) {
          401 => 'Pairing failed. Check the code or create a new one.',
          429 =>
            'Pairing attempts are limited. Wait briefly or create a new code.',
          404 =>
            'This core does not support device pairing. Upgrade the core package first.',
          _ => 'The core could not complete pairing. Try a new code.',
        }, response.statusCode);
      }
      return decoded;
    })().timeout(const Duration(seconds: 12));
  } on SocketException {
    throw const CoreException(
      'Could not reach the core. Check its address, port, and firewall.',
    );
  } on HandshakeException {
    throw const CoreException(
      'Could not establish the encrypted pairing connection.',
    );
  } on TimeoutException {
    throw const CoreException('The core did not respond in time.');
  } finally {
    client.close(force: true);
  }
}
