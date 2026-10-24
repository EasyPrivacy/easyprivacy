import 'package:easyprivacy_core/features/nodes/service_node.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easyprivacy_core/runtime/storage/profile_store.dart';

class FakeService implements ServiceNodeClient {
  ServiceNodeStatus value = const ServiceNodeStatus(configured: true);
  int starts = 0, stops = 0, installs = 0;
  @override
  Future<ServiceNodeStatus> status() async => value;
  @override
  Future<void> start() async {
    starts++;
    value = ServiceNodeStatus(
      configured: true,
      active: true,
      handshake: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
  }

  @override
  Future<void> stop() async {
    stops++;
    value = const ServiceNodeStatus(configured: true);
  }

  @override
  Future<void> install(
    CoreProfile identity,
    String name, [
    String managementAddresses = '',
  ]) async {
    installs++;
  }
}

void main() {
  testWidgets(
    'GUI controls an existing headless service without enrolling again',
    (tester) async {
      final client = FakeService();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ServiceNodePanel(client: client)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Start home service'), findsOneWidget);
      expect(find.text('Set up home exit'), findsNothing);
      await tester.tap(find.text('Start home service'));
      await tester.pumpAndSettle();
      expect(client.starts, 1);
      expect(find.text('Home: connected to the VPS'), findsOneWidget);
      await tester.tap(find.text('Stop home service'));
      await tester.pumpAndSettle();
      expect(client.stops, 1);
      expect(client.installs, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('new service requires a paired identity', (tester) async {
    final client = FakeService()..value = const ServiceNodeStatus();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ServiceNodePanel(client: client)),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Set up home exit'),
          )
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
