import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:easyprivacy_files/providers/device_transfer_provider.dart';
import 'package:easyprivacy_files/providers/folder_sync_provider.dart';
import 'package:easyprivacy_files/sync/sync_engine.dart';
import 'package:easyprivacy_files/sync/sync_paths.dart';
import 'package:easyprivacy_files/transfer/secure_channel.dart';
import 'package:easyprivacy_files/transfer/send_engine.dart';

const corePin = 'test-core';
final peer = SendDevice('b' * 64, 'Test phone', 'receiver.test');
final engineId = List.filled(8, 'AAAAAAA').join('-');
final otherEngine = List.filled(8, 'BBBBBBB').join('-');
final folderId = 'ep-${'c' * 32}';
final testIdentity = TransferIdentity(
  core: corePin,
  device: 'a' * 64,
  sign: (_, _, _, _) async => {},
  isPaired: (_) async => true,
);

class FakeChannel implements SecureTransferChannel {
  final messages = <Map<String, Object?>>[];
  @override
  Future<void> control(Map<String, Object?> message) async =>
      messages.add(message);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeTransfers extends DeviceTransferProvider {
  FakeTransfers() : super(autoStart: false);
  final modes = <String>{};
  @override
  Future<TransferIdentity> identity() async => testIdentity;
  @override
  Future<void> receiveFor(String mode, bool enabled) async {
    if (enabled) {
      modes.add(mode);
    } else {
      modes.remove(mode);
    }
  }
}

class FakeEngine extends SyncEngine {
  FakeEngine(Directory directory) : super(root: directory);
  bool active = false;
  final configured = <String, bool>{};
  final reconciled = <String>{};
  @override
  bool get running => active;
  @override
  Future<void> start() async {
    active = true;
    deviceId = otherEngine;
  }

  @override
  Future<void> stop() async {
    active = false;
  }

  @override
  Future<void> reconcile(Set<String> ids, Set<String> peers) async =>
      reconciled.addAll(ids);
  @override
  Future<void> configurePeer(String id, String label, int port) async {}
  @override
  Future<void> configureFolder(
    String id,
    String label,
    String peer, {
    bool paused = false,
    Iterable<String>? peers,
    SyncSelection? selection,
  }) async {
    configured[id] = paused;
    await folder(id).create(recursive: true);
  }

