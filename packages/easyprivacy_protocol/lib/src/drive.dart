import 'dart:convert';

const maxDriveFileBytes = 1024 * 1024 * 1024;
bool validDrivePath(String value, {bool root = false}) =>
    (root && value.isEmpty) ||
    (value.isNotEmpty &&
        utf8.encode(value).length <= 2048 &&
        value.split('/').length <= 64 &&
        value
            .split('/')
            .every(
              (p) =>
                  p.isNotEmpty &&
                  utf8.encode(p).length <= 180 &&
                  p != '.' &&
                  p != '..' &&
                  p.trim() == p &&
                  !p.endsWith('.') &&
                  !p.contains(RegExp(r'[\\:<>"|?*\x00-\x1f]')) &&
                  !p.runes.any((r) => r >= 127 && r <= 159) &&
                  !RegExp(
                    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$',
                  ).hasMatch(p.split('.').first.toUpperCase()) &&
                  p.toLowerCase() != '.easyprivacy-drive',
            ));

/// Exact command bytes are signed; Files cannot delegate a general HTTP call.
class DriveCommand {
  const DriveCommand({
    required this.op,
    this.volume = '',
    this.path = '',
    this.target = '',
    this.cursor = '',
    this.size = 0,
    this.sha256 = '',
  });
  final String op, volume, path, target, cursor, sha256;
  final int size;
  Map<String, Object> toJson() => {
    'op': op,
    'volume': volume,
    'path': path,
    'target': target,
    'cursor': cursor,
    'size': size,
    'sha256': sha256,
  };
  factory DriveCommand.fromJson(Map<String, dynamic> json) {
    if (json.length != 7) throw const FormatException('Invalid Drive command.');
    final result = DriveCommand(
      op: json['op'] as String,
      volume: json['volume'] as String,
      path: json['path'] as String,
      target: json['target'] as String,
      cursor: json['cursor'] as String,
      size: json['size'] as int,
      sha256: json['sha256'] as String,
    );
    result.validate();
    return result;
  }
  void validate() {
    final ordinary = {'list', 'download', 'mkdir', 'move', 'delete'};
    if (!(ordinary.contains(op) || op == 'volumes' || op == 'upload') ||
        (op == 'volumes'
            ? volume.isNotEmpty
            : !RegExp(r'^[0-9a-f]{32}$').hasMatch(volume)) ||
        !validDrivePath(path, root: op == 'volumes' || op == 'list') ||
        (op == 'volumes' && path.isNotEmpty) ||
        (op == 'move' ? !validDrivePath(target) : target.isNotEmpty) ||
        (op == 'list'
            ? (cursor.isNotEmpty &&
                  (!validDrivePath(cursor) || cursor.contains('/')))
            : cursor.isNotEmpty) ||
        (op == 'upload'
            ? (size < 0 ||
                  size > maxDriveFileBytes ||
                  !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256))
            : (size != 0 || sha256.isNotEmpty))) {
      throw const FormatException('Invalid Drive command.');
    }
  }
}

String driveRequestClaim({
  required String core,
  required String device,
  required String node,
  required DriveCommand command,
  required String nonce,
  required int expires,
}) {
  command.validate();
  if (!RegExp(r'^SHA256:[0-9A-F]{64}$').hasMatch(core) ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(device) ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(node) ||
      device == node ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(nonce) ||
      expires < 1) {
    throw const FormatException('Invalid Drive authorization.');
  }
  String field(String value) => base64Encode(utf8.encode(value));
  return 'EasyPrivacy Drive request v1\n$core\n$device\n$node\n'
      '${command.op}\n${command.volume}\n${field(command.path)}\n'
      '${field(command.target)}\n${field(command.cursor)}\n${command.size}\n'
      '${command.sha256}\n$nonce\n$expires';
}
