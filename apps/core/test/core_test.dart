import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:easyprivacy_core/runtime/api/core_client.dart';
import 'package:easyprivacy_core/runtime/session/core_controller.dart';

final testPin = 'SHA256:${'A' * 64}';

class FakeClient implements NodeClient {
  Object? error;
  Completer<String>? signInCompletion;
  int signOuts = 0;
  @override
  Future<String> signIn(String username, String password) async {
    if (signInCompletion != null) return signInCompletion!.future;
    if (password != 'testing passphrase') {
      throw const CoreException('Incorrect username or password.', 401);
    }
    return 'session';
  }

  @override
  Future<CoreStatus> status(String token) async {
    if (error != null) throw error!;
    return CoreStatus(
      name: 'Test core',
      version: 'test',
      uptimeSeconds: 3,
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
    );
  }

  @override
  Future<void> signOut(String token) async {
    signOuts++;
  }
}

void main() {
  test(
    'only direct HTTPS core addresses and complete fingerprints are accepted',
    () {
      for (final value in [
        'http://example.com',
        'https://user:secret@example.com',
        'https://example.com/api',
        'example.com?q=1',
        '',
        'example.com:99999',
      ]) {
        expect(() => CoreAddress.parse(value), throwsFormatException);
      }
      expect(CoreAddress.parse('example.com').port, 7444);
      expect(CoreAddress.parse('example.com:17444').port, 17444);
      expect(CoreAddress.parse('https://example.com:443').port, 443);
      expect(CoreAddress.parse('[::1]:17444').uri('/healthz').host, '::1');
      expect(normalizeFingerprint(testPin.toLowerCase()), testPin);
      expect(() => normalizeFingerprint('SHA256:1234'), throwsFormatException);
    },
  );

  test(
    'failed refresh becomes unreachable, recovers, and expiry returns to sign-in',
    () async {
      final client = FakeClient();
      final controller = CoreController(clientFactory: (_, _) => client);
      addTearDown(controller.dispose);
      expect(
        await controller.connect(
          'example.com',
          testPin,
          'owner',
          'testing passphrase',
        ),
        isTrue,
      );
      final checked = controller.lastChecked;
      client.error = const CoreException('Offline');
      await controller.refresh();
      expect(controller.phase, ConnectionPhase.unreachable);
      expect(controller.lastChecked, checked);
      expect(controller.hasSession, isTrue);
      client.error = null;
      await controller.refresh();
      expect(controller.phase, ConnectionPhase.connected);
      client.error = const CoreException('Sign in again', 401);
      await controller.refresh();
      expect(controller.hasSession, isFalse);
      expect(controller.phase, ConnectionPhase.disconnected);
    },
  );

  test('incorrect credentials never produce a connected state', () async {
    final controller = CoreController(clientFactory: (_, _) => FakeClient());
    addTearDown(controller.dispose);
    expect(
      await controller.connect('example.com', testPin, 'owner', 'wrong'),
      isFalse,
    );
    expect(controller.phase, ConnectionPhase.disconnected);
    expect(controller.hasSession, isFalse);
  });

  test('disconnect revokes the session and clears observed status', () async {
    final client = FakeClient();
    final controller = CoreController(clientFactory: (_, _) => client);
    addTearDown(controller.dispose);
    await controller.connect(
      'example.com',
      testPin,
      'owner',
      'testing passphrase',
    );
    await controller.disconnect();
    expect(client.signOuts, 1);
    expect(controller.coreStatus, isNull);
    expect(controller.hasSession, isFalse);
  });

  test('a connection completing after disposal is signed out', () async {
    final client = FakeClient()..signInCompletion = Completer<String>();
    final controller = CoreController(clientFactory: (_, _) => client);
    final future = controller.connect(
      'example.com',
      testPin,
      'owner',
      'testing passphrase',
    );
    controller.dispose();
    client.signInCompletion!.complete('session');
    expect(await future, isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(client.signOuts, 1);
  });
}
