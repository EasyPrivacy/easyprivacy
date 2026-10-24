import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easyprivacy_core_sdk/easyprivacy_core_sdk.dart';
import 'package:easyprivacy_files/app.dart';
import 'package:easyprivacy_files/providers/device_transfer_provider.dart';
import 'package:easyprivacy_files/screens/send_screen.dart';
import 'dart:async';

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
  testWidgets('Send approval and cancellation fit on a narrow phone screen', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final core = BrokerCoreConnection(
      capability: 'files',
      transport: TestBroker(),
      autoStart: false,
    );
    final transfers = DeviceTransferProvider(autoStart: false);
    addTearDown(core.dispose);
    addTearDown(transfers.dispose);
    final offer = TransferJob(
      name: 'example.bin',
      size: 100,
      peer: const SendDevice('peer', 'Laptop', 'receiver'),
      incoming: true,
      phase: TransferPhase.approval,
    )..decision = Completer<bool>();
    transfers.jobs.add(offer);
    await tester.pumpWidget(
      EasyPrivacyFilesApp(connection: core, transfers: transfers),
    );
    await tester.scrollUntilVisible(
      find.text('Accept file'),
      180,
      scrollable: find
          .descendant(
            of: find.byType(SendScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Accept file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Accept file'));
    expect(offer.decision!.isCompleted, isTrue);
    expect(await offer.decision!.future, isTrue);
    offer.phase = TransferPhase.transferring;
    offer.bytes = 50;
    transfers.changed();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Cancel transfer'));
    await tester.tap(find.text('Cancel transfer'));
    await tester.pumpAndSettle();
    expect(offer.cancellation.cancelled, isTrue);
    expect(find.text('Cancelled'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'Files separates the three modes without advertising unimplemented services',
    (tester) async {
      final core = BrokerCoreConnection(
        capability: 'files',
        transport: TestBroker(),
        autoStart: false,
      );
      addTearDown(core.dispose);
      final transfers = DeviceTransferProvider(autoStart: false);
      addTearDown(transfers.dispose);
      await tester.pumpWidget(
        EasyPrivacyFilesApp(connection: core, transfers: transfers),
      );
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
