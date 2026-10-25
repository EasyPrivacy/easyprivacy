import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as paths;
import 'package:path_provider/path_provider.dart';
import '../sync/core_sync_bridge.dart';
import '../sync/sync_engine.dart';
import '../sync/sync_paths.dart';
import '../sync/documents_mirror.dart';
import 'package:flutter/services.dart';
import '../transfer/file_store.dart';
import '../transfer/secure_channel.dart';
import '../transfer/send_engine.dart';
import 'device_transfer_provider.dart';

class SyncFolder {
  SyncFolder({
    required this.id,
    required this.label,
    required this.peer,
    this.enginePeer,
    this.paused = false,
    this.linked = true,
    this.localPath,
    this.isSource = false,
    this.useDocuments = false,
    this.documentsPath,
    SyncSelection? selection,
    List<SyncFolderMember>? additionalPeers,
  }) : selection = selection ?? SyncSelection(),
       additionalPeers = additionalPeers ?? [];
  final String id, label;
  final SendDevice peer;
  String? enginePeer;
  bool paused;
  bool linked;
  final String? localPath;
  final bool isSource;
  bool useDocuments;
  String? documentsPath;
  SyncSelection selection;
  final List<SyncFolderMember> additionalPeers;
  Iterable<SyncFolderMember> get members sync* {
    yield SyncFolderMember(peer, enginePeer);
    yield* additionalPeers;
  }

  Iterable<String> get enginePeers =>
      members.map((p) => p.engineId).whereType<String>();
  String state = 'Waiting for the other device';
  int files = 0, bytes = 0;
  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'peer': peer.id,
    'peer_name': peer.name,
    'engine_peer': enginePeer,
    'paused': paused,
    'linked': linked,
    'local_path': localPath,
    'source': isSource,
    'documents': useDocuments,
    'documents_path': documentsPath,
    'selection': selection.toJson(),
    'additional_peers': additionalPeers.map((p) => p.toJson()).toList(),
  };
  factory SyncFolder.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String,
        label = json['label'] as String,
        peer = json['peer'] as String,
        engine = json['engine_peer'] as String?;
    if (!validSyncFolder(id) ||
        label.trim().isEmpty ||
        label.length > 80 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(peer) ||
        (engine != null && !validSyncDevice(engine))) {
      throw const FormatException('Invalid Sync settings.');
    }
    final location = json['local_path'] as String?;
    if (location != null &&
        (!paths.isAbsolute(location) || location.length > 32760)) {
      throw const FormatException('Invalid Sync folder location.');
    }
    final additional = (json['additional_peers'] as List? ?? [])
        .map(
          (v) => SyncFolderMember.fromJson(Map<String, dynamic>.from(v as Map)),
        )
        .toList();
    if (additional.length > 2 ||
        {peer, ...additional.map((m) => m.peer.id)}.length !=
            additional.length + 1) {
      throw const FormatException('Invalid Sync folder devices.');
    }
    return SyncFolder(
      id: id,
      label: label,
      peer: SendDevice(peer, json['peer_name'] as String, null),
      enginePeer: engine,
      paused: json['paused'] as bool,
      linked: json['linked'] as bool? ?? true,
      localPath: location,
      isSource: json['source'] == true,
      useDocuments: json['documents'] == true,
      documentsPath: json['documents_path'] as String?,
      selection: SyncSelection.fromJson(
        Map<String, dynamic>.from(json['selection'] as Map? ?? {}),
      ),
      additionalPeers: additional,
    );
  }
}

class SyncFolderMember {
  SyncFolderMember(this.peer, this.engineId);
  final SendDevice peer;
  String? engineId;
  Map<String, Object?> toJson() => {
    'peer': peer.id,
    'name': peer.name,
    'engine': engineId,
  };
  factory SyncFolderMember.fromJson(Map<String, dynamic> json) {
    final peer = json['peer'] as String, engine = json['engine'] as String?;
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(peer) ||
        (engine != null && !validSyncDevice(engine))) {
      throw const FormatException('Invalid Sync folder device.');
    }
    return SyncFolderMember(
      SendDevice(peer, json['name'] as String, null),
      engine,
    );
  }
}

class SyncInvitation {
  SyncInvitation(this.id, this.label, this.peer, this.enginePeer);
  final String id, label, enginePeer;
  final SendDevice peer;
  final decision = Completer<bool>();
  String? localPath;
  SyncSelection selection = SyncSelection();
}

