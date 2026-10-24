import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as paths;
import 'package:path_provider/path_provider.dart';
import '../sync/core_sync_bridge.dart';
import '../sync/sync_engine.dart';
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
  });
  final String id, label;
  final SendDevice peer;
  String? enginePeer;
  bool paused;
  bool linked;
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
    return SyncFolder(
      id: id,
      label: label,
      peer: SendDevice(peer, json['peer_name'] as String, null),
      enginePeer: engine,
      paused: json['paused'] as bool,
      linked: json['linked'] as bool? ?? true,
    );
  }
}

class SyncInvitation {
  SyncInvitation(this.id, this.label, this.peer, this.enginePeer);
  final String id, label, enginePeer;
  final SendDevice peer;
  final decision = Completer<bool>();
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
  String? _core;
  final List<SyncFolder> folders = [];
  SyncInvitation? invitation;
  bool enabled = false, busy = false, initialized = false;
  String? error;
  bool _disposed = false, _refreshing = false;
  Timer? _timer;
  Future<void> _saves = Future.value();
  Future<void>? _initializing;
  void changed() {
    if (!_disposed) notifyListeners();
  }

  Directory directory(SyncFolder folder) =>
      Directory(paths.join(root!.path, 'folders', folder.id));

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
      final file = File(paths.join(root!.path, 'state.json'));
      var savedEnabled = false;
      if (await file.exists()) {
        if (await file.length() > 64 * 1024) {
          throw const FormatException('Sync settings are too large.');
        }
        final json =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        if (json['version'] != 1 || json['core'] != _core) {
          throw const FormatException('Sync belongs to a different core.');
        }
        final loaded = (json['folders'] as List)
            .map(
              (v) => SyncFolder.fromJson(Map<String, dynamic>.from(v as Map)),
            )
            .toList();
        if (loaded.length > 8 ||
            loaded.map((f) => f.id).toSet().length != loaded.length ||
            loaded.where((f) => f.linked).map((f) => f.peer.id).toSet().length >
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
      'version': 1,
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
            f.peer.id == peer.coreId &&
            f.enginePeer == peer.engineId,
      );
  Future<void> setEnabled(bool value) async {
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
        await _save();
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
        await engine!.start();
        await engine!.reconcile(
          folders
              .where((f) => f.linked && f.enginePeer != null)
              .map((f) => f.id)
              .toSet(),
          folders
              .where((f) => f.linked && f.enginePeer != null)
              .map((f) => f.enginePeer!)
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
          await _bridge!.add(
            SyncPeer(folder.peer.id, folder.enginePeer!, folder.peer.name),
          );
          await engine!.configureFolder(
            folder.id,
            folder.label,
            folder.enginePeer!,
            paused: folder.paused,
          );
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

  Future<void> refresh() async {
    if (_disposed || !enabled || _refreshing) return;
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
        final status = await engine!.status(folder.id);
        folder.files = (status['globalFiles'] as num?)?.toInt() ?? 0;
        folder.bytes = (status['globalBytes'] as num?)?.toInt() ?? 0;
        final connection =
            (connections['connections'] as Map)[folder.enginePeer] as Map?;
        folder.state = folder.paused
            ? 'Paused'
            : (status['pullErrors'] as num? ?? 0) > 0
            ? 'Needs attention'
            : connection?['connected'] != true
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

  void decide(bool accepted) {
    if (invitation?.decision.isCompleted == false) {
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
    if (folders.where((f) => f.linked).map((f) => f.peer.id).toSet().length >=
            3 &&
        !folders.any((f) => f.linked && f.peer.id == peer.id)) {
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
    if (!accepted) {
      if (folders.length >= 8 && existing.isEmpty) {
        throw const TransferFailure(
          'Pause or remove a sync link before adding more folders.',
        );
      }
      invitation = SyncInvitation(id, label, peer, device);
      changed();
      try {
        accepted = await invitation!.decision.future.timeout(
          const Duration(minutes: 4),
          onTimeout: () => false,
        );
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
    final folder = existing.isEmpty
        ? SyncFolder(id: id, label: label, peer: peer, enginePeer: device)
        : existing.single;
    folder.paused = false;
    folder.linked = true;
    if (existing.isEmpty) folders.add(folder);
    await _save();
    await _bridge!.add(SyncPeer(peer.id, device, peer.name));
    await engine!.configureFolder(id, folder.label, device);
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

  Future<void> create(String label, SendDevice peer) async {
    if (!enabled || busy) return;
    if (label.trim().isEmpty ||
        label.trim().length > 80 ||
        folders.length >= 8 ||
        (folders.where((f) => f.linked).map((f) => f.peer.id).toSet().length >=
                3 &&
            !folders.any((f) => f.linked && f.peer.id == peer.id))) {
      error =
          'Choose a folder name; at most eight folders and three peers are supported.';
      changed();
      return;
    }
    final folder = SyncFolder(
      id: 'ep-${randomTransferNonce().substring(0, 32)}',
      label: label.trim(),
      peer: peer,
    );
    folders.add(folder);
    await _save();
    await retry(folder);
  }

  Future<void> retry(SyncFolder folder) async {
    if (!enabled || busy) return;
    busy = true;
    changed();
    SecureTransferChannel? channel;
    try {
      channel = await transfers.openPeer(folder.peer);
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
        (f) =>
            f.peer.id == folder.peer.id &&
            f.enginePeer != null &&
            f.enginePeer != device,
      )) {
        throw const TransferFailure(
          'The other device changed its Sync identity.',
        );
      }
      folder.enginePeer = device;
      folder.paused = false;
      await _save();
      await _bridge!.add(SyncPeer(folder.peer.id, device, folder.peer.name));
      await engine!.configureFolder(folder.id, folder.label, device);
      error = null;
    } catch (e) {
      error = e.toString();
    } finally {
      await channel?.close();
      busy = false;
      changed();
    }
  }

  Future<void> pause(SyncFolder folder, bool paused) async {
    if (!enabled || busy || folder.enginePeer == null) return;
    busy = true;
    changed();
    try {
      await _bridge!.disconnect(folder.peer.id);
      folder.paused = paused;
      await _save();
      await engine!.configureFolder(
        folder.id,
        folder.label,
        folder.enginePeer!,
        paused: paused,
      );
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
      if (enabled) await _bridge?.disconnect(folder.peer.id);
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
  }) async {
    if (busy || folder.enginePeer == null || !folder.linked) return;
    if (source.size < 0 || source.size > maxTransferBytes) {
      throw const TransferFailure('The selected file is too large.');
    }
    final destination = File(
      paths.join(directory(folder).path, safeTransferName(source.name)),
    );
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
        directory(folder).path,
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
      if (enabled && !folder.paused) await engine!.scan(folder.id);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> deleteLocalCopy(SyncFolder folder) async {
    if (folder.linked || busy) return;
    final target = directory(folder);
    final parent = Directory(paths.join(root!.path, 'folders')).absolute.path;
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
    unawaited(() async {
      await _bridge?.close();
      await engine?.stop();
      await transfers.receiveFor('sync', false);
    }());
    super.dispose();
  }
}
