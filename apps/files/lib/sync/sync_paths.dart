import 'dart:io';
import 'package:path/path.dart' as paths;
import '../transfer/secure_channel.dart';

bool syncMetadataName(String name) =>
    {'.stfolder', '.stignore', '.stversions'}.contains(name.toLowerCase()) ||
    name.toLowerCase().startsWith('.syncthing.');

/// Network names are always relative POSIX paths, including on Windows.
String syncRelative(String value, {bool allowRoot = false}) {
  if (allowRoot && value.isEmpty) return value;
  final parts = value.split('/');
  if (value.isEmpty ||
      value.length > 2048 ||
      parts.any(
        (part) =>
            part.isEmpty ||
            part == '.' ||
            part == '..' ||
            part.trim() != part ||
            part.endsWith('.') ||
            part.contains(RegExp(r'[\\:\x00-\x1f]')) ||
            syncMetadataName(part),
      )) {
    throw const TransferFailure('Invalid path inside the synced folder.');
  }
  return value;
}

Future<String> syncLocalPath(Directory root, String relative) async {
  syncRelative(relative, allowRoot: true);
  if (await FileSystemEntity.type(root.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const TransferFailure(
      'The synced folder is unavailable. Reconnect its drive or restore its location.',
    );
  }
  final base = paths.normalize(paths.absolute(root.path));
  if (!paths.equals(await root.resolveSymbolicLinks(), base)) {
    throw const TransferFailure('The synced folder location has changed.');
  }
  var current = base;
  for (final part in relative.isEmpty ? <String>[] : relative.split('/')) {
    current = paths.join(current, part);
    if (await FileSystemEntity.type(current, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const TransferFailure(
        'Linked files and folders cannot be managed by Sync.',
      );
    }
  }
  if (!paths.equals(base, current) && !paths.isWithin(base, current)) {
    throw const TransferFailure('The path is outside the synced folder.');
  }
  return current;
}

class SyncSelection {
  SyncSelection({this.selective = false, Map<String, bool>? rules})
    : rules = Map.of(rules ?? {});
  bool selective;
  final Map<String, bool> rules;
  bool includes(String path) {
    syncRelative(path);
    if (!selective) return true;
    var result = false, depth = -1;
    for (final entry in rules.entries) {
      if ((path == entry.key || path.startsWith('${entry.key}/')) &&
          entry.key.length > depth) {
        depth = entry.key.length;
        result = entry.value;
      }
    }
    return result;
  }

  void select(String path, bool selected) {
    syncRelative(path);
    rules.removeWhere((key, _) => key == path || key.startsWith('$path/'));
    rules[path] = selected;
    if (rules.length > 4096) {
      throw const TransferFailure(
        'Select a parent folder to reduce the number of individual selections.',
      );
    }
  }

  List<String> get ignorePatterns {
    if (!selective) return [];
    final entries = rules.entries.toList()
      ..sort((a, b) => b.key.length.compareTo(a.key.length));
    String escape(String path) =>
        path.replaceAllMapped(RegExp(r'[\\*?\[\]{}!#]'), (m) => '\\${m[0]}');
    return [
      r'#escape=\',
      for (final entry in entries)
        '${entry.value ? '!' : ''}/${escape(entry.key)}',
      '*',
    ];
  }

  Map<String, Object?> toJson() => {'selective': selective, 'rules': rules};
  factory SyncSelection.fromJson(Map<String, dynamic> json) {
    final rules = Map<String, bool>.from(json['rules'] as Map? ?? {});
    if (rules.length > 4096) {
      throw const FormatException('Too many Sync selections.');
    }
    for (final path in rules.keys) {
      syncRelative(path);
    }
    return SyncSelection(selective: json['selective'] == true, rules: rules);
  }
}

class SyncEntry {
  const SyncEntry(
    this.path, {
    required this.directory,
    required this.local,
    this.size = 0,
  });
  final String path;
  final bool directory, local;
  final int size;
  String get name => path.split('/').last;
}