  @override
  Future<void> removeFolder(String id) async => configured.remove(id);
  @override
  Future<dynamic> call(
    String method,
    String resource, {
    Object? body,
    Map<String, String>? query,
  }) async => {'connections': {}};
  @override
  Future<Map<String, dynamic>> status(String id) async => {
    'state': 'idle',
    'needTotalItems': 0,
  };
  @override
  Future<List<Map<String, dynamic>>> browse(String id, String relative) async =>
      [];
  @override
  Future<void> scan(String id) async {}
}

void main() {
  late Directory root;
  late FakeTransfers transfers;
  late FakeEngine engine;
  late FolderSyncProvider provider;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ep-sync-provider-test-');
    transfers = FakeTransfers();
    engine = FakeEngine(root);
    provider = FolderSyncProvider(
      transfers: transfers,
      rootFactory: (_) async => root,
      engineFactory: (_) => engine,
      autoStart: false,
    );
    await provider.initialize();
    await provider.setEnabled(true);
    expect(provider.error, isNull);
  });
  tearDown(() async {
    await provider.setEnabled(false);
    provider.dispose();
    transfers.dispose();
    await root.delete(recursive: true);
  });
  Map<String, dynamic> invite({String? device}) => {
    'type': 'sync-invite',
    'folder_id': folderId,
    'label': 'Shared tests',
    'device_id': device ?? engineId,
  };
  Future<void> incoming(FakeChannel channel, {String? device}) =>
      transfers.handlers['sync-invite']!(
        channel,
        testIdentity,
        peer,
        invite(device: device),
      );

  test(
    'invitation writes no folder or grant before explicit approval',
    () async {
      final channel = FakeChannel();
      final pending = incoming(channel);
      await Future<void>.delayed(Duration.zero);
      expect(provider.invitation, isNotNull);
      expect(provider.folders, isEmpty);
      expect(await Directory('${root.path}/folders').exists(), isFalse);
      provider.decide(false);
      await pending;
      expect(channel.messages.single['type'], 'sync-decline');
      expect(provider.folders, isEmpty);
    },
  );

  test('an incomplete import cannot replace an existing synced file', () async {
    final pending = incoming(FakeChannel());
    await Future<void>.delayed(Duration.zero);
    provider.decide(true);
    await pending;
    final folder = provider.folders.single;
    final file = await File(
      '${provider.directory(folder).path}/example.txt',
    ).writeAsString('keep');
    await expectLater(
      provider.importFile(
        folder,
        TransferSource(
          name: 'example.txt',
          size: 10,
          read: (_, _) => const Stream.empty(),
        ),
        replace: true,
      ),
      throwsA(isA<TransferFailure>()),
    );
    expect(await file.readAsString(), 'keep');
    final remaining = await provider.directory(folder).list().toList();
    expect(remaining, hasLength(1));
    expect(
      await FileSystemEntity.identical(remaining.single.path, file.path),
      isTrue,
    );
  });
  test(
    'accepted grant pins identity, pause and stop preserve local files',
    () async {
      final channel = FakeChannel();
      final pending = incoming(channel);
      await Future<void>.delayed(Duration.zero);
      provider.decide(true);
      await pending;
      final folder = provider.folders.single;
      expect(folder.enginePeer, engineId);
      expect(channel.messages.single['type'], 'sync-accepted');
      final file = File('${provider.directory(folder).path}/example.txt');
      await file.writeAsString('retained');
      await expectLater(
        incoming(FakeChannel(), device: otherEngine),
        throwsA(isA<TransferFailure>()),
      );
      await provider.pause(folder, true);
      expect(engine.configured[folder.id], isTrue);
      expect(await file.readAsString(), 'retained');
      await provider.remove(folder);
      expect(folder.linked, isFalse);
      expect(engine.configured, isEmpty);
      expect(await file.readAsString(), 'retained');
      await provider.setEnabled(false);
      provider.dispose();
      provider = FolderSyncProvider(
        transfers: transfers,
        rootFactory: (_) async => root,
        engineFactory: (_) => engine,
        autoStart: false,
      );
      await provider.initialize();
      await provider.setEnabled(true);
      expect(provider.folders.single.linked, isFalse);
      expect(engine.configured, isEmpty);
      expect(engine.reconciled, isEmpty);
      await provider.deleteLocalCopy(provider.folders.single);
      expect(await file.exists(), isFalse);
      expect(provider.folders, isEmpty);
    },
  );

  test(
    'deletion is confined to an accepted folder and excludes engine metadata',
    () async {
      final pending = incoming(FakeChannel());
      await Future<void>.delayed(Duration.zero);
      provider.decide(true);
      await pending;
      final folder = provider.folders.single;
      final outside = await File(
        '${root.path}/private-key',
      ).writeAsString('keep');
      final metadata = await File(
        '${provider.directory(folder).path}/.stignore',
      ).writeAsString('keep');
      await expectLater(
        provider.deleteFile(folder, outside),
        throwsA(isA<TransferFailure>()),
      );
      await expectLater(
        provider.deleteFile(folder, metadata),
        throwsA(isA<TransferFailure>()),
      );
      expect(await outside.readAsString(), 'keep');
      expect(await metadata.readAsString(), 'keep');
      await provider.setEnabled(false);
      final file = await File(
        '${provider.directory(folder).path}/example.txt',
      ).writeAsString('delete');
      await provider.deleteFile(folder, file);
      expect(await file.exists(), isFalse);
      await provider.deleteLocalCopy(folder);
      expect(
        provider.folders,
        hasLength(1),
      ); // A live link cannot be erased this way.
    },
  );

  test(
    'invalid persisted grants fail atomically, including after a retry',
    () async {
      await provider.setEnabled(false);
      provider.dispose();
      final folder = SyncFolder(
        id: folderId,
        label: 'Duplicate',
        peer: peer,
        enginePeer: engineId,
      );
      await File('${root.path}/state.json').writeAsString(
        jsonEncode({
          'version': 1,
          'core': corePin,
          'enabled': true,
          'folders': [folder.toJson(), folder.toJson()],
        }),
      );
      provider = FolderSyncProvider(
        transfers: transfers,
        rootFactory: (_) async => root,
        engineFactory: (_) => engine,
        autoStart: false,
      );
      await provider.initialize();
      await provider.initialize();
      expect(provider.initialized, isFalse);
      expect(provider.enabled, isFalse);
      expect(provider.folders, isEmpty);
    },
  );
  test(
    'source folders stay complete and forgetting an external folder preserves every file',
    () async {
      final chosen = await Directory.systemTemp.createTemp(
        'ep-chosen-source-test-',
      );
      addTearDown(() => chosen.delete(recursive: true));
      final original = await File(
        '${chosen.path}/original.txt',
      ).writeAsString('keep original');
      final location = await provider.validateLocation(chosen.path);
      final folder = SyncFolder(
        id: folderId,
        label: 'Source',
        peer: peer,
        enginePeer: engineId,
        localPath: location,
        isSource: true,
      );
      provider.folders.add(folder);
      await expectLater(
        provider.setSelective(folder, true),
        throwsA(isA<TransferFailure>()),
      );
      await provider.remove(folder);
      await provider.deleteLocalCopy(folder);
      expect(await original.readAsString(), 'keep original');
      expect(provider.folders, isEmpty);
    },
  );
  test(
    'an aliased app-support path restores private folders without reporting a move',
    () async {
      await provider.setEnabled(false);
      provider.dispose();
      final physical = await Directory('${root.path}/physical').create();
      final alias = Link('${root.path}/app-support-alias');
      if (Platform.isWindows) {
        // Directory junctions need no symlink privilege on Windows.
        final result = await Process.run(
          'powershell.exe',
          [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            r'New-Item -ItemType Junction -Path $env:EP_SYNC_ALIAS -Target $env:EP_SYNC_TARGET -ErrorAction Stop | Out-Null',
          ],
          environment: {
            'EP_SYNC_ALIAS': alias.path,
            'EP_SYNC_TARGET': physical.path,
          },
        );
        expect(result.exitCode, 0, reason: result.stderr.toString());
      } else {
        await alias.create(physical.path);
      }
      final support = await Directory('${alias.path}/support').create();
      final disk = await Directory(
        '${physical.path}/support/folders/$folderId',
      ).create(recursive: true);
      final original = await File('${disk.path}/Test.md').writeAsString('keep');
      final restored = SyncFolder(
        id: folderId,
        label: 'Test',
        peer: peer,
        enginePeer: engineId,
        selection: SyncSelection(selective: true, rules: {'Test.md': true}),
      );
      await File('${support.path}/state.json').writeAsString(
        jsonEncode({
          'version': 2,
          'core': corePin,
          'enabled': true,
          'folders': [restored.toJson()],
        }),
      );
      // The strict guard must still reject unresolved/redirected roots.
      await expectLater(
        syncLocalPath(Directory('${support.path}/folders/$folderId'), ''),
        throwsA(isA<TransferFailure>()),
      );
      Future<void> restore() async {
        engine = FakeEngine(support);
        provider = FolderSyncProvider(
          transfers: transfers,
          rootFactory: (_) async => support,
          engineFactory: (_) => engine,
          autoStart: false,
        );
        await provider.initialize();
        expect(provider.error, isNull);
        expect(provider.enabled, isTrue);
        // Saved engine paths retain their spelling; identity/config need no migration.
        expect(engine.root.path, support.path);
      }

      await restore();
      final folder = provider.folders.single;
      expect((await provider.entries(folder, '')).single.name, 'Test.md');
      expect(folder.selection.rules, {'Test.md': true});
      await expectLater(
        provider.validateLocation('${physical.path}/support'),
        throwsA(isA<TransferFailure>()),
      );
      await provider.createDirectory(folder, 'nested');
      await provider.importFile(
        folder,
        TransferSource(
          name: 'added.txt',
          size: 4,
          read: (_, _) => Stream.value([116, 101, 115, 116]),
        ),
        relative: 'nested',
      );
      await provider.move(folder, 'nested/added.txt', 'nested/renamed.txt');
      expect(
        await File('${disk.path}/nested/renamed.txt').readAsString(),
        'test',
      );
      await provider.deleteEntry(folder, 'nested/renamed.txt');
      await provider.shutdown();
      provider.dispose();
      await restore();
      expect(
        (await provider.entries(
          provider.folders.single,
          '',
        )).map((entry) => entry.name),
        contains('Test.md'),
      );
      expect(provider.folders.single.selection.rules['Test.md'], isTrue);
      expect(await original.readAsString(), 'keep');
      final reloaded = provider.folders.single;
      await provider.remove(reloaded);
      await provider.deleteLocalCopy(reloaded);
      expect(await original.exists(), isFalse);
      expect(await File('${support.path}/state.json').exists(), isTrue);
      await provider.shutdown();
    },
  );
  test(
    'nested file management stays confined to its shared directory',
    () async {
      final pending = incoming(FakeChannel());
      await Future<void>.delayed(Duration.zero);
      provider.decide(true);
      await pending;
      final folder = provider.folders.single;
      await provider.createDirectory(folder, 'nested');
      await provider.importFile(
        folder,
        TransferSource(
          name: 'example.txt',
          size: 4,
          read: (_, _) => Stream.value([116, 101, 115, 116]),
        ),
        relative: 'nested',
      );
      await provider.move(folder, 'nested/example.txt', 'nested/renamed.txt');
      expect(
        await File(
          '${provider.directory(folder).path}/nested/renamed.txt',
        ).readAsString(),
        'test',
      );
      await expectLater(
        provider.move(folder, 'nested', '../outside'),
        throwsA(isA<TransferFailure>()),
      );
      await expectLater(
        provider.deleteEntry(folder, '.stfolder'),
        throwsA(isA<TransferFailure>()),
      );
      await provider.deleteEntry(folder, 'nested');
      expect(
        await Directory('${provider.directory(folder).path}/nested').exists(),
        isFalse,
      );
    },
  );
}
