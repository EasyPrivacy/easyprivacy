import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:easyprivacy_core_sdk/easyprivacy_core_sdk.dart';
import '../test_support/private_stream_fixture.dart';

void main() {
  test(
    'physical Android-to-Windows stream through the owner core',
    () async {
      final client = PrivateServicesClient();
      addTearDown(client.close);
      final status = await client.status();
      expect(
        status['active'],
        isTrue,
        reason: 'Start the Windows private connection first.',
      );
      final id = await client.registerReceiver();
      addTearDown(() => client.closeReceiver(id));
      // This receiver ID is public rendezvous metadata, never an enrollment key.
      // Pass it to the Android integration-test build as EP_TEST_RECEIVER_ID.
      // ignore: avoid_print
      print('EP_TEST_RECEIVER_ID=$id');
      final deadline = DateTime.now().add(const Duration(minutes: 8));
      CorePrivateStream? stream;
      while (stream == null && DateTime.now().isBefore(deadline)) {
        stream = await client.accept(id);
      }
      expect(stream, isNotNull, reason: 'No Android sender connected.');
      await runFixtureReceiver(stream!);
      // ignore: avoid_print
      print(
        'PHYSICAL_STREAM_PASS: 8 MiB each direction, SHA-256 and peer receipts verified.',
      );
    },
    skip:
        !Platform.isWindows ||
        Platform.environment['EP_PHYSICAL_STREAM_TEST'] != '1',
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
