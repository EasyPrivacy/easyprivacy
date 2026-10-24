import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easyprivacy_core_sdk/easyprivacy_core_sdk.dart';
import 'package:easyprivacy_files/app.dart';

class TestBroker implements BrokerTransport {
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, Object?> arguments = const {},
  ]) async => {'protocol': 1, 'has_session': false, 'message': 'Pair in Core.'};
  @override
  void close() {}
}

void main() {
  testWidgets(
    'Files separates the three modes without advertising unimplemented services',
    (tester) async {
      final core = BrokerCoreConnection(
        capability: 'files',
        transport: TestBroker(),
        autoStart: false,
      );
      addTearDown(core.dispose);
      await tester.pumpWidget(EasyPrivacyFilesApp(connection: core));
      expect(find.text('Send'), findsOneWidget);
      expect(find.text('Sync'), findsOneWidget);
      expect(find.text('Drive'), findsOneWidget);
      await tester.tap(find.text('Drive'));
      await tester.pumpAndSettle();
      expect(find.text('Your private Drive'), findsOneWidget);
      expect(
        find.text(
          'This capability is not available in this development build.',
        ),
        findsWidgets,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
