import 'dart:io';
import 'package:easyprivacy_files/providers/folder_sync_provider.dart';
import 'package:easyprivacy_files/providers/device_transfer_provider.dart';
import 'package:easyprivacy_files/transfer/secure_channel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easyprivacy_files/sync/sync_engine.dart';
import 'package:easyprivacy_files/sync/sync_paths.dart';

class LiveTransfers extends DeviceTransferProvider {
  LiveTransfers() : super(autoStart: false);
  @override
  Future<TransferIdentity> identity() async => TransferIdentity(
    core: 'synthetic-core',
    device: 'b' * 64,
    sign: (_, _, _, _) async => {},
    isPaired: (_) async => true,
  );
}

void main() {
  test(
    'live source folders, two replicas, metadata-only selection and unavailable roots',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'ep-live-folders-test-',
      );
      final source = await Directory('${root.path}/Chosen source').create();
      final second = await Directory('${root.path}/Chosen second').create();
      final third = await Directory('${root.path}/Chosen third').create();
      final a = SyncEngine(root: Directory('${root.path}/a'));
      final b = SyncEngine(root: Directory('${root.path}/b'));
      final c = SyncEngine(root: Directory('${root.path}/c'));
      final id = 'ep-${'e' * 32}';
      for (final entry in [(a, source), (b, second), (c, third)]) {
        entry.$1.registerLocation(id, entry.$2);
      }
      addTearDown(() async {
        for (final engine in [a, b, c]) {
          await engine.stop();
        }
        if (root.absolute.parent.path != Directory.systemTemp.absolute.path ||
            !root.path
                .split(Platform.pathSeparator)
                .last
                .startsWith('ep-live-folders-test-')) {
          throw StateError('Unexpected test path');
        }
        await root.delete(recursive: true);
      });
      for (final engine in [a, b, c]) {
        await engine.start();
      }
      await a.configurePeer(b.deviceId!, 'Second', b.syncPort!);
      await a.configurePeer(c.deviceId!, 'Third', c.syncPort!);
      await b.configurePeer(a.deviceId!, 'Source', a.syncPort!);
      await c.configurePeer(a.deviceId!, 'Source', a.syncPort!);
      final selective = SyncSelection(selective: true);
      await a.configureFolder(
        id,
        'Live',
        b.deviceId!,
        peers: [c.deviceId!],
        selection: SyncSelection(),
      );
      await b.configureFolder(id, 'Live', a.deviceId!, selection: selective);
      await c.configureFolder(
        id,
        'Live',
        a.deviceId!,
        selection: SyncSelection(),
      );
      Future<void> until(
        Future<bool> Function() condition,
        String reason,
      ) async {
        final end = DateTime.now().add(const Duration(seconds: 55));
        while (DateTime.now().isBefore(end)) {
          if (await condition()) return;
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
        fail(
          '$reason\nA: ${a.diagnostics.take(8).join('\n')}\nB: ${b.diagnostics.take(8).join('\n')}',
        );
      }

      await Directory('${source.path}/Reports/nested').create(recursive: true);
      final original = File('${source.path}/Reports/keep[1].txt');
      await original.writeAsString('first');
      await File(
        '${source.path}/Reports/nested/other.txt',
      ).writeAsString('not selected');
      await a.scan(id);
      await until(
        () async => (await b.browse(
          id,
          'Reports',
        )).any((e) => e['name'] == 'keep[1].txt'),
        'Ignored names absent from catalog',
      );
      expect(
        await File('${second.path}/Reports/keep[1].txt').exists(),
        isFalse,
      );
      await until(
        () => File('${third.path}/Reports/nested/other.txt').exists(),
        'Complete replica did not receive descendants',
      );
      selective.select('Reports/keep[1].txt', true);
      await b.setSelection(id, selective);
      await until(
        () => File('${second.path}/Reports/keep[1].txt').exists(),
        'Nested literal selection did not download',
      );
      expect(
        await File('${second.path}/Reports/nested/other.txt').exists(),
        isFalse,
      );
      await File(
        '${third.path}/Reports/keep[1].txt',
      ).writeAsString('edited on third');
      await until(
        () async =>
            await original.readAsString() == 'edited on third' &&
            await File('${second.path}/Reports/keep[1].txt').readAsString() ==
                'edited on third',
        'External edit did not automatically propagate through source',
      );
      final transfers = LiveTransfers();
      final provider = FolderSyncProvider(
        transfers: transfers,
        rootFactory: (_) async => b.root,
        engineFactory: (_) => b,
        autoStart: false,
      );
      await provider.initialize();
      provider.engine = b;
      provider.enabled = true;
      final replica = SyncFolder(
        id: id,
        label: 'Live',
        peer: SendDevice('a' * 64, 'Source', null),
        enginePeer: a.deviceId,
        localPath: second.path,
        selection: selective,
      );
      provider.folders.add(replica);
      expect(
        (await provider.entries(
          replica,
          'Reports',
        )).any((e) => e.name == 'nested'),
        isTrue,
      );
      await provider.select(replica, 'Reports/keep[1].txt', false);
      expect(
        await File('${second.path}/Reports/keep[1].txt').exists(),
        isFalse,
      );
      provider.enabled = false;
      provider.dispose();
      transfers.dispose();
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(await original.readAsString(), 'edited on third');
      expect(await File('${third.path}/Reports/keep[1].txt').exists(), isTrue);
      await b.stop();
      await b.start();
      await b.configurePeer(a.deviceId!, 'Source', a.syncPort!);
      selective.select('Reports', true);
      await b.configureFolder(id, 'Live', a.deviceId!, selection: selective);
      await b.setSelection(id, selective);
      await until(
        () => File('${second.path}/Reports/nested/other.txt').exists(),
        'Selected folder did not include descendants',
      );
      final moved = await source.rename('${root.path}/Temporarily unavailable');
      await expectLater(
        a.configureFolder(id, 'Live', b.deviceId!, peers: [c.deviceId!]),
        throwsException,
      );
      expect(await source.exists(), isFalse);
      expect(
        await File('${third.path}/Reports/nested/other.txt').exists(),
        isTrue,
      );
      await moved.rename(source.path);
      final identity = a.deviceId;
      await a.stop();
      await a.start();
      expect(a.deviceId, identity);
      await a.configurePeer(b.deviceId!, 'Second', b.syncPort!);
      await a.configurePeer(c.deviceId!, 'Third', c.syncPort!);
      await a.configureFolder(
        id,
        'Live',
        b.deviceId!,
        peers: [c.deviceId!],
        selection: SyncSelection(),
      );
      await File('${source.path}/Reports/nested/other.txt').delete();
      await until(
        () async =>
            !await File('${second.path}/Reports/nested/other.txt').exists() &&
            !await File('${third.path}/Reports/nested/other.txt').exists(),
        'External deletion did not propagate after restart',
      );
    },
    skip: Platform.environment['EASYPRIVACY_SYNC_ENGINE'] == null,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
