// Operator-only integration command. Requires explicit folder/recipient inputs.
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as paths;
import 'package:easyprivacy_files/providers/device_transfer_provider.dart';
import 'package:easyprivacy_files/providers/folder_sync_provider.dart';
import 'package:easyprivacy_files/sync/sync_engine.dart';
import 'package:easyprivacy_files/transfer/file_store.dart';

void main() {
  test(
    'invite a paired device to an explicitly authorized source folder',
    () async {
      final location = Platform.environment['EP_SHARE_FOLDER'];
      final recipient = Platform.environment['EP_SHARE_RECIPIENT'];
      final executable = Platform.environment['EASYPRIVACY_SYNC_ENGINE'];
      if (location == null ||
          !paths.isAbsolute(location) ||
          recipient == null ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(recipient) ||
          executable == null) {
        throw StateError(
          'Specify an absolute source folder, paired recipient ID, and bundled engine.',
        );
      }
      final selected = await Directory(location).resolveSymbolicLinks();
      final temporary = await Directory.systemTemp.createTemp(
        'ep-folder-invite-',
      );
      final transfers = DeviceTransferProvider(
        autoStart: false,
        storeFactory: () async =>
            TransferFileStore(Directory('${temporary.path}/received')),
      );
      final sync = FolderSyncProvider(
        transfers: transfers,
        autoStart: false,
        rootFactory: (core) async => Directory(
          paths.join(
            Platform.environment['APPDATA']!,
            'org.easyprivacy',
            'easyprivacy_files',
            'easyprivacy-sync',
            sha256.convert(utf8.encode(core)).toString(),
          ),
        ),
        engineFactory: (root) => SyncEngine(root: root, executable: executable),
      );
      addTearDown(() async {
        await sync.shutdown();
        sync.dispose();
        transfers.dispose();
        if (temporary.absolute.parent.path !=
                Directory.systemTemp.absolute.path ||
            !paths.basename(temporary.path).startsWith('ep-folder-invite-')) {
          throw StateError('Unexpected invitation cleanup path.');
        }
        await temporary.delete(recursive: true);
      });
      await transfers.initialize();
      expect(transfers.connected, isTrue, reason: transfers.error);
      final peers = (await transfers.pairedDevices())
          .where((d) => d.id == recipient)
          .toList();
      expect(
        peers,
        hasLength(1),
        reason: 'The selected device must be paired.',
      );
      expect(
        peers.single.online,
        isTrue,
        reason: 'Open Files and enable Sync on the phone.',
      );
      await sync.initialize();
      expect(sync.initialized, isTrue, reason: sync.error);
      if (!sync.enabled) await sync.setEnabled(true);
      expect(sync.enabled, isTrue, reason: sync.error);
      final existing = sync.folders
          .where((f) => paths.equals(sync.directory(f).path, selected))
          .toList();
      // ignore: avoid_print
      print(
        'SYNC_INVITING: ${paths.basename(selected)} -> ${peers.single.name}',
      );
      if (existing.isEmpty) {
        await sync.create(
          paths.basename(selected),
          peers.single,
          localPath: selected,
        );
      } else {
        expect(existing.single.peer.id, recipient);
        if (existing.single.enginePeer == null) {
          await sync.retry(existing.single);
        }
      }
      final folder = sync.folders.singleWhere(
        (f) => paths.equals(sync.directory(f).path, selected),
      );
      expect(folder.enginePeer, isNotNull, reason: sync.error);
      await sync.engine!.scan(folder.id);
      // ignore: avoid_print
      print(
        'SYNC_INVITATION_ACCEPTED: ${folder.id}; source location saved for the desktop app.',
      );
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (DateTime.now().isBefore(deadline)) {
        final status = await sync.engine!.status(folder.id);
        final connections =
            await sync.engine!.call('GET', 'system/connections') as Map;
        final peer =
            (connections['connections'] as Map)[folder.enginePeer] as Map?;
        if ((status['localFiles'] as num? ?? 0) >= 2 &&
            peer?['connected'] == true) {
          // ignore: avoid_print
          print(
            'SYNC_SOURCE_READY: ${status['localFiles']} files indexed; phone engine connected.',
          );
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      // ignore: avoid_print
      print(
        'SYNC_SOURCE_SAVED: desktop app will continue connecting after restart.',
      );
    },
    skip:
        !Platform.isWindows ||
        Platform.environment['EP_SHARE_FOLDER_RUN'] != '1',
    timeout: const Timeout(Duration(minutes: 7)),
  );
}