class FolderSyncProvider extends ChangeNotifier {
  FolderSyncProvider({
    required this.transfers,
    this.rootFactory,
    this.engineFactory,
    bool autoStart = true,
  }) {
    transfers.handlers['sync-invite'] = _invitation;
    transfers.handlers['sync-connect'] = _connection;
    if (autoStart) unawaited(initialize());
  }
  final DeviceTransferProvider transfers;
  final Future<Directory> Function(String core)? rootFactory;
  final SyncEngine Function(Directory root)? engineFactory;
  SyncEngine? engine;
  CoreSyncBridge? _bridge;
  Directory? root;
  Directory? _resolvedRoot;
  String? _core;
  final List<SyncFolder> folders = [];
  SyncInvitation? invitation;
  bool enabled = false, busy = false, initialized = false;
  String? error;
  bool _disposed = false, _refreshing = false;
  Timer? _timer;
  Future<void> _saves = Future.value();
  Future<void>? _initializing;
  final _mirrors = <String, DocumentsMirror>{};
  final _unavailable = <String>{};
  SecureTransferChannel? _inviteChannel;
  Future<void>? _shuttingDown;
  void changed() {
    if (!_disposed) notifyListeners();
  }

  Directory directory(SyncFolder folder) => Directory(
    folder.localPath ?? paths.join(_resolvedRoot!.path, 'folders', folder.id),
  );

  Future<String> validateLocation(String location, {String? folderId}) async {
    final selected = Directory(location);
    if (!selected.isAbsolute ||
        await FileSystemEntity.type(location, followLinks: false) !=
            FileSystemEntityType.directory) {
      throw const TransferFailure('Choose an existing folder on this device.');
    }
    final canonical = await selected.resolveSymbolicLinks();
    if (paths.dirname(canonical) == canonical ||
        paths.equals(canonical, _resolvedRoot!.path) ||
        paths.isWithin(canonical, _resolvedRoot!.path) ||
        paths.isWithin(_resolvedRoot!.path, canonical)) {
      throw const TransferFailure(
        'Choose a data folder outside the Files configuration directory.',
      );
    }
    for (final folder in folders.where((f) => f.id != folderId)) {
      final other = directory(folder).absolute.path;
      if (paths.equals(canonical, other) ||
          paths.isWithin(canonical, other) ||
          paths.isWithin(other, canonical)) {
        throw const TransferFailure(
          'This location overlaps an existing synced folder.',
        );
      }
    }
    for (final name in ['.stfolder', '.stignore', '.stversions']) {
      if (await FileSystemEntity.type(
            paths.join(canonical, name),
            followLinks: false,
          ) !=
          FileSystemEntityType.notFound) {
        throw const TransferFailure(
          'This folder already contains Sync metadata. Choose a different folder.',
        );
      }
    }
    return canonical;
  }

  Future<void> initialize() {
    if (_initializing != null) return _initializing!;
    final pending = _initialize();
    _initializing = pending;
    return pending.whenComplete(() => _initializing = null);
  }

  Future<void> _initialize() async {
    if (initialized || _disposed) return;
    try {
      final identity = await transfers.identity();
      _core = identity.core;
      root = rootFactory == null
          ? Directory(
              paths.join(
                (await getApplicationSupportDirectory()).path,
                'easyprivacy-sync',
                sha256.convert(utf8.encode(_core!)).toString(),
              ),
            )
          : await rootFactory!(_core!);
      await root!.create(recursive: true);
      // Android's application-support path can contain an OS-managed alias.
      // Pin private file operations to its resolved location, while retaining
      // the existing engine/config paths so an update preserves saved links.
      _resolvedRoot = Directory(await root!.resolveSymbolicLinks());
      final file = File(paths.join(root!.path, 'state.json'));
      var savedEnabled = false;
      if (await file.exists()) {
        if (await file.length() > 1024 * 1024) {
          throw const FormatException('Sync settings are too large.');
        }
        final json =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        if (![1, 2].contains(json['version']) || json['core'] != _core) {
          throw const FormatException('Sync belongs to a different core.');
        }
        final loaded = (json['folders'] as List)
            .map(
              (v) => SyncFolder.fromJson(Map<String, dynamic>.from(v as Map)),
            )
            .toList();
        if (loaded.length > 8 ||
            loaded.map((f) => f.id).toSet().length != loaded.length ||
            loaded
                    .where((f) => f.linked)
                    .expand((f) => f.members)
                    .map((m) => m.peer.id)
                    .toSet()
                    .length >
                3) {
          throw const FormatException('Invalid Sync folders.');
        }
        folders
          ..clear()
          ..addAll(loaded);
        savedEnabled = json['enabled'] == true;
      }
      initialized = true;
      if (savedEnabled) await setEnabled(true);
    } catch (e) {
      error = e.toString();
    }
    changed();
  }

