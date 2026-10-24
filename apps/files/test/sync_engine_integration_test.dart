import 'dart:convert';
import 'dart:io';
import 'package:easyprivacy_files/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'bundled engine starts offline, uses only loopback and preserves identity',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'easyprivacy-sync-engine-test-',
      );
      final engine = SyncEngine(root: root);
      addTearDown(() async {
        await engine.stop();
        if (root.absolute.parent.path != Directory.systemTemp.absolute.path ||
            !root.path
                .split(Platform.pathSeparator)
                .last
                .startsWith('easyprivacy-sync-engine-test-')) {
          throw StateError('Unexpected cleanup path.');
        }
        await root.delete(recursive: true);
      });
      try {
        await engine.start();
      } catch (_) {
        for (final log in engine.diagnostics) {
          /* Synthetic test state only. */
          stdout.writeln(log);
        }
        rethrow;
      }
      final id = engine.deviceId;
      expect(validSyncDevice(id!), isTrue);
      final config = await engine.call('GET', 'config') as Map;
      expect(config['folders'], isEmpty);
      final options = config['options'] as Map;
      for (final name in [
        'globalAnnounceEnabled',
        'localAnnounceEnabled',
        'relaysEnabled',
        'natEnabled',
        'crashReportingEnabled',
      ]) {
        expect(options[name], isFalse, reason: name);
      }
      expect(options['listenAddresses'], [
        'tcp://127.0.0.1:${engine.syncPort}',
      ]);
      expect(jsonEncode(config['devices']), isNot(contains('dynamic')));
      await engine.stop();
      await engine.start();
      expect(engine.deviceId, id);
    },
    skip: Platform.environment['EASYPRIVACY_SYNC_ENGINE'] == null,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
