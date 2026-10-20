import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easyprivacy/core_client.dart';
import 'package:easyprivacy/core_controller.dart';
import 'package:easyprivacy/device_identity.dart';
import 'package:easyprivacy/main.dart';
import 'package:easyprivacy/pairing_client.dart';
import 'package:easyprivacy/profile_store.dart';
import 'app_test.dart' show MemoryStore;
import 'core_test.dart' show FakeClient, testPin;

class FakeDeviceClient extends FakeClient implements DeviceNodeClient {
  int deviceLogins = 0, passwordLogins = 0, codeRequests = 0;
  bool expireOnce = false;
  List<PairedDevice> deviceList = [
    PairedDevice('b' * 64, 'Other phone', false),
  ];
  @override
  Future<String> signIn(String username, String password) async {
    passwordLogins++;
    return super.signIn(username, password);
  }

  @override
  Future<String> signInDevice(DeviceIdentity identity) async {
    deviceLogins++;
    return 'device-session';
  }

  @override
  Future<CoreStatus> status(String token) async {
    if (expireOnce) {
      expireOnce = false;
      throw const CoreException('Session expired', 401);
    }
    return super.status(token);
  }

  @override
  Future<PairingCode> createPairingCode(String token) async {
    codeRequests++;
    return PairingCode(
      '01234567',
      DateTime.now().add(const Duration(minutes: 5)),
    );
  }

  @override
  Future<List<PairedDevice>> devices(String token) async => deviceList;
  @override
  Future<void> revokeDevice(String token, String id) async {
    deviceList = deviceList
        .map((d) => d.id == id ? PairedDevice(d.id, d.name, true) : d)
        .toList();
  }
}

class FailingStore extends MemoryStore {
  @override
  Future<void> save(CoreProfile value) async {
    throw StateError('fixture storage failure');
  }
}

VerifiedCore fixtureVerification(String pin, DeviceIdentity identity) =>
    VerifiedCore(
      pin,
      identity,
      address: CoreAddress.parse('example.com:7444'),
      exchangeId: 'a' * 64,
      enrollmentProof: List.filled(32, 1),
      expiresAt: DateTime.now().add(const Duration(minutes: 5)),
    );

Future<void> authorizeFixture(WidgetTester tester) async {
  expect(find.text('Core verified'), findsOneWidget);
  await tester.enterText(find.byKey(const Key('username')), 'owner');
  await tester.enterText(
    find.byKey(const Key('password')),
    'fixture account password',
  );
  await tester.ensureVisible(find.byKey(const Key('authorize-device')));
  await tester.tap(find.byKey(const Key('authorize-device')));
  await tester.pumpAndSettle();
}

