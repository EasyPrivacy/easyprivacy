import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:easyprivacy_core/runtime/api/core_client.dart';
import 'package:easyprivacy_core/runtime/identity/device_identity.dart';
import 'package:easyprivacy_core/runtime/identity/pairing_client.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> rejected(
  Future<Object?> Function() action,
  String label, {
  bool tlsIdentity = false,
}) async {
  try {
    await action();
  } on CoreException catch (error) {
    check(
      tlsIdentity
          ? error.statusCode == null &&
                error.message.startsWith('Could not verify the core identity.')
          : error.statusCode == 401,
      '$label failed for an unexpected reason: $error',
    );
    return;
  }
  throw StateError('$label was accepted');
}

Future<void> main() async {
  final lines = StreamIterator(
    stdin.transform(utf8.decoder).transform(const LineSplitter()),
  );
  try {
    check(await lines.moveNext(), 'Missing fixture input');
    final input = jsonDecode(lines.current) as Map<String, dynamic>;
    final address = CoreAddress.parse(input['address'] as String),
        code = input['code'] as String;
    final wrong = code == '00000000' ? '11111111' : '00000000';
    await rejected(
      () => pairCore(address, wrong, 'Wrong-code fixture'),
      'Wrong pairing code',
    );
    final first = await pairCore(address, code, 'Windows smoke device');
    await enrollVerifiedCore(first, 'owner', 'a testing passphrase only');
    final client = CoreClient(address, first.fingerprint);
    var token = await client.signInDevice(first.identity);
    check(
      (await client.status(token)).name == 'Smoke Core',
      'Authenticated core status failed',
    );
    await Future<void>.delayed(const Duration(seconds: 11));
    final anotherCode = await client.createPairingCode(token);
    final second = await pairCore(
      address,
      anotherCode.code,
      'Second smoke device',
    );
    await enrollVerifiedCore(second, 'owner', 'a testing passphrase only');
    check(first.identity.id != second.identity.id, 'Devices share an identity');
    check(
      first.fingerprint == second.fingerprint,
      'Core identity changed between devices',
    );
    final otherClient = CoreClient(address, second.fingerprint);
    final otherToken = await otherClient.signInDevice(second.identity);
    check(
      (await client.devices(token)).where((d) => !d.revoked).length == 2,
      'Device list failed',
    );
    await client.revokeDevice(token, second.identity.id);
    await rejected(
      () => otherClient.status(otherToken),
      'Revoked live session',
    );
    await rejected(
      () => otherClient.signInDevice(second.identity),
      'Revoked device key',
    );
    stdout.writeln(
      'PASS: native Windows Dart verifies Linux Go, enrolls with account credentials, creates a code without reauthentication, and revokes another device.',
    );
    stdout.writeln('READY_TO_RESTART');
    await stdout.flush();
    check(await lines.moveNext(), 'Missing restart signal');
    final proxyInput = jsonDecode(lines.current) as Map<String, dynamic>;
    await rejected(
      () => client.status(token),
      'Session retained across restart',
    );
    final restored = await DeviceIdentity.fromSeed(first.identity.encodedSeed);
    token = await client.signInDevice(restored);
    await client.status(token);
    await rejected(
      () => otherClient.signInDevice(second.identity),
      'Revoked key after restart',
    );
    stdout.writeln(
      'PASS: saved device identity reconnects after core restart; revocation persists.',
    );
    final proxy = CoreAddress.parse(proxyInput['address'] as String);
    final proxyCode = proxyInput['code'] as String;
    await rejected(
      () => pairCore(proxy, proxyCode, 'Tampered core identity'),
      'Substituted core fingerprint',
    );
    final relayed = await pairCore(proxy, proxyCode, 'Relayed pairing fixture');
    check(
      relayed.fingerprint == first.fingerprint,
      'Relay replaced the authenticated core identity',
    );
    await rejected(
      () => enrollVerifiedCore(relayed, 'owner', 'a testing passphrase only'),
      'TLS-terminating intermediary',
      tlsIdentity: true,
    );
    await rejected(
      () => client.signInDevice(relayed.identity),
      'Code-only identity without account enrollment',
    );
    stdout.writeln(
      'PASS: substituted core identity fails confirmation; a transparent relay cannot obtain account credentials or enrollment proof; code verification alone cannot authorize a device.',
    );
    await client.revokeDevice(token, first.identity.id);
    await rejected(() => client.status(token), 'Revoked own session');
  } finally {
    await lines.cancel();
  }
}
