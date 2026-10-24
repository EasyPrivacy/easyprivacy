import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:easyprivacy_core_sdk/easyprivacy_core_sdk.dart';
import 'package:easyprivacy_core/runtime/broker/core_broker_runtime.dart';
import 'package:easyprivacy_core/runtime/storage/profile_store.dart';
import 'package:easyprivacy_core/runtime/session/core_controller.dart';
import 'package:easyprivacy_core/runtime/identity/device_identity.dart';

class TestStore implements ProfileStore {
  int reads = 0;
  final profile = CoreProfile(
    address: 'example.test',
    username: 'owner',
    fingerprint: 'public-core-pin',
    deviceSeed: base64Encode(List.filled(32, 42)),
    deviceId: 'public-device-id',
  );
  @override
  Future<CoreProfile?> read() async {
    reads++;
    return profile;
  }

  @override
  Future<void> save(CoreProfile profile) async {}
  @override
  Future<void> delete() async {}
}

class TestSession extends CoreController {
  int provisions = 0;
  @override
  bool get hasSession => true;
  @override
  bool get isDeviceConnection => true;
  @override
  String? get deviceId => 'public-device-id';
  @override
  Future<void> disconnect({bool authorizationLost = false}) async {}
  @override
  Future<bool> connectDevice(
    String address,
    String fingerprint,
    DeviceIdentity identity,
  ) async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'wrong capability or operation cannot invoke owner management',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final store = TestStore(), session = TestSession();
      final runtime = CoreBrokerRuntime(store: store, session: session);
      addTearDown(runtime.dispose);
      await expectLater(
        runtime.handle('files', 'vpnRegister', {}),
        throwsA(isA<BrokerException>()),
      );
      await expectLater(
        runtime.handle('vpn', 'revokeDevice', {}),
        throwsA(isA<BrokerException>()),
      );
      await expectLater(
        runtime.handle('unknown', 'getSummary', {}),
        throwsA(isA<BrokerException>()),
      );
      expect(store.reads, 0);
    },
  );
  test(
    'a missing user grant rejects provisioning before reading enrollment',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final store = TestStore(), session = TestSession();
      final runtime = CoreBrokerRuntime(store: store, session: session);
      addTearDown(runtime.dispose);
      await expectLater(
        runtime.handle('vpn', 'vpnRegister', {
          'exit_id': 'vps',
          'public_key': 'key',
        }),
        throwsA(
          isA<BrokerException>().having(
            (e) => e.code,
            'code',
            'grant_required',
          ),
        ),
      );
      expect(store.reads, 0);
    },
  );
  test('summary exports public identity only', () async {
    FlutterSecureStorage.setMockInitialValues({
      'easyprivacy.broker.allow_vpn': 'true',
    });
    final store = TestStore(),
        session = TestSession()..phase = ConnectionPhase.connected;
    final runtime = CoreBrokerRuntime(store: store, session: session);
    addTearDown(runtime.dispose);
    final summary = await runtime.handle('vpn', 'getSummary', {});
    expect(summary['has_session'], isTrue);
    expect(summary['device_id'], 'public-device-id');
    expect(jsonEncode(summary), isNot(contains(store.profile.deviceSeed!)));
    expect(summary.containsKey('token'), isFalse);
    expect(summary.containsKey('device_seed'), isFalse);
  });
  test(
    'private status and local stop do not depend on remote management',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final store = TestStore(), session = TestSession();
      final runtime = CoreBrokerRuntime(store: store, session: session);
      addTearDown(runtime.dispose);
      expect(
        (await runtime.handle('core', 'privateStatus', {}))['active'],
        isFalse,
      );
      expect(
        (await runtime.handle('core', 'privateStop', {}))['active'],
        isFalse,
      );
      expect(store.reads, 0);
      for (final method in ['privateStart', 'privateStop', 'refreshGrants']) {
        await expectLater(
          runtime.handle('files', method, {}),
          throwsA(isA<BrokerException>()),
        );
      }
      await expectLater(
        runtime.handle('files', 'privateStatus', {}),
        throwsA(
          isA<BrokerException>().having(
            (e) => e.code,
            'code',
            'grant_required',
          ),
        ),
      );
    },
  );
}