void main() {
  test(
    'pairing code normalization preserves leading zeros and rejects other text',
    () {
      expect(normalizePairingCode('0123-4567'), '01234567');
      expect(normalizePairingCode(' 0123 4567 '), '01234567');
      for (final text in ['1234567', '123456789', '0123x4567']) {
        expect(() => normalizePairingCode(text), throwsFormatException);
      }
    },
  );
  test(
    'device identities are distinct and survive secure-storage serialization',
    () async {
      final a = await DeviceIdentity.create(),
          b = await DeviceIdentity.create();
      expect(a.id, isNot(b.id));
      final restored = await DeviceIdentity.fromSeed(a.encodedSeed);
      expect(restored.id, a.id);
      expect(
        await restored.sign('fresh challenge'),
        await a.sign('fresh challenge'),
      );
    },
  );
  test('expired device sessions renew using the private key', () async {
    final client = FakeDeviceClient(), identity = await DeviceIdentity.create();
    final controller = CoreController(clientFactory: (_, _) => client);
    addTearDown(controller.dispose);
    expect(
      await controller.connectDevice('example.com', testPin, identity),
      isTrue,
    );
    client.expireOnce = true;
    await controller.refresh();
    expect(controller.phase, ConnectionPhase.connected);
    expect(client.deviceLogins, 2);
    expect(client.passwordLogins, 0);
  });

  for (final size in [const Size(1280, 900), const Size(390, 844)]) {
    testWidgets(
      'pair, create code without password, reconnect and revoke at ${size.width}px',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final identity = await DeviceIdentity.create(),
            client = FakeDeviceClient(),
            store = MemoryStore();
        final controller = CoreController(clientFactory: (_, _) => client);
        await tester.pumpWidget(
          EasyPrivacyApp(
            controller: controller,
            store: store,
            pairer: (address, code, name) async {
              expect(normalizePairingCode(code), '01234567');
              return fixtureVerification(testPin, identity);
            },
            enroller: (_, username, password) async {
              expect(username, 'owner');
              expect(password, 'fixture account password');
            },
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('core-fingerprint')), findsNothing);
        await tester.enterText(
          find.byKey(const Key('core-address')),
          'example.com:7444',
        );
        await tester.enterText(
          find.byKey(const Key('pairing-code')),
          '0123 4567',
        );
        await tester.ensureVisible(find.byKey(const Key('pair-device')));
        await tester.tap(find.byKey(const Key('pair-device')));
        await tester.pumpAndSettle();
        expect(store.profile, isNull);
        expect(client.deviceLogins, 0);
        await authorizeFixture(tester);
        expect(find.text('Core connected'), findsOneWidget);
        expect(store.profile?.deviceId, identity.id);
        expect(store.profile?.deviceSeed, identity.encodedSeed);
        expect(client.passwordLogins, 0);
        await tester.ensureVisible(find.byKey(const Key('add-device')));
        await tester.tap(find.byKey(const Key('add-device')));
        await tester.pumpAndSettle();
        expect(find.text('0123 4567'), findsOneWidget);
        expect(client.codeRequests, 1);
        expect(find.byKey(const Key('password')), findsNothing);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('manage-devices')));
        await tester.tap(find.byKey(const Key('manage-devices')));
        await tester.pumpAndSettle();
        expect(find.text('Other phone'), findsOneWidget);
        await tester.tap(find.byTooltip('Revoke device'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Revoke device'));
        await tester.pumpAndSettle();
        expect(find.text('Revoked'), findsOneWidget);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Disconnect'));
        await tester.tap(find.text('Disconnect'));
        await tester.pumpAndSettle();
        expect(find.text('Your paired core'), findsOneWidget);
        await tester.tap(find.byKey(const Key('connect-paired')));
        await tester.pumpAndSettle();
        expect(client.deviceLogins, 2);
        expect(client.passwordLogins, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        // A new app instance loads and reconnects with the saved key.
        await tester.pumpWidget(
          EasyPrivacyApp(
            store: store,
            controller: CoreController(clientFactory: (_, _) => client),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Core connected'), findsOneWidget);
        expect(client.deviceLogins, 3);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'failed secure persistence does not connect or save an unverified profile',
    (tester) async {
      final identity = await DeviceIdentity.create(),
          client = FakeDeviceClient(),
          store = FailingStore();
      await tester.pumpWidget(
        EasyPrivacyApp(
          store: store,
          controller: CoreController(clientFactory: (_, _) => client),
          pairer: (_, _, _) async => fixtureVerification(testPin, identity),
          enroller: (_, _, _) async {},
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('core-address')),
        'example.com',
      );
      await tester.enterText(find.byKey(const Key('pairing-code')), '01234567');
      await tester.tap(find.byKey(const Key('pair-device')));
      await tester.pumpAndSettle();
      await authorizeFixture(tester);
      expect(
        find.textContaining('key could not be saved securely'),
        findsOneWidget,
      );
      expect(client.deviceLogins, 0);
      expect(store.profile, isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'pairing cannot silently replace an existing trusted core identity',
    (tester) async {
      final identity = await DeviceIdentity.create(),
          client = FakeDeviceClient(),
          store = MemoryStore();
      store.profile = CoreProfile(
        address: 'example.com',
        username: 'owner',
        fingerprint: testPin,
      );
      await tester.pumpWidget(
        EasyPrivacyApp(
          store: store,
          controller: CoreController(clientFactory: (_, _) => client),
          pairer: (_, _, _) async =>
              fixtureVerification('SHA256:${'B' * 64}', identity),
          enroller: (_, _, _) async =>
              fail('Sent credentials to a changed core'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Use a pairing code'));
      await tester.tap(find.text('Use a pairing code'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('pairing-code')), '01234567');
      await tester.tap(find.byKey(const Key('pair-device')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('identity differs from your saved core'),
        findsOneWidget,
      );
      expect(store.profile?.fingerprint, testPin);
      expect(client.deviceLogins, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('wrong account password never saves or authorizes a device', (
    tester,
  ) async {
    final identity = await DeviceIdentity.create(),
        client = FakeDeviceClient(),
        store = MemoryStore();
    var attempts = 0, verifications = 0;
    await tester.pumpWidget(
      EasyPrivacyApp(
        store: store,
        controller: CoreController(clientFactory: (_, _) => client),
        pairer: (_, _, _) async {
          verifications++;
          return fixtureVerification(testPin, identity);
        },
        enroller: (_, username, password) async {
          attempts++;
          if (password != 'correct account password') {
            throw const CoreException('Incorrect username or password.', 401);
          }
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('password')), findsNothing);
    await tester.enterText(
      find.byKey(const Key('core-address')),
      'example.com',
    );
    await tester.enterText(find.byKey(const Key('pairing-code')), '01234567');
    await tester.tap(find.byKey(const Key('pair-device')));
    await tester.pumpAndSettle();
    await authorizeFixture(tester);
    expect(find.text('Incorrect username or password.'), findsOneWidget);
    expect(store.profile, isNull);
    expect(client.deviceLogins, 0);
    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('password')))
          .controller!
          .text,
      isEmpty,
    );
    await tester.enterText(
      find.byKey(const Key('password')),
      'correct account password',
    );
    await tester.tap(find.byKey(const Key('authorize-device')));
    await tester.pumpAndSettle();
    expect(find.text('Core connected'), findsOneWidget);
    expect(attempts, 2);
    expect(verifications, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'expired verification returns to code entry without persisting a key',
    (tester) async {
      final identity = await DeviceIdentity.create(), store = MemoryStore();
      await tester.pumpWidget(
        EasyPrivacyApp(
          store: store,
          controller: CoreController(
            clientFactory: (_, _) => FakeDeviceClient(),
          ),
          pairer: (_, _, _) async => fixtureVerification(testPin, identity),
          enroller: (_, _, _) async => throw const CoreException(
            'Core verification expired. Verify the core with a new code.',
            410,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('core-address')),
        'example.com',
      );
      await tester.enterText(find.byKey(const Key('pairing-code')), '01234567');
      await tester.tap(find.byKey(const Key('pair-device')));
      await tester.pumpAndSettle();
      await authorizeFixture(tester);
      expect(find.byKey(const Key('pairing-code')), findsOneWidget);
      expect(find.byKey(const Key('password')), findsNothing);
      expect(store.profile, isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
