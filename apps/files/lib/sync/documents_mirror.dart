import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as paths;
import '../transfer/secure_channel.dart';
import 'sync_paths.dart';

abstract class FolderDocuments {
  Future<Map<String, String>> snapshot();
  Future<void> importFile(
    String relative,
    String destination,
    String hash,
    String? oldHash,
  );
  Future<void> exportFile(
    String relative,
    String source,
    String hash,
    String? oldHash,
  );
  Future<void> createDirectory(String relative);
  Future<void> delete(String relative, String hash, {bool recursive = false});
  Future<void> move(String from, String to) async =>
      throw UnsupportedError('Document moves are unavailable.');
  Future<void> open(String relative, bool edit);
}

class AndroidFolderDocuments extends FolderDocuments {
  AndroidFolderDocuments(this.key, this.local);
  final String key;
  final Directory local;
  static const channel = MethodChannel('org.easyprivacy/files_documents');
  Future<T?> _call<T>(String method, [Map<String, Object?> args = const {}]) =>
      channel.invokeMethod<T>(method, {'key': key, ...args});
  static Future<bool> chooseRoot() async =>
      await channel.invokeMethod<bool>('hasRoot') == true ||
      (await channel.invokeMethod<bool>('chooseRoot') ?? false);
  Future<String> prepare(String label) async =>
      (await _call<String>('prepare', {'label': label, 'path': local.path}))!;
  @override
  Future<Map<String, String>> snapshot() async =>
      Map<String, String>.from((await _call<Map>('snapshot'))!);
  @override
  Future<void> importFile(
    String relative,
    String destination,
    String hash,
    String? oldHash,
  ) async {
    await _call<void>('import', {
      'relative': relative,
      'destination': destination,
      'hash': hash,
      'oldHash': oldHash,
    });
  }

  @override
  Future<void> exportFile(
    String relative,
    String source,
    String hash,
    String? oldHash,
  ) async {
    await _call<void>('export', {
      'relative': relative,
      'source': source,
      'hash': hash,
      'oldHash': oldHash,
    });
  }

  @override
  Future<void> createDirectory(String relative) async {
    await _call<void>('mkdir', {'relative': relative});
  }

  @override
  Future<void> delete(
    String relative,
    String hash, {
    bool recursive = false,
  }) async {
    await _call<void>('delete', {
      'relative': relative,
      'hash': hash,
      'recursive': recursive,
    });
  }

  @override
  Future<void> move(String from, String to) async {
    await _call<void>('move', {'relative': from, 'destination': to});
  }

  @override
  Future<void> open(String relative, bool edit) async {
    await _call<void>('open', {'relative': relative, 'edit': edit});
  }
}

/// Three-way reconciliation connects the engine's POSIX files to a granted
/// Android document tree. Missing grants/roots throw; they never mean "empty".
/// The journal advances only after both copies agree. Conflicting edits survive.
class DocumentsMirror {
  DocumentsMirror({
    required this.local,
    required this.documents,
    required this.journal,
  });
  final Directory local;
  final FolderDocuments documents;
  final File journal;
  Map<String, String>? _baseline;
  Future<void> _tail = Future.value();
  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  final _hashCache = <String, (int, int, String)>{};
  Future<Map<String, String>> _localSnapshot() async {
    await syncLocalPath(local, '');
    final result = <String, String>{};
    Future<void> visit(Directory directory) async {
      await for (final entry in directory.list(followLinks: false)) {
        if (syncMetadataName(paths.basename(entry.path))) continue;
        final relative = paths
            .relative(entry.path, from: local.path)
            .split(paths.separator)
            .join('/');
        syncRelative(relative);
        if (entry is Link) {
          throw const TransferFailure(
            'Remove linked items from the Android synced folder.',
          );
        }
        if (entry is Directory) {
          result[relative] = 'directory';
          await visit(entry);
        } else if (entry is File) {
          final stat = await entry.stat(), cached = _hashCache[relative];
          final stamp = stat.modified.microsecondsSinceEpoch;
          final hash =
              cached != null && cached.$1 == stat.size && cached.$2 == stamp
              ? cached.$3
              : (await sha256.bind(entry.openRead()).first).toString();
          _hashCache[relative] = (stat.size, stamp, hash);
          result[relative] = hash;
        }
        if (result.length > 100000) {
          throw const TransferFailure(
            'This folder has too many document entries.',
          );
        }
      }
    }

    await visit(local);
    return result;
  }

