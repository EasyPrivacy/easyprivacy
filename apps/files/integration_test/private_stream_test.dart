import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:easyprivacy_core_sdk/easyprivacy_core_sdk.dart';
import '../../../packages/easyprivacy_core_sdk/test_support/private_stream_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const receiverId = String.fromEnvironment('EP_TEST_RECEIVER_ID');
  testWidgets(
    'phone streams through its Core broker to Windows',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: Text('Testing private phone/laptop connection…'),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(receiverId)) {
          throw StateError(
            'Supply EP_TEST_RECEIVER_ID from the Windows fixture.',
          );
        }
        final client = PrivateServicesClient();
        try {
          final status = await client.status();
          expect(
            status['active'],
            isTrue,
            reason: 'Enable Files access and the private connection in Core.',
          );
          final targets = await client.services();
          expect(targets.any((v) => v['id'] == 'receiver.$receiverId'), isTrue);
          await runFixtureSender(await client.open('receiver.$receiverId'));
        } finally {
          client.close();
        }
      });
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: Text(
                'Passed: 8 MiB each direction with verified integrity.',
              ),
            ),
          ),
        ),
      );
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