  Future<void> _save() {
    final body = jsonEncode({
      'version': 2,
      'core': _core,
      'enabled': enabled,
      'folders': folders.map((f) => f.toJson()).toList(),
    });
    final pending = _saves.then((_) async {
      final temp = File(paths.join(root!.path, 'state.tmp'));
      await temp.writeAsString(body, flush: true);
      await temp.rename(paths.join(root!.path, 'state.json'));
    });
    _saves = pending.then<void>((_) {}, onError: (Object _) {});
    return pending;
  }

  bool _allowed(SyncPeer peer) =>
      enabled &&
      engine?.running == true &&
      folders.any(
        (f) =>
            f.linked &&
            !f.paused &&
            f.members.any(
              (m) => m.peer.id == peer.coreId && m.engineId == peer.engineId,
            ),
      );
  Future<void> setEnabled(bool value, {bool persist = true}) async {
    if (busy || _disposed) return;
    if (!initialized) {
      await initialize();
      if (!initialized) return;
    }
    busy = true;
    changed();
    try {
      if (!value) {
        enabled = false;
        if (persist) await _save();
        _timer?.cancel();
        _timer = null;
        await _bridge?.close();
        _bridge = null;
        await engine?.stop();
        await transfers.receiveFor('sync', false);
      } else {
        if ((await transfers.identity()).core != _core) {
          throw const TransferFailure(
            'Reconnect to the core used by these synced folders.',
          );
        }
        engine ??= engineFactory?.call(root!) ?? SyncEngine(root: root!);
        for (final folder in folders) {
          if (folder.localPath != null) {
            engine!.registerLocation(folder.id, directory(folder));
          }
        }
        await engine!.start();
        await engine!.reconcile(
          folders
              .where((f) => f.linked && f.enginePeer != null)
              .map((f) => f.id)
              .toSet(),
          folders
              .where((f) => f.linked && f.enginePeer != null)
              .expand((f) => f.enginePeers)
              .toSet(),
        );
        enabled = true;
        _bridge = CoreSyncBridge(
          engine: engine!,
          allowed: _allowed,
          open: (peer) =>
              transfers.openPeer(SendDevice(peer.coreId, peer.name, null)),
        );
        for (final folder in folders.where(
          (f) => f.enginePeer != null && f.linked,
        )) {
          try {
            await _configure(folder);
          } catch (e) {
            _unavailable.add(folder.id);
            folder.state = e.toString();
          }
        }
        await transfers.receiveFor('sync', true);
        await _save();
        _timer?.cancel();
        _timer = Timer.periodic(
          const Duration(seconds: 5),
          (_) => unawaited(refresh()),
        );
        await refresh();
      }
      error = null;
    } catch (e) {
      error = e.toString();
      enabled = false;
      await _bridge?.close();
      _bridge = null;
      await engine?.stop();
      await transfers.receiveFor('sync', false);
    } finally {
      busy = false;
      changed();
    }
  }

  Future<void> _configure(SyncFolder folder) async {
    if (folder.useDocuments) await _prepareDocuments(folder);
    for (final member in folder.members.where((m) => m.engineId != null)) {
      await _bridge!.add(
        SyncPeer(member.peer.id, member.engineId!, member.peer.name),
      );
    }
    await engine!.configureFolder(
      folder.id,
      folder.label,
      folder.enginePeer!,
      peers: folder.enginePeers,
      paused: folder.paused,
      selection: folder.selection,
    );
    _unavailable.remove(folder.id);
  }

  String location(SyncFolder folder) =>
      folder.documentsPath ?? directory(folder).path;

  Future<void> _prepareDocuments(SyncFolder folder) async {
    if (!Platform.isAndroid) {
      throw const TransferFailure(
        'This folder needs its Android Documents location.',
      );
    }
    if (_mirrors.containsKey(folder.id)) return;
    final documents = AndroidFolderDocuments(
      '${sha256.convert(utf8.encode(_core!))}/${folder.id}',
      directory(folder),
    );
    folder.documentsPath = await documents.prepare(folder.label);
    _mirrors[folder.id] = DocumentsMirror(
      local: directory(folder),
      documents: documents,
      journal: File(paths.join(root!.path, 'documents', '${folder.id}.json')),
    );
    await _save();
  }

  Future<void> placeInDocuments(SyncFolder folder) async {
    if (!await AndroidFolderDocuments.chooseRoot()) return;
    folder.useDocuments = true;
    await _prepareDocuments(folder);
    await _mirrors[folder.id]!.reconcile(folder.selection);
    await _save();
    changed();
  }

