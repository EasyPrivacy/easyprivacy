import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:easyprivacy_files/providers/device_transfer_provider.dart';
import 'package:easyprivacy_files/providers/folder_sync_provider.dart';
import 'package:easyprivacy_files/transfer/file_store.dart';
import 'package:easyprivacy_files/transfer/send_engine.dart';
import 'package:flutter_test/flutter_test.dart';

// Opt-in counterpart to the normal phone UI. Uses production providers and the
// real Windows Core broker, with isolated synthetic payloads and engine state.
void main() {
  test(
    'physical folder Sync and Send through paired Core brokers',
    () async {
      final control = Directory(Platform.environment['EP_SYNC_TEST_CONTROL']!);
      if (!control.isAbsolute || !await control.exists()) {
        throw StateError(
          'Set EP_SYNC_TEST_CONTROL to an existing test directory.',
        );
      }
      for (final name in ['resume', 'phone-restarted', 'send', 'finish']) {
        final previous = File('${control.path}/$name.flag');
        if (await previous.exists()) {
          await previous.delete();
        }
      }
      final root = await Directory.systemTemp.createTemp(
        'easyprivacy-sync-physical-',
      );
      final transfers = DeviceTransferProvider(
        autoStart: false,
        storeFactory: () async =>
            TransferFileStore(Directory('${root.path}/received')),
      );
      final sync = FolderSyncProvider(
        transfers: transfers,
        autoStart: false,
        rootFactory: (_) async => Directory('${root.path}/sync'),
      );
      addTearDown(() async {
        await sync.setEnabled(false);
        sync.dispose();
        transfers.dispose();
        if (root.absolute.parent.path != Directory.systemTemp.absolute.path ||
            !root.path
                .split(Platform.pathSeparator)
                .last
                .startsWith('easyprivacy-sync-physical-')) {
          throw StateError('Unexpected physical-test cleanup path.');
        }
        await root.delete(recursive: true);
      });
      Future<void> until(
        Future<bool> Function() condition,
        String reason, {
        Duration timeout = const Duration(minutes: 12),
      }) async {
        final deadline = DateTime.now().add(timeout);
        while (DateTime.now().isBefore(deadline)) {
          if (await condition()) return;
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        throw StateError(
          'Timed out: $reason; ${sync.error ?? transfers.error ?? ""}',
        );
      }

      var state = <String, Object?>{};
      Future<void> stage(String value) async {
        state['stage'] = value;
        await File(
          '${control.path}/state.json',
        ).writeAsString(jsonEncode(state), flush: true);
        // ignore: avoid_print
        print('EP_PHYSICAL_SYNC: $value');
      }

      Future<void> flag(String name) =>
          until(() => File('${control.path}/$name.flag').exists(), name);
      await transfers.initialize();
      expect(transfers.connected, isTrue, reason: transfers.error);
      await sync.initialize();
      await sync.setEnabled(true);
      expect(sync.enabled, isTrue, reason: sync.error);
      final peers = (await transfers.pairedDevices())
          .where((d) => d.online)
          .toList();
      expect(
        peers,
        hasLength(1),
        reason: 'Enable Sync only on the test phone.',
      );
      final run = DateTime.now().millisecondsSinceEpoch.toString();
      final name = 'easyprivacy-sync-test-$run.bin';
      final a = File('${root.path}/a.bin'), b = File('${root.path}/b.bin');
      Future<void> fixture(File file, int modulus) async {
        final handle = await file.open(mode: FileMode.write);
        try {
          final chunk = List.generate(64 * 1024, (i) => i % modulus);
          for (var i = 0; i < 64; i++) {
            await handle.writeFrom(chunk);
          }
        } finally {
          await handle.close();
        }
      }

      await fixture(a, 251);
      await fixture(b, 239);
      final hashA = (await sha256.bind(a.openRead()).first).toString();
      final hashB = (await sha256.bind(b.openRead()).first).toString();
      state = {
        'name': name,
        'sourceB': b.path,
        'shaA': hashA,
        'shaB': hashB,
        'label': 'EasyPrivacy Sync test $run',
      };
      await stage('inviting');
      await sync.create(state['label'] as String, peers.single);
      expect(sync.error, isNull);
      final folder = sync.folders.single;
      expect(folder.enginePeer, isNotNull);
      state['folder'] = folder.id;
      final local = File('${sync.directory(folder).path}/$name');
      Future<void> importA() => sync.importFile(
        folder,
        TransferSource(
          name: name,
          size: 4 * 1024 * 1024,
          read: (s, e) => a.openRead(s, e),
        ),
      );
      Future<void> remoteCaughtUp() => until(() async {
        final status = await sync.engine!.status(folder.id);
        if (status['globalFiles'] != 1 || status['needTotalItems'] != 0) {
          return false;
        }
        final connections =
            await sync.engine!.call('GET', 'system/connections') as Map;
        if (((connections['connections'] as Map)[folder.enginePeer]
                as Map?)?['connected'] !=
            true) {
          return false;
        }
        final completion =
            await sync.engine!.call(
                  'GET',
                  'db/completion',
                  query: {'folder': folder.id, 'device': folder.enginePeer!},
                )
                as Map;
        return completion['completion'] == 100 &&
            completion['globalBytes'] == 4 * 1024 * 1024 &&
            completion['needBytes'] == 0;
      }, 'remote fixture convergence');
      await importA();
      await remoteCaughtUp();
      await stage('initial-ready');
      await until(
        () async =>
            await local.exists() &&
            (await sha256.bind(local.openRead()).first).toString() == hashB,
        'phone replacement',
      );
      await stage('phone-edit-verified');
      if (Platform.environment['EP_SYNC_PICKER_ONLY'] == '1') {
        await stage('passed');
        return;
      }
      await until(() async => !await local.exists(), 'phone deletion');
      await sync.pause(folder, true);
      await importA();
      await stage('paused-with-new-file');
      await flag('resume');
      await sync.pause(folder, false);
      await remoteCaughtUp();
      final identity = sync.engine!.deviceId;
      await sync.setEnabled(false);
      await sync.setEnabled(true);
      expect(sync.enabled, isTrue, reason: sync.error);
      expect(sync.engine!.deviceId, identity);
      await remoteCaughtUp();
      await stage('laptop-restarted');
      await flag('phone-restarted');
      await remoteCaughtUp();
      await stage('ready-for-send');
      await flag('send');
      await transfers.send(
        TransferSource(
          name: 'easyprivacy-send-during-sync-$run.bin',
          size: 4 * 1024 * 1024,
          read: (s, e) => a.openRead(s, e),
        ),
        peers.single,
      );
      expect(
        transfers.jobs.first.phase,
        TransferPhase.complete,
        reason: transfers.jobs.first.message,
      );
      await stage('send-verified');
      await flag('finish');
      await stage('passed');
    },
    skip:
        !Platform.isWindows ||
        Platform.environment['EP_PHYSICAL_SYNC_TEST'] != '1',
    timeout: const Timeout(Duration(minutes: 40)),
  );
}
