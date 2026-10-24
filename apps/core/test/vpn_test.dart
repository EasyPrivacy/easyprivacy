import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easyprivacy_core/runtime/api/core_client.dart';
import 'package:easyprivacy_core/runtime/session/core_controller.dart';
import 'package:easyprivacy_core/runtime/identity/device_identity.dart';
import 'package:easyprivacy_vpn_feature/easyprivacy_vpn.dart';
import 'core_test.dart' show testPin;
import 'pairing_test.dart' show FakeDeviceClient;

VPNProfile fixtureProfile([String exit = 'vps']) => VPNProfile.fromJson({
  'exit_id': exit,
  'exit_name': 'My VPS',
  'public_key': base64Encode(List.filled(32, 7)),
  'endpoint': '203.0.113.8:51821',
  'address': '10.87.0.2/32',
  'address_v6': 'fd6e:7072:6976::2/128',
  'dns': ['1.1.1.1'],
  'allowed_ips': ['0.0.0.0/0', '::/0'],
  'mtu': 1280,
  'keepalive': 25,
  if (exit == 'home') 'management_routes': ['192.168.50.136/32'],
});

class VPNClient extends FakeDeviceClient implements VPNNodeClient {
  List<VPNExit> available = [const VPNExit('vps', 'My VPS', true, '')];
  int registrations = 0, removals = 0;
  String? publicKey;
  Completer<VPNProfile>? registration;
  bool denyAuth = false, transientAuthFailure = false;
  @override
  Future<String> signInDevice(DeviceIdentity identity) async {
    if (denyAuth) {
      throw const CoreException('Device authorization revoked.', 401);
    }
    if (transientAuthFailure) {
      throw const CoreException('Could not reach the core.');
    }
    return super.signInDevice(identity);
  }

  @override
  Future<List<VPNExit>> vpnExits(String token) async => List.of(available);
  @override
  Future<VPNProfile> vpnRegister(String token, String exit, String key) async {
    registrations++;
    publicKey = key;
    return registration?.future ?? Future.value(fixtureProfile(exit));
  }

  @override
  Future<void> vpnDisconnect(String token) async {
    removals++;
  }

  @override
  Future<TunnelStatus> vpnStatus(String token) async =>
      const TunnelStatus(active: true);
}

class MemoryKeys implements VPNKeyStore {
  String? selected;
  @override
  Future<String?> selection() async => selected;
  @override
  Future<void> select(String id) async {
    selected = id;
  }

  VPNKey? saved;
  bool fail = false;
  @override
  Future<void> delete(String scope) async {
    saved = null;
  }

  @override
  Future<VPNKey> key(String scope) async {
    if (fail) {
      throw StateError('storage unavailable');
    }
    return saved ??= await VPNKey.create();
  }
}

class FakeTunnel implements TunnelBackend {
  TunnelStatus current = const TunnelStatus();
  int connects = 0, disconnects = 0, installs = 0;
  bool denyInstall = false, handshake = true;
  @override
  Future<TunnelStatus> status() async => current;
  @override
  Future<void> install() async {
    installs++;
    if (denyInstall) {
      throw const CoreException('Administrator approval was cancelled.');
    }
    current = const TunnelStatus(installed: true);
  }

  @override
  Future<void> connect(VPNProfile profile, VPNKey key) async {
    connects++;
    current = TunnelStatus(
      active: true,
      handshake: handshake ? DateTime.now().millisecondsSinceEpoch ~/ 1000 : 0,
      received: 123,
      sent: 456,
    );
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
    current = const TunnelStatus();
  }
}

Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(condition(), isTrue);
}

