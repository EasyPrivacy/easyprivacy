import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easyprivacy_files/sync/documents_mirror.dart';
import 'package:easyprivacy_files/sync/sync_paths.dart';

class DiskDocuments extends FolderDocuments {
  DiskDocuments(this.root);
  final Directory root;
  bool denied = false;
  String path(String relative) => '${root.path}/$relative';
  Future<String> hash(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();
  @override
  Future<Map<String, String>> snapshot() async {
    if (denied) throw const FileSystemException('Document permission revoked');
    final result = <String, String>{};
    await for (final entry in root.list(recursive: true, followLinks: false)) {
      final name = entry.path
          .substring(root.path.length + 1)
          .split(Platform.pathSeparator)
          .join('/');
      result[name] = entry is Directory
          ? 'directory'
          : await hash(File(entry.path));
    }
    return result;
  }

  Future<void> copy(
    File source,
    File destination,
    String expected,
    String? old,
  ) async {
    expect(await hash(source), expected);
    expect(await destination.exists() ? await hash(destination) : null, old);
    await destination.parent.create(recursive: true);
    await source.copy(destination.path);
  }

  @override
  Future<void> importFile(
    String relative,
    String destination,
    String hash,
    String? oldHash,
  ) => copy(File(path(relative)), File(destination), hash, oldHash);
  @override
  Future<void> exportFile(
    String relative,
    String source,
    String hash,
    String? oldHash,
  ) => copy(File(source), File(path(relative)), hash, oldHash);
  @override
  Future<void> createDirectory(String relative) async {
    await Directory(path(relative)).create(recursive: true);
  }

  @override
  Future<void> delete(
    String relative,
    String expected, {
    bool recursive = false,
  }) async {
    final type = await FileSystemEntity.type(path(relative));
    if (type == FileSystemEntityType.directory) {
      expect(expected, 'directory');
      await Directory(path(relative)).delete();
    } else {
      expect(await hash(File(path(relative))), expected);
      await File(path(relative)).delete();
    }
  }

  @override
  Future<void> open(String relative, bool edit) async {}
}

void main() {
  late Directory root, local, public;
  late DiskDocuments store;
  late DocumentsMirror mirror;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ep-documents-test-');
    local = await Directory('${root.path}/local').create();
    public = await Directory('${root.path}/Documents').create();
    store = DiskDocuments(public);
    mirror = DocumentsMirror(
      local: local,
      documents: store,
      journal: File('${root.path}/journal.json'),
    );
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  test(
    'nested edits, additions, moves and deletions reconcile automatically in both directions',
    () async {
      await Directory('${local.path}/nested').create();
      final private = File('${local.path}/nested/example.txt');
      final document = File('${public.path}/nested/example.txt');
      await private.writeAsString('source');
      await mirror.reconcile(SyncSelection());
      expect(await document.readAsString(), 'source');
      await document.writeAsString('edited directly in Documents');
      expect(await mirror.reconcile(SyncSelection()), isTrue);
      expect(await private.readAsString(), 'edited directly in Documents');
      await document.rename('${public.path}/nested/moved.txt');
      await mirror.reconcile(SyncSelection());
      expect(await private.exists(), isFalse);
      expect(await File('${local.path}/nested/moved.txt').exists(), isTrue);
      await File('${local.path}/nested/moved.txt').delete();
      await mirror.reconcile(SyncSelection());
      expect(await File('${public.path}/nested/moved.txt').exists(), isFalse);
    },
  );
  test(
    'concurrent edits retain both complete versions and survive a journal reload',
    () async {
      final a = File('${local.path}/example.txt'),
          b = File('${public.path}/example.txt');
      await a.writeAsString('initial');
      await mirror.reconcile(SyncSelection());
      await a.writeAsString('desktop edit');
      await b.writeAsString('document editor edit');
      await mirror.reconcile(SyncSelection());
      final conflicts = await local
          .list()
          .where((f) => f.path.contains('.sync-conflict-'))
          .toList();
      expect(conflicts, hasLength(1));
      expect(
        await File(conflicts.single.path).readAsString(),
        'document editor edit',
      );
      expect(await a.readAsString(), 'desktop edit');
      expect(await b.readAsString(), 'desktop edit');
      mirror = DocumentsMirror(
        local: local,
        documents: store,
        journal: File('${root.path}/journal.json'),
      );
      expect(await mirror.reconcile(SyncSelection()), isFalse);
    },
  );
  test(
    'lost permission is not interpreted as deletion and selective replicas omit unselected content',
    () async {
      await File('${local.path}/keep.txt').writeAsString('keep');
      await File('${local.path}/remote.txt').writeAsString('remote');
      final selection = SyncSelection(
        selective: true,
        rules: {'keep.txt': true},
      );
      await mirror.reconcile(selection);
      expect(await File('${public.path}/keep.txt').exists(), isTrue);
      expect(await File('${public.path}/remote.txt').exists(), isFalse);
      store.denied = true;
      await expectLater(
        mirror.reconcile(selection),
        throwsA(isA<FileSystemException>()),
      );
      expect(await File('${local.path}/keep.txt').readAsString(), 'keep');
      store.denied = false;
      await mirror.reconcile(selection);
      selection.select('keep.txt', false);
      await mirror.evict(selection);
      expect(await File('${public.path}/keep.txt').exists(), isFalse);
      expect(await File('${local.path}/keep.txt').exists(), isTrue);
    },
  );
  test(
    'a missing local root is not recreated or exported as a mass deletion',
    () async {
      await File('${local.path}/keep.txt').writeAsString('keep');
      await mirror.reconcile(SyncSelection());
      await local.rename('${root.path}/removed-location');
      await expectLater(mirror.reconcile(SyncSelection()), throwsException);
      expect(await local.exists(), isFalse);
      expect(await File('${public.path}/keep.txt').readAsString(), 'keep');
    },
  );
}
