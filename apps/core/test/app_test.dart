import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easyprivacy_core/app.dart';
import 'package:easyprivacy_core/runtime/session/core_controller.dart';
import 'package:easyprivacy_core/runtime/storage/profile_store.dart';
import 'core_test.dart' show FakeClient, testPin;

class MemoryStore implements ProfileStore {
  CoreProfile? profile;
  @override
  Future<CoreProfile?> read() async => profile;
  @override
  Future<void> save(CoreProfile value) async {
    profile = value;
  }

  @override
  Future<void> delete() async {
    profile = null;
  }
}

void main() {
  for (final size in [const Size(1280, 900), const Size(390, 844)]) {
    testWidgets(
      'connect and disconnect at ${size.width}px without layout errors',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final store = MemoryStore();
        await tester.pumpWidget(
          EasyPrivacyApp(
            controller: CoreController(clientFactory: (_, _) => FakeClient()),
            store: store,
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Use existing fingerprint login'));
        await tester.tap(find.text('Use existing fingerprint login'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('core-address')),
          'example.com:7444',
        );
        await tester.enterText(
          find.byKey(const Key('core-fingerprint')),
          testPin,
        );
        await tester.enterText(find.byKey(const Key('username')), 'owner');
        await tester.enterText(
          find.byKey(const Key('password')),
          'testing passphrase',
        );
        await tester.ensureVisible(find.byKey(const Key('connect')));
        await tester.tap(find.byKey(const Key('connect')));
        await tester.pumpAndSettle();
        expect(find.text('Core connected'), findsOneWidget);
        expect(store.profile?.fingerprint, testPin);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('Disconnect'));
        await tester.tap(find.text('Disconnect'));
        await tester.pumpAndSettle();
        expect(find.text('Connect to your core'), findsOneWidget);
        expect(
          tester
              .widget<TextFormField>(find.byKey(const Key('password')))
              .controller!
              .text,
          isEmpty,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
