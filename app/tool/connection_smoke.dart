// Run against the isolated test fixture started by core/scripts/smoke.py.
import 'dart:io';
import 'package:easyprivacy/core_client.dart';

Future<void> main(List<String> args) async {
  final client = CoreClient(CoreAddress.parse(args[0]), args[1]);
  var rejected = false;
  try {
    await client.signIn('owner', 'incorrect password');
  } on CoreException catch (error) {
    rejected = error.statusCode == 401;
    if (!rejected) {
      throw StateError(
        'Unexpected sign-in error: ${error.statusCode}: ${error.message}',
      );
    }
  }
  if (!rejected) throw StateError('Incorrect password was accepted.');
  final token = await client.signIn('owner', 'a testing passphrase only');
  final status = await client.status(token);
  if (status.name != 'Smoke Core') throw StateError('Wrong core status.');
  await client.signOut(token);
  rejected = false;
  try {
    await client.status(token);
  } on CoreException catch (error) {
    rejected = error.statusCode == 401;
  }
  if (!rejected) throw StateError('Signed-out session remained active.');
  final wrongPin = 'SHA256:${'0' * 64}';
  rejected = false;
  try {
    await CoreClient(
      CoreAddress.parse(args[0]),
      wrongPin,
    ).signIn('owner', 'a testing passphrase only');
  } on CoreException {
    rejected = true;
  }
  if (!rejected) throw StateError('Wrong server fingerprint was accepted.');
  stdout.writeln(
    'PASS: real Dart-to-Go TLS connection, bad password, status, sign-out and wrong-fingerprint rejection.',
  );
}