  Future<void> _load() async {
    if (_baseline != null) return;
    if (await journal.exists()) {
      if (await journal.length() > 16 * 1024 * 1024) {
        throw const FormatException('Document journal is too large.');
      }
      final value = Map<String, String>.from(
        jsonDecode(await journal.readAsString()) as Map,
      );
      for (final entry in value.entries) {
        syncRelative(entry.key);
        if (entry.value != 'directory' &&
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(entry.value)) {
          throw const FormatException('Invalid document journal.');
        }
      }
      _baseline = value;
    } else {
      _baseline = {};
    }
  }

  Future<bool> reconcile(SyncSelection selection) =>
      _serial(() => _reconcile(selection));
  Future<bool> _reconcile(SyncSelection selection) async {
    {
      await _load();
      final disk = await _localSnapshot(), public = await documents.snapshot();
      for (final path in public.keys) {
        syncRelative(path);
      }
      final names = {...disk.keys, ...public.keys, ..._baseline!.keys}.toList()
        ..sort((a, b) => a.split('/').length.compareTo(b.split('/').length));
      for (final path in names) {
        final a = disk[path], b = public[path], old = _baseline![path];
        if (a == 'directory' || b == 'directory' || old == 'directory') {
          if (a != null && a != 'directory' || b != null && b != 'directory') {
            throw const TransferFailure(
              'A file and folder have the same name. Rename one to resolve the conflict.',
            );
          }
          if (a == 'directory' && b == null && old == null) {
            await documents.createDirectory(path);
          }
          if (b == 'directory' && a == null && old == null) {
            await Directory(
              await syncLocalPath(local, path),
            ).create(recursive: true);
          }
          continue;
        }
        if (!selection.includes(path) || a == b) continue;
        final target = await syncLocalPath(local, path);
        if (a == null && b != null) {
          if (old == b) {
            await documents.delete(path, b);
          } else {
            await Directory(paths.dirname(target)).create(recursive: true);
            await documents.importFile(path, target, b, null);
          }
        } else if (b == null && a != null) {
          if (old == a) {
            // Recheck content before applying a deletion made in Documents.
            if ((await sha256.bind(File(target).openRead()).first).toString() !=
                a) {
              throw const TransferFailure(
                'A file changed during synchronization. It will be checked again.',
              );
            }
            await File(target).delete();
          } else {
            await documents.exportFile(path, target, a, null);
          }
        } else if (a != null && b != null) {
          if (a == old) {
            await documents.importFile(path, target, b, a);
          } else if (b == old) {
            await documents.exportFile(path, target, a, b);
          } else {
            final conflict =
                '$path.sync-conflict-${randomTransferNonce().substring(0, 12)}';
            final conflictPath = await syncLocalPath(local, conflict);
            await documents.importFile(path, conflictPath, b, null);
            await documents.exportFile(conflict, conflictPath, b, null);
            await documents.exportFile(path, target, a, b);
          }
        }
      }
      // Remove only empty directories previously tracked by this adapter.
      for (final path in names.reversed) {
        if (_baseline![path] != 'directory') continue;
        final target = Directory(await syncLocalPath(local, path));
        if (disk[path] == null && public[path] == 'directory') {
          try {
            await documents.delete(path, 'directory');
          } catch (_) {
            /* Not empty: preserve it. */
          }
        } else if (public[path] == null &&
            disk[path] == 'directory' &&
            await target.exists()) {
          if (await target.list().isEmpty) await target.delete();
        }
      }
      final afterLocal = await _localSnapshot(),
          afterPublic = await documents.snapshot();
      final next = Map<String, String>.of(_baseline!);
      for (final path in {
        ...afterLocal.keys,
        ...afterPublic.keys,
        ...next.keys,
      }) {
        if (afterLocal[path] == afterPublic[path]) {
          if (afterLocal[path] == null) {
            next.remove(path);
          } else {
            next[path] = afterLocal[path]!;
          }
        }
      }
      await journal.parent.create(recursive: true);
      final temporary = File('${journal.path}.tmp');
      await temporary.writeAsString(jsonEncode(next), flush: true);
      await temporary.rename(journal.path);
      _baseline = next;
      return disk.length != afterLocal.length ||
          disk.entries.any((e) => afterLocal[e.key] != e.value);
    }
  }

  Future<void> evict(SyncSelection selection) =>
      _serial(() => _evict(selection));
  Future<void> _evict(SyncSelection selection) async {
    await _load();
    final snapshot = await documents.snapshot();
    for (final entry in _baseline!.entries) {
      if (entry.value != 'directory' &&
          !selection.includes(entry.key) &&
          snapshot[entry.key] == entry.value) {
        await documents.delete(entry.key, entry.value);
      }
    }
  }
}
