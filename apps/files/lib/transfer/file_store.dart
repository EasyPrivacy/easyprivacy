import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as paths;
import 'secure_channel.dart';

const maxTransferBytes = 1024 * 1024 * 1024 * 1024;
const transferRetention = Duration(hours: 24);

String safeTransferName(String name) {
  var result = name
      .replaceAll(
        RegExp(r'[<>:"/\\|?*\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]'),
        '_',
      )
      .trim();
  result = result.replaceAll(RegExp(r'[. ]+$'), '');
  if (result.isEmpty || result == '.' || result == '..') result = 'file';
  if (RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])($|\.)',
    caseSensitive: false,
  ).hasMatch(result)) {
    result = '_$result';
  }
  while (utf8.encode(result).length > 180) {
    result = String.fromCharCodes(result.runes.take(result.runes.length - 1));
  }
  return result;
}

class TransferOffer {
  TransferOffer({
    required this.id,
    required this.name,
    required this.size,
    required this.digest,
  }) {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(id) ||
        name != safeTransferName(name) ||
        size < 0 ||
        size > maxTransferBytes ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      throw const TransferFailure('Invalid file offer.');
    }
  }
  factory TransferOffer.fromJson(Map<String, dynamic> json) => TransferOffer(
    id: json['id'] as String,
    name: json['name'] as String,
    size: json['size'] as int,
    digest: json['sha256'] as String,
  );
  final String id, name, digest;
  final int size;
  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'size': size,
    'sha256': digest,
  };
  static String identifier(
    String core,
    String sender,
    String recipient,
    String name,
    int size,
    String digest,
  ) => sha256
      .convert(
        utf8.encode(
          'EasyPrivacy Send v1\n$core\n$sender\n$recipient\n$name\n$size\n$digest',
        ),
      )
      .toString()
      .substring(0, 32);
}

class StoredTransfer {
  StoredTransfer(
    this.offer,
    this.core,
    this.sender,
    this.recipient,
    this.created,
    this.directory,
  );
  final TransferOffer offer;
  final String core, sender, recipient;
  final DateTime created;
  final Directory directory;
  File get partial => File(paths.join(directory.path, 'payload.part'));
  File get completed => File(paths.join(directory.path, 'payload.received'));
  Future<bool> get verified => completed.exists();
  Future<void> delete() async {
    // Only fixed filenames under a validated transfer ID are removed. Never
    // follow recursively created directories or paths received from a peer.
    for (final name in [
      'payload.part',
      'payload.received',
      'record.json',
      'record.tmp',
    ]) {
      final path = paths.join(directory.path, name);
      if (await FileSystemEntity.type(path, followLinks: false) ==
          FileSystemEntityType.file) {
        await File(path).delete();
      }
    }
    if (await directory.exists() && await directory.list().isEmpty) {
      await directory.delete();
    }
  }
}

class TransferFileStore {
  TransferFileStore(this.root);
  final Directory root;
  Future<List<StoredTransfer>> records() async {
    await root.create(recursive: true);
    final result = <StoredTransfer>[];
    await for (final entry in root.list(followLinks: false)) {
      if (entry is! Directory ||
          !RegExp(r'^[0-9a-f]{32}$').hasMatch(paths.basename(entry.path))) {
        continue;
      }
      final file = File(paths.join(entry.path, 'record.json'));
      try {
        if (await FileSystemEntity.type(file.path, followLinks: false) !=
                FileSystemEntityType.file ||
            await file.length() > 4096) {
          continue;
        }
        final json =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final offer = TransferOffer.fromJson(json);
        if (offer.id != paths.basename(entry.path)) continue;
        final record = StoredTransfer(
          offer,
          json['core'] as String,
          json['sender'] as String,
          json['recipient'] as String,
          DateTime.parse(json['created'] as String),
          entry,
        );
        if (DateTime.now().difference(record.created) >= transferRetention) {
          await record.delete();
        } else {
          result.add(record);
        }
      } catch (_) {
        /* Unrecognized files are never treated as transfer records. */
      }
    }
    return result;
  }

  Future<StoredTransfer> prepare(
    TransferOffer offer,
    String core,
    String sender,
    String recipient,
  ) async {
    if (offer.id !=
        TransferOffer.identifier(
          core,
          sender,
          recipient,
          offer.name,
          offer.size,
          offer.digest,
        )) {
      throw const TransferFailure(
        'The file offer belongs to a different transfer.',
      );
    }
    final existing = await records();
    final matching = existing.where((r) => r.offer.id == offer.id);
    if (matching.isNotEmpty) {
      final record = matching.single;
      if (!await record.completed.exists() && !await record.partial.exists()) {
        await record.partial.create();
      }
      return record;
    }
    if (existing.length >= 8) {
      throw const TransferFailure(
        'Save or remove a received file before accepting another.',
      );
    }
    final dir = Directory(paths.join(root.path, offer.id));
    if (await FileSystemEntity.type(dir.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const TransferFailure('The receive location is unavailable.');
    }
    await dir.create();
    final record = StoredTransfer(
      offer,
      core,
      sender,
      recipient,
      DateTime.now().toUtc(),
      dir,
    );
    await File(paths.join(dir.path, 'record.json')).writeAsString(
      jsonEncode({
        ...offer.toJson(),
        'core': core,
        'sender': sender,
        'recipient': recipient,
        'created': record.created.toIso8601String(),
      }),
      flush: true,
    );
    await record.partial.create();
    return record;
  }
}