  Future<void> open(
    SyncFolder folder,
    String relative, {
    bool edit = false,
  }) async {
    final path = await syncLocalPath(directory(folder), relative);
    if (!await File(path).exists() && !folder.useDocuments) {
      throw const TransferFailure(
        'Select this file for sync and wait for its local copy.',
      );
    }
    if (folder.useDocuments) {
      await _prepareDocuments(folder);
      await _mirrors[folder.id]!.reconcile(folder.selection);
      await _mirrors[folder.id]!.documents.open(relative, edit);
    } else if (Platform.isWindows) {
      await const MethodChannel(
        'org.easyprivacy/files_presence',
      ).invokeMethod<void>('openFile', {'path': path, 'edit': edit});
    } else {
      throw const TransferFailure(
        'Place this folder in Documents before opening files with another app.',
      );
    }
  }

  Future<void> openDirectory(SyncFolder folder) async {
    final path = await syncLocalPath(directory(folder), '');
    if (Platform.isWindows) {
      await const MethodChannel(
        'org.easyprivacy/files_presence',
      ).invokeMethod<void>('openFolder', {'path': path});
    }
  }

  Future<void> refresh() async {
    if (_disposed || !enabled || _refreshing || busy) return;
    _refreshing = true;
    try {
      final connections =
          await engine!.call('GET', 'system/connections') as Map;
      for (final folder in folders) {
        if (!folder.linked) {
          folder.state = 'Local copy · link removed';
          continue;
        }
        if (folder.enginePeer == null) {
          folder.state = 'Waiting for acceptance';
          continue;
        }
        if (!await directory(folder).exists()) {
          folder.state = 'Folder unavailable · reconnect its location';
          continue;
        }
        if (_unavailable.contains(folder.id)) {
          try {
            await _configure(folder);
          } catch (e) {
            folder.state = e.toString();
            continue;
          }
        }
        if (folder.useDocuments && !folder.paused) {
          try {
            await _prepareDocuments(folder);
            if (await _mirrors[folder.id]!.reconcile(folder.selection)) {
              await engine!.scan(folder.id);
            }
          } catch (e) {
            folder.state = e.toString();
            continue;
          }
        }
        final status = await engine!.status(folder.id);
        folder.files = (status['globalFiles'] as num?)?.toInt() ?? 0;
        folder.bytes = (status['globalBytes'] as num?)?.toInt() ?? 0;
        final connected = folder.enginePeers.any(
          (id) =>
              ((connections['connections'] as Map)[id] as Map?)?['connected'] ==
              true,
        );
        folder.state = folder.paused
            ? 'Paused'
            : (status['pullErrors'] as num? ?? 0) > 0
            ? 'Needs attention'
            : (status['errors'] as num? ?? 0) > 0
            ? 'Folder needs attention'
            : !connected
            ? 'Waiting for the other device'
            : status['state'] == 'idle' && status['needTotalItems'] == 0
            ? 'Synced'
            : 'Syncing';
      }
      error = null;
    } catch (e) {
      error = e.toString();
    } finally {
      _refreshing = false;
      changed();
    }
  }

