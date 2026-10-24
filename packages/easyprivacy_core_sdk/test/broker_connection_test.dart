import 'package:flutter_test/flutter_test.dart';
import 'package:easyprivacy_core_sdk/easyprivacy_core_sdk.dart';

class TestTransport implements BrokerTransport {
  Map<String, dynamic> summary = {
    'protocol': 1,
    'has_session': true,
    'device_id': 'public-device',
    'fingerprint': 'public-pin',
    'core_name': 'My Core',
  };
  Object? failure;
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, Object?> arguments = const {},
  ]) async {
    if (failure != null) throw failure!;
    return summary;
  }

  @override
  void close() {}
}

void main() {
  test(
    'temporary broker loss preserves authorization while explicit revocation invalidates it',
    () async {
      final transport = TestTransport();
      final core = BrokerCoreConnection(transport: transport, autoStart: false);
      addTearDown(core.dispose);
      await core.refresh();
      expect(core.hasSession, isTrue);
      transport.failure = const BrokerException(
        'core_unavailable',
        'Core restarting',
      );
      await core.refresh();
      expect(core.phase, ConnectionPhase.unreachable);
      expect(core.authorizationLost, isFalse);
      transport.failure = null;
      transport.summary = {
        'protocol': 1,
        'has_session': false,
        'authorization_lost': true,
      };
      await core.refresh();
      expect(core.hasSession, isFalse);
      expect(core.authorizationLost, isTrue);
    },
  );
  test('incompatible brokers do not establish an initial session', () async {
    final transport = TestTransport()
      ..summary = {'protocol': 99, 'has_session': true};
    final core = BrokerCoreConnection(transport: transport, autoStart: false);
    addTearDown(core.dispose);
    await core.refresh();
    expect(core.hasSession, isFalse);
    expect(core.error, contains('Update'));
  });
}
