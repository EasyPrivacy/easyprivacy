import 'package:easyprivacy_core/runtime/session/core_controller.dart';
import 'package:easyprivacy_core/runtime/identity/device_identity.dart';
import 'package:easyprivacy_vpn_feature/easyprivacy_vpn.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'core_test.dart' show testPin;
import 'vpn_test.dart' show VPNClient, MemoryKeys, FakeTunnel, until;

class MemoryPreferences implements VPNPresencePreferences {
  bool value = false, failWrite = false;
  @override
  Future<bool> read() async => value;
  @override
  Future<void> write(bool value) async {
    if (failWrite) throw StateError('storage unavailable');
    this.value = value;
  }
}

class FakePresence implements VPNPresenceBackend {
  Future<void> Function(String)? action;
  String? pending;
  final states = <Map<String, Object>>[];
  bool permitted = true;
  @override
  void listen(Future<void> Function(String) callback) => action = callback;
  @override
  Future<String?> pendingAction() async => pending;
  @override
  Future<bool> update(Map<String, Object> state) async {
    states.add(state);
    return permitted;
  }

  @override
  Future<bool> requestPermission() async => permitted;
  @override
  Future<void> openSettings() async {}
  @override
  void dispose() => action = null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CoreController core;
  late VPNController vpn;
  late VPNClient client;
  late FakeTunnel tunnel;
  late FakePresence native;
  late MemoryPreferences preferences;
  late VPNPresenceController presence;

  setUp(() {
    client = VPNClient();
    core = CoreController(clientFactory: (_, _) => client);
    tunnel = FakeTunnel();
    vpn = VPNController(core, backend: tunnel, keys: MemoryKeys());
    native = FakePresence();
    preferences = MemoryPreferences();
  });

  Future<void> start({String? pending}) async {
    native.pending = pending;
    presence = VPNPresenceController(
      vpn,
      backend: native,
      preferences: preferences,
    );
    await until(() => presence.ready && native.states.isNotEmpty);
  }

  Future<void> pair() async {
    final identity = await DeviceIdentity.create();
    await core.connectDevice('example.com:7444', testPin, identity);
    await until(() => vpn.exits.isNotEmpty);
  }

  tearDown(() {
    presence.dispose();
    vpn.dispose();
    core.dispose();
  });

  test(
    'connected-only default follows the tunnel rather than core login',
    () async {
      await start();
      expect(native.states.last['visible'], false);
      await pair();
      await native.action!('connect');
      await until(() => native.states.last['status'] == 'VPN connected');
      expect(native.states.last['visible'], true);
      expect(native.states.last['action'], 'disconnect');
      await core.disconnect();
      expect(presence.state['visible'], true);
      expect(presence.state['actionEnabled'], true);
      await native.action!('disconnect');
      await until(() => native.states.last['visible'] == false);
      expect(tunnel.disconnects, 1);
    },
  );

  test(
    'always-show saves the setting and exposes Connect only when ready',
    () async {
      await start();
      await presence.setAlwaysShow(true);
      expect(preferences.value, true);
      expect(presence.state['visible'], true);
      expect(presence.state['actionEnabled'], false);
      await pair();
      expect(presence.state['actionEnabled'], true);
      await native.action!('connect');
      await native.action!('disconnect');
      expect(presence.state['visible'], true);
      expect(presence.state['action'], 'connect');
      await presence.setAlwaysShow(false);
      expect(presence.state['visible'], false);
    },
  );

  test(
    'cold notification Connect waits for pairing and uses the saved exit',
    () async {
      client.available.add(const VPNExit('home', 'Home', true, ''));
      (vpn.keys as MemoryKeys).selected = 'home';
      await start(pending: 'connect');
      expect(tunnel.connects, 0);
      await pair();
      await until(() => tunnel.connects == 1 && !vpn.busy);
      expect(vpn.selectedExit, 'home');
      expect(vpn.phase, VPNPhase.connected);
      expect(client.registrations, 1);
    },
  );

  test(
    'an active tunnel without a handshake is not reported as connected',
    () async {
      tunnel.handshake = false;
      await start();
      await pair();
      await native.action!('connect');
      expect(presence.state['status'], 'Waiting for VPN server');
      expect(presence.state['action'], 'disconnect');
    },
  );

  test(
    'restores always-show while disconnected after restarting the app',
    () async {
      preferences.value = true;
      await start();
      expect(presence.alwaysShow, true);
      expect(native.states.last['visible'], true);
      expect(native.states.last['action'], 'connect');
      expect(native.states.last['actionEnabled'], false);
    },
  );

  test('permission refusal and persistence failure remain visible', () async {
    await start();
    native.permitted = false;
    await presence.setAlwaysShow(true);
    expect(presence.notificationsEnabled, false);
    preferences.failWrite = true;
    await presence.setAlwaysShow(false);
    expect(presence.alwaysShow, true);
    expect(presence.error, contains('Could not save'));
  });

  testWidgets('notification setting works before core sign-in', (tester) async {
    presence = VPNPresenceController(
      vpn,
      backend: native,
      preferences: preferences,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: VPNNotificationSettings(controller: presence)),
      ),
    );
    await tester.tap(find.byKey(const Key('always-show-vpn')));
    await tester.pumpAndSettle();
    expect(preferences.value, true);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