void main() {
  test(
    'home selection survives app restart and loss of its service entry',
    () async {
      final client = VPNClient()
        ..available.add(const VPNExit('home', 'Home', true, ''));
      final core = CoreController(clientFactory: (_, _) => client);
      final backend = FakeTunnel()
        ..current = TunnelStatus(
          active: true,
          handshake: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        );
      final keys = MemoryKeys()..selected = 'home';
      final vpn = VPNController(core, backend: backend, keys: keys);
      addTearDown(vpn.dispose);
      addTearDown(core.dispose);
      await until(() => vpn.selectedExit == 'home');
      await core.connectDevice(
        'example.com',
        testPin,
        await DeviceIdentity.create(),
      );
      await until(() => vpn.exits.length == 2);
      client.available.removeWhere((e) => e.id == 'home');
      await vpn.load();
      expect(vpn.selectedExit, 'home');
      expect(vpn.exits.last.ready, isFalse);
      expect(backend.disconnects, 0);
      await vpn.disconnect();
    },
  );
  test(
    'home profile passes explicit management host routes to the native engine',
    () async {
      final key = await VPNKey.create();
      expect(fixtureProfile('home').nativeConfig(key)['management_routes'], [
        '192.168.50.136/32',
      ]);
    },
  );
  test('disconnect retains a VPN key while forgetting removes it', () async {
    final client = VPNClient(),
        core = CoreController(clientFactory: (_, _) => client),
        backend = FakeTunnel(),
        keys = MemoryKeys();
    final vpn = VPNController(core, backend: backend, keys: keys);
    addTearDown(vpn.dispose);
    addTearDown(core.dispose);
    await core.connectDevice(
      'example.com',
      testPin,
      await DeviceIdentity.create(),
    );
    await until(() => vpn.exits.isNotEmpty);
    await vpn.connect();
    await vpn.disconnect();
    expect(keys.saved, isNotNull);
    await vpn.forgetKeys(core.fingerprint!, core.deviceId!);
    expect(keys.saved, isNull);
  });
  for (final revoked in [false, true]) {
    test(
      'management ${revoked ? 'revocation stops' : 'outage preserves'} an active VPN',
      () async {
        final client = VPNClient(),
            core = CoreController(clientFactory: (_, _) => client),
            backend = FakeTunnel();
        final vpn = VPNController(core, backend: backend, keys: MemoryKeys());
        addTearDown(vpn.dispose);
        addTearDown(core.dispose);
        await core.connectDevice(
          'example.com',
          testPin,
          await DeviceIdentity.create(),
        );
        await until(() => vpn.exits.isNotEmpty);
        await vpn.connect();
        client.expireOnce = true;
        client.denyAuth = revoked;
        client.transientAuthFailure = !revoked;
        await core.refresh();
        if (revoked) {
          await until(() => backend.disconnects > 0);
          await until(() => !vpn.active);
        } else {
          expect(backend.disconnects, 0);
          expect(vpn.active, isTrue);
          await vpn.disconnect();
        }
      },
    );
  }
  test(
    'a running native tunnel remains disconnectable before core login',
    () async {
      final core = CoreController(),
          backend = FakeTunnel()
            ..current = TunnelStatus(
              active: true,
              handshake: DateTime.now().millisecondsSinceEpoch ~/ 1000,
            );
      final vpn = VPNController(core, backend: backend, keys: MemoryKeys());
      addTearDown(vpn.dispose);
      addTearDown(core.dispose);
      await until(() => vpn.active);
      expect(core.hasSession, isFalse);
      expect(await vpn.disconnect(), isTrue);
      expect(backend.disconnects, 1);
      expect(vpn.active, isFalse);
    },
  );
  test('VPN keys are separate, persistent X25519 identities', () async {
    final a = await VPNKey.create(), b = await VPNKey.create();
    expect(a.publicKey, isNot(b.publicKey));
    expect((await VPNKey.fromPrivate(a.privateKey)).publicKey, a.publicKey);
    expect(base64Decode(a.privateKey)[0] & 7, 0);
  });
  test(
    'VPN uses paired authorization, local private keys and a real handshake state',
    () async {
      final client = VPNClient(),
          core = CoreController(clientFactory: (_, _) => client),
          backend = FakeTunnel(),
          keys = MemoryKeys();
      final vpn = VPNController(core, backend: backend, keys: keys);
      addTearDown(vpn.dispose);
      addTearDown(core.dispose);
      await core.connectDevice(
        'example.com',
        testPin,
        await DeviceIdentity.create(),
      );
      await until(() => vpn.exits.isNotEmpty);
      await vpn.connect();
      expect(vpn.phase, VPNPhase.connected);
      expect(client.publicKey, keys.saved!.publicKey);
      expect(client.publicKey, isNot(keys.saved!.privateKey));
      expect(client.passwordLogins, 0);
      expect(backend.connects, 1);
      expect(await vpn.disconnect(), isTrue);
      expect(backend.disconnects, 1);
      expect(client.removals, 1);
      expect(vpn.phase, VPNPhase.idle);
    },
  );
  test('missing handshake is not reported as connected', () async {
    final client = VPNClient(),
        core = CoreController(clientFactory: (_, _) => client),
        backend = FakeTunnel()..handshake = false;
    final vpn = VPNController(core, backend: backend, keys: MemoryKeys());
    addTearDown(vpn.dispose);
    addTearDown(core.dispose);
    await core.connectDevice(
      'example.com',
      testPin,
      await DeviceIdentity.create(),
    );
    await until(() => vpn.exits.isNotEmpty);
    await vpn.connect();
    expect(vpn.phase, VPNPhase.connecting);
    await vpn.disconnect();
  });
  test('failed protected key storage never provisions a peer', () async {
    final client = VPNClient(),
        core = CoreController(clientFactory: (_, _) => client),
        backend = FakeTunnel();
    final vpn = VPNController(
      core,
      backend: backend,
      keys: MemoryKeys()..fail = true,
    );
    addTearDown(vpn.dispose);
    addTearDown(core.dispose);
    await core.connectDevice(
      'example.com',
      testPin,
      await DeviceIdentity.create(),
    );
    await until(() => vpn.exits.isNotEmpty);
    await vpn.connect();
    expect(client.registrations, 0);
    expect(backend.connects, 0);
    expect(vpn.error, isNotNull);
  });
  test('cancelled Windows helper approval never provisions a peer', () async {
    final client = VPNClient(),
        core = CoreController(clientFactory: (_, _) => client),
        backend = FakeTunnel()
          ..denyInstall = true
          ..current = const TunnelStatus(installed: false);
    final vpn = VPNController(core, backend: backend, keys: MemoryKeys());
    addTearDown(vpn.dispose);
    addTearDown(core.dispose);
    await core.connectDevice(
      'example.com',
      testPin,
      await DeviceIdentity.create(),
    );
    await until(() => vpn.exits.isNotEmpty);
    await vpn.connect();
    expect(backend.installs, 1);
    expect(client.registrations, 0);
    expect(backend.connects, 0);
  });
  test(
    'cancelling during peer registration cannot start a late tunnel',
    () async {
      final client = VPNClient()..registration = Completer<VPNProfile>(),
          core = CoreController(clientFactory: (_, _) => client),
          backend = FakeTunnel();
      final vpn = VPNController(core, backend: backend, keys: MemoryKeys());
      addTearDown(vpn.dispose);
      addTearDown(core.dispose);
      await core.connectDevice(
        'example.com',
        testPin,
        await DeviceIdentity.create(),
      );
      await until(() => vpn.exits.isNotEmpty);
      final connecting = vpn.connect();
      await until(() => client.registrations == 1);
      await vpn.disconnect();
      client.registration!.complete(fixtureProfile());
      await connecting;
      expect(backend.connects, 0);
      expect(client.removals, greaterThanOrEqualTo(1));
    },
  );
  for (final width in [390.0, 1280.0]) {
    testWidgets('VPN controls fit at ${width}px', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = CoreController(),
          vpn = VPNController(core, backend: FakeTunnel(), keys: MemoryKeys())
            ..exits = [const VPNExit('vps', 'My VPS', true, '')]
            ..selectedExit = 'vps';
      addTearDown(vpn.dispose);
      addTearDown(core.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: VPNPanel(controller: vpn)),
          ),
        ),
      );
      expect(find.text('Connect VPN'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