  Future<List<SyncEntry>> entries(SyncFolder folder, String relative) async {
    final target = Directory(await syncLocalPath(directory(folder), relative));
    final result = <String, SyncEntry>{};
    if (enabled && folder.enginePeer != null) {
      for (final node in await engine!.browse(folder.id, relative)) {
        final name = node['name'];
        if (name is! String || name.contains('/') || name.contains('\\')) {
          continue;
        }
        final path = [if (relative.isNotEmpty) relative, name].join('/');
        try {
          syncRelative(path);
        } catch (_) {
          continue;
        }
        final type = node['type'] as String? ?? '';
        if (!type.endsWith('_DIRECTORY') && !type.endsWith('_FILE')) continue;
        result[name] = SyncEntry(
          path,
          directory: type.endsWith('_DIRECTORY'),
          local: false,
          size: (node['size'] as num?)?.toInt() ?? 0,
        );
      }
    }
    if (await target.exists()) {
      await for (final entry in target.list(followLinks: false)) {
        final name = paths.basename(entry.path);
        if (syncMetadataName(name) || entry is Link) continue;
        final path = [if (relative.isNotEmpty) relative, name].join('/');
        try {
          syncRelative(path);
        } catch (_) {
          continue;
        }
        result[name] = SyncEntry(
          path,
          directory: entry is Directory,
          local: true,
          size: entry is File ? await entry.length() : 0,
        );
      }
    }
    if (folder.useDocuments) {
      await _prepareDocuments(folder);
      final public = await _mirrors[folder.id]!.documents.snapshot();
      for (final entry in public.entries) {
        final parent = entry.key.contains('/')
            ? entry.key.substring(0, entry.key.lastIndexOf('/'))
            : '';
        if (parent != relative) continue;
        final name = entry.key.split('/').last;
        final existing = result[name];
        result[name] = SyncEntry(
          entry.key,
          directory: entry.value == 'directory',
          local: true,
          size: existing?.size ?? -1,
        );
      }
    }
    return result.values.toList()..sort(
      (a, b) => a.directory != b.directory
          ? (a.directory ? -1 : 1)
          : a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
  }

  Future<void> setSelective(SyncFolder folder, bool selective) async {
    if (folder.isSource && selective) {
      throw const TransferFailure(
        'The source folder always shares its complete contents.',
      );
    }
    final next = SyncSelection(
      selective: selective,
      rules: folder.selection.rules,
    );
    await _selection(folder, next);
  }

  Future<void> select(SyncFolder folder, String path, bool selected) async {
    if (!folder.selection.selective || folder.isSource) return;
    final next = SyncSelection(selective: true, rules: folder.selection.rules)
      ..select(path, selected);
    await _selection(folder, next);
  }

  Future<void> _selection(SyncFolder folder, SyncSelection next) async {
    if (!enabled || folder.paused || busy) {
      throw const TransferFailure(
        'Enable and resume this folder before changing its selection.',
      );
    }
    busy = true;
    changed();
    var paused = false;
    try {
      while (_refreshing) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      await engine!.scan(folder.id);
      final status = await engine!.status(folder.id);
      if (status['state'] != 'idle' || status['needTotalItems'] != 0) {
        throw const TransferFailure(
          'Wait for current changes to sync before removing local copies.',
        );
      }
      final previous = folder.selection;
      final base = directory(folder);
      final copies = <String, String>{};
      if (next.selective) {
        await syncLocalPath(base, '');
        await for (final entity in base.list(
          recursive: true,
          followLinks: false,
        )) {
          final relative = paths
              .relative(entity.path, from: base.path)
              .split(paths.separator)
              .join('/');
          if (relative.split('/').any(syncMetadataName) ||
              entity is! File ||
              !previous.includes(relative) ||
              next.includes(relative)) {
            continue;
          }
          await syncLocalPath(base, relative);
          final indexed =
              await engine!.call(
                    'GET',
                    'db/file',
                    query: {'folder': folder.id, 'file': relative},
                  )
                  as Map;
          final local = indexed['local'] as Map,
              global = indexed['global'] as Map;
          final available = indexed['availability'] as List? ?? [];
          if (local['deleted'] != false ||
              local['invalid'] != false ||
              global['deleted'] != false ||
              jsonEncode(local['version']) != jsonEncode(global['version']) ||
              !available.any(
                (v) =>
                    v['id'] == folder.enginePeer && v['fromTemporary'] != true,
              )) {
            throw const TransferFailure(
              'Keep this copy until its latest changes are available on the source device.',
            );
          }
          copies[relative] = (await sha256.bind(entity.openRead()).first)
              .toString();
        }
      }
      await engine!.configureFolder(
        folder.id,
        folder.label,
        folder.enginePeer!,
        peers: folder.enginePeers,
        paused: true,
      );
      paused = true;
      // Ignore first, then evict: local removals must never become shared deletes.
      await engine!.setSelection(folder.id, next);
      folder.selection = next;
      await _save();
      await _mirrors[folder.id]?.evict(next);
      for (final copy in copies.entries) {
        final file = File(await syncLocalPath(base, copy.key));
        if (!await file.exists()) continue;
        if ((await sha256.bind(file.openRead()).first).toString() !=
            copy.value) {
          throw const TransferFailure(
            'A local file changed during selection. Its copy has been kept.',
          );
        }
        await file.delete();
      }
    } finally {
      try {
        if (paused) {
          await engine!.configureFolder(
            folder.id,
            folder.label,
            folder.enginePeer!,
            peers: folder.enginePeers,
            paused: folder.paused,
          );
        }
      } finally {
        busy = false;
        changed();
      }
    }
    await engine!.scan(folder.id);
  }

  Future<void> createDirectory(SyncFolder folder, String relative) async {
    final target = await syncLocalPath(directory(folder), relative);
    if (await FileSystemEntity.type(target, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const TransferFailure('An item with that name already exists.');
    }
    await Directory(target).create(recursive: true);
    if (folder.selection.selective) await select(folder, relative, true);
    if (enabled && !folder.paused) await engine!.scan(folder.id);
  }

  Future<void> move(SyncFolder folder, String from, String to) async {
    if (from == to || to.startsWith('$from/')) {
      throw const TransferFailure(
        'Choose a different destination inside the synced folder.',
      );
    }
    final source = await syncLocalPath(directory(folder), from);
    final destination = await syncLocalPath(directory(folder), to);
    if (await FileSystemEntity.type(destination, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const TransferFailure('An item with that name already exists.');
    }
    final type = await FileSystemEntity.type(source, followLinks: false);
    if (folder.selection.selective) {
      // Select the destination first so the engine can publish the move.
      await select(folder, to, true);
    }
    if (folder.useDocuments) {
      await _prepareDocuments(folder);
      await _mirrors[folder.id]!.reconcile(folder.selection);
      await _mirrors[folder.id]!.documents.move(from, to);
      if (type == FileSystemEntityType.notFound) return;
    }
    if (type == FileSystemEntityType.directory) {
      await Directory(source).rename(destination);
    } else if (type == FileSystemEntityType.file) {
      await File(source).rename(destination);
    } else {
      throw const TransferFailure('The item is no longer available locally.');
    }
    if (enabled && !folder.paused) await engine!.scan(folder.id);
  }

  Future<void> deleteEntry(SyncFolder folder, String relative) async {
    final target = await syncLocalPath(directory(folder), relative);
    final type = await FileSystemEntity.type(target, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      await for (final child in Directory(
        target,
      ).list(recursive: true, followLinks: false)) {
        if (child is Link || syncMetadataName(paths.basename(child.path))) {
          throw const TransferFailure(
            'This folder contains linked or reserved items.',
          );
        }
      }
    }
    if (folder.useDocuments) {
      await _prepareDocuments(folder);
      await _mirrors[folder.id]!.reconcile(folder.selection);
      final public = await _mirrors[folder.id]!.documents.snapshot();
      final hash = public[relative];
      if (hash != null) {
        await _mirrors[folder.id]!.documents.delete(
          relative,
          hash,
          recursive: true,
        );
      }
      if (type == FileSystemEntityType.notFound) return;
    }
    if (type == FileSystemEntityType.directory) {
      await Directory(target).delete(recursive: true);
    } else if (type == FileSystemEntityType.file) {
      await File(target).delete();
    } else {
      throw const TransferFailure('The item is no longer available locally.');
    }
    if (enabled && !folder.paused) await engine!.scan(folder.id);
  }

  void decide(bool accepted, {String? localPath, SyncSelection? selection}) {
    if (invitation?.decision.isCompleted == false) {
      invitation!.localPath = localPath;
      if (selection != null) invitation!.selection = selection;
      invitation!.decision.complete(accepted);
    }
  }

  Future<void> _invitation(
    SecureTransferChannel channel,
    TransferIdentity identity,
    SendDevice peer,
    Map<String, dynamic> message,
  ) async {
    if (!enabled || engine?.running != true || invitation != null) {
      await channel.control({'type': 'sync-decline'});
      return;
    }
    if (folders
                .where((f) => f.linked)
                .expand((f) => f.members)
                .map((m) => m.peer.id)
                .toSet()
                .length >=
            3 &&
        !folders.any(
          (f) => f.linked && f.members.any((m) => m.peer.id == peer.id),
        )) {
      throw const TransferFailure(
        'At most three Sync peers are supported in this build.',
      );
    }
    final id = message['folder_id'],
        label = message['label'],
        device = message['device_id'];
    if (id is! String ||
        !validSyncFolder(id) ||
        label is! String ||
        label.trim().isEmpty ||
        label.length > 80 ||
        device is! String ||
        !validSyncDevice(device)) {
      throw const TransferFailure('Invalid shared folder invitation.');
    }
    final existing = folders.where((f) => f.id == id);
    if (existing.isNotEmpty &&
        (existing.single.peer.id != peer.id ||
            existing.single.enginePeer != device)) {
      throw const TransferFailure('The folder invitation changed identity.');
    }
    var accepted =
        existing.isNotEmpty &&
        existing.single.linked &&
        !existing.single.paused;
    String? chosenPath;
    var selection = SyncSelection();
    if (!accepted) {
      if (folders.length >= 8 && existing.isEmpty) {
        throw const TransferFailure(
          'Pause or remove a sync link before adding more folders.',
        );
      }
      final pendingInvitation = SyncInvitation(id, label, peer, device);
      invitation = pendingInvitation;
      changed();
      try {
        accepted = await invitation!.decision.future.timeout(
          const Duration(minutes: 4),
          onTimeout: () => false,
        );
        chosenPath = pendingInvitation.localPath;
        selection = pendingInvitation.selection;
      } finally {
        invitation = null;
        changed();
      }
    }
    if (!accepted || !enabled) {
      await channel.control({'type': 'sync-decline'});
      return;
    }
    if (folders.any(
      (f) =>
          f.peer.id == peer.id &&
          f.enginePeer != null &&
          f.enginePeer != device,
    )) {
      throw const TransferFailure(
        'This device has a different Sync identity. Remove its old links before accepting again.',
      );
    }
    if (chosenPath != null) chosenPath = await validateLocation(chosenPath);
    final folder = existing.isEmpty
        ? SyncFolder(
            id: id,
            label: label,
            peer: peer,
            enginePeer: device,
            localPath: chosenPath,
            selection: selection,
            useDocuments: Platform.isAndroid,
          )
        : existing.single;
    folder.paused = false;
    folder.linked = true;
    if (existing.isEmpty) folders.add(folder);
    if (folder.localPath != null) {
      engine!.registerLocation(id, directory(folder));
    }
    await _save();
    await _configure(folder);
    await channel.control({
      'type': 'sync-accepted',
      'folder_id': id,
      'device_id': engine!.deviceId,
    });
    changed();
  }

  Future<void> _connection(
    SecureTransferChannel channel,
    TransferIdentity identity,
    SendDevice peer,
    Map<String, dynamic> message,
  ) async {
    final device = message['device_id'];
    if (!enabled ||
        device is! String ||
        !validSyncDevice(device) ||
        _bridge == null) {
      throw const TransferFailure('Enable Sync on both devices.');
    }
    await _bridge!.incoming(
      SyncPeer(peer.id, device, peer.name),
      channel,
      message,
    );
  }

  Future<void> create(
    String label,
    SendDevice peer, {
    String? localPath,
  }) async {
    if (!enabled || busy) return;
    if (label.trim().isEmpty ||
        label.trim().length > 80 ||
        folders.length >= 8 ||
        (folders
                    .where((f) => f.linked)
                    .expand((f) => f.members)
                    .map((m) => m.peer.id)
                    .toSet()
                    .length >=
                3 &&
            !folders.any(
              (f) => f.linked && f.members.any((m) => m.peer.id == peer.id),
            ))) {
      error =
          'Choose a folder name; at most eight folders and three peers are supported.';
      changed();
      return;
    }
    if (localPath != null) localPath = await validateLocation(localPath);
    final folder = SyncFolder(
      id: 'ep-${randomTransferNonce().substring(0, 32)}',
      label: label.trim(),
      peer: peer,
      localPath: localPath,
      isSource: true,
      useDocuments: Platform.isAndroid,
    );
    if (localPath != null) {
      engine!.registerLocation(folder.id, Directory(localPath));
    }
    folders.add(folder);
    await _save();
    await retry(folder);
  }

  Future<void> retry(SyncFolder folder, {SendDevice? additionalPeer}) async {
    if (!enabled || busy) return;
    final peer = additionalPeer ?? folder.peer;
    if (additionalPeer != null &&
        (!folder.isSource ||
            folder.additionalPeers.length >= 2 ||
            folder.members.any((m) => m.peer.id == peer.id) ||
            folders
                    .where((f) => f.linked)
                    .expand((f) => f.members)
                    .map((m) => m.peer.id)
                    .toSet()
                    .union({peer.id})
                    .length >
                3)) {
      throw const TransferFailure(
        'This source can share with up to three paired devices.',
      );
    }
    busy = true;
    changed();
    SecureTransferChannel? channel;
    try {
      channel = await transfers.openPeer(peer);
      _inviteChannel = channel;
      await channel.control({
        'type': 'sync-invite',
        'folder_id': folder.id,
        'label': folder.label,
        'device_id': engine!.deviceId,
      });
      final response = await channel.readControl(
        timeout: const Duration(minutes: 5),
      );
      if (response['type'] != 'sync-accepted' ||
          response['folder_id'] != folder.id ||
          response['device_id'] is! String ||
          !validSyncDevice(response['device_id'] as String)) {
        throw const TransferFailure(
          'The other device declined. Enable Sync there, then retry.',
        );
      }
      final device = response['device_id'] as String;
      if (folders.any(
        (f) => f.members.any(
          (m) =>
              m.peer.id == peer.id &&
              m.engineId != null &&
              m.engineId != device,
        ),
      )) {
        throw const TransferFailure(
          'The other device changed its Sync identity.',
        );
      }
      if (additionalPeer == null) {
        folder.enginePeer = device;
      } else {
        folder.additionalPeers.add(SyncFolderMember(peer, device));
      }
      folder.paused = false;
      await _save();
      await _configure(folder);
      error = null;
    } catch (e) {
      error = e.toString();
    } finally {
      await channel?.close();
      if (identical(_inviteChannel, channel)) _inviteChannel = null;
      busy = false;
      changed();
    }
  }

  Future<void> pause(SyncFolder folder, bool paused) async {
    if (!enabled || busy || folder.enginePeer == null) return;
    busy = true;
    changed();
    try {
      for (final member in folder.members) {
        await _bridge!.disconnect(member.peer.id);
      }
      folder.paused = paused;
      await _save();
      await _configure(folder);
      folder.state = paused ? 'Paused' : 'Connecting';
      error = null;
    } catch (e) {
      error = e.toString();
    } finally {
      busy = false;
      changed();
    }
  }

  Future<void> remove(SyncFolder folder) async {
    if (busy) return;
    busy = true;
    changed();
    try {
      if (enabled) {
        for (final member in folder.members) {
          await _bridge?.disconnect(member.peer.id);
        }
      }
      folder.linked = false;
      folder.paused = true;
      folder.state = 'Local copy · link removed';
      await _save();
      if (enabled) await engine?.removeFolder(folder.id);
      error = null;
    } catch (e) {
      error = e.toString();
    } finally {
      busy = false;
      changed();
    }
  }

  Future<void> importFile(
    SyncFolder folder,
    TransferSource source, {
    bool replace = false,
    String relative = '',
  }) async {
    if (busy || folder.enginePeer == null || !folder.linked) return;
    if (source.size < 0 || source.size > maxTransferBytes) {
      throw const TransferFailure('The selected file is too large.');
    }
    final name = safeTransferName(source.name);
    final target = [if (relative.isNotEmpty) relative, name].join('/');
    final destination = File(await syncLocalPath(directory(folder), target));
    await destination.parent.create(recursive: true);
    final type = await FileSystemEntity.type(
      destination.path,
      followLinks: false,
    );
    if (type != FileSystemEntityType.notFound &&
        !(replace && type == FileSystemEntityType.file)) {
      throw const TransferFailure('A file with that name already exists.');
    }
    if (destination.path.split(Platform.pathSeparator).last.startsWith('.st')) {
      throw const TransferFailure('That name is reserved for Sync.');
    }
    final temporary = File(
      paths.join(
        destination.parent.path,
        '.syncthing.easyprivacy-${randomTransferNonce()}.tmp',
      ),
    );
    try {
      final handle = await temporary.open(mode: FileMode.write);
      try {
        var written = 0;
        await for (final chunk in boundedTransferChunks(source.read(0, null))) {
          written += chunk.length;
          if (written > source.size) {
            throw const TransferFailure(
              'The selected file changed. Choose it again.',
            );
          }
          await handle.writeFrom(chunk);
        }
        if (written != source.size) {
          throw const TransferFailure(
            'The selected file changed. Choose it again.',
          );
        }
        await handle.flush();
      } finally {
        await handle.close();
      }
      await temporary.rename(destination.path);
      if (folder.selection.selective && !folder.selection.includes(target)) {
        await select(folder, target, true);
      }
      if (enabled && !folder.paused) await engine!.scan(folder.id);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> deleteLocalCopy(SyncFolder folder) async {
    if (folder.linked || busy) return;
    if (folder.localPath != null || folder.useDocuments) {
      folders.remove(folder);
      await _save();
      changed();
      return;
    }
    final target = directory(folder);
    final parent = Directory(
      paths.join(_resolvedRoot!.path, 'folders'),
    ).absolute.path;
    if (target.absolute.parent.path != parent ||
        !validSyncFolder(paths.basename(target.path)) ||
        await FileSystemEntity.type(target.path, followLinks: false) ==
            FileSystemEntityType.link) {
      throw const TransferFailure('Refused to remove an unmanaged Sync path.');
    }
    if (await target.exists()) await target.delete(recursive: true);
    folders.remove(folder);
    await _save();
    changed();
  }

  Future<void> deleteFile(SyncFolder folder, File file) async {
    if (busy || !folder.linked || folder.enginePeer == null) return;
    final base = await directory(folder).resolveSymbolicLinks();
    final canonical = await file.resolveSymbolicLinks();
    final relative = paths.relative(canonical, from: base);
    if (!paths.isWithin(base, canonical) ||
        await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        paths
            .split(relative)
            .any((p) => p.startsWith('.st') || p.startsWith('.syncthing'))) {
      throw const TransferFailure('Refused to delete an unmanaged Sync file.');
    }
    await file.delete();
    if (enabled && !folder.paused) await engine!.scan(folder.id);
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    decide(false);
    transfers.handlers.remove('sync-invite');
    transfers.handlers.remove('sync-connect');
    unawaited(shutdown());
    super.dispose();
  }

  Future<void> shutdown() => _shuttingDown ??= _shutdown();
  Future<void> _shutdown() async {
    enabled = false;
    _timer?.cancel();
    decide(false);
    await _inviteChannel?.close();
    while (busy || _refreshing) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await _bridge?.close();
    await engine?.stop();
    await transfers.receiveFor('sync', false);
  }
}
