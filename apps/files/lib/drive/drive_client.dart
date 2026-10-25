import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as hashes;
import 'package:easyprivacy_core_sdk/easyprivacy_core_sdk.dart';
import 'package:easyprivacy_protocol/easyprivacy_protocol.dart' hide FileMode;
import 'package:path/path.dart' as paths;
import 'package:path_provider/path_provider.dart';
import '../transfer/secure_channel.dart';
import '../transfer/send_engine.dart';

class DriveNode {
  const DriveNode(this.id, this.device, this.name);
  final String id, device, name;
}

class DriveVolume {
  DriveVolume.fromJson(Map<String, dynamic> v)
    : id = v['id'] as String,
      name = v['name'] as String,
      quota = v['quota'] as int,
      used = v['used'] as int,
      reserved = v['reserved'] as int,
      available = v['available'] as bool {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(id) ||
        name.length > 180 ||
        quota < 1 ||
        used < 0 ||
        reserved < 0) {
      throw const FormatException('Invalid Drive storage information.');
    }
  }
  final String id, name;
  final int quota, used, reserved;
  final bool available;
}

class DriveEntry {
  DriveEntry.fromJson(Map<String, dynamic> v)
    : name = v['name'] as String,
      directory = v['directory'] as bool,
      size = v['size'] as int,
      modified = DateTime.parse(v['modified'] as String) {
    if (!validDrivePath(name) || name.contains('/') || size < 0) {
      throw const FormatException('Invalid cloud item.');
    }
  }
  final String name;
  final bool directory;
  final int size;
  final DateTime modified;
}

class DriveDownload {
  const DriveDownload(this.file, this.name, this.size);
  final File file;
  final String name;
  final int size;
  Future<void> discard() async {
    if (RegExp(r'^[0-9a-f]{32}$').hasMatch(paths.basename(file.parent.path)) &&
        paths.basename(file.path) == 'payload' &&
        await file.parent.exists()) {
      await file.parent.delete(recursive: true);
    }
  }
}

/// An injectable byte transport; production uses only Core's private stream.
class DriveConnection {
  DriveConnection(this.incoming, this.sink, this.onClose);
  final Stream<List<int>> incoming;
  final IOSink sink;
  final Future<void> Function() onClose;
  Future<void> close() => onClose();
}

class _Reader {
  _Reader(Stream<List<int>> stream) : iterator = StreamIterator(stream);
  final StreamIterator<List<int>> iterator;
  List<int> chunk = const [];
  int offset = 0;
  Future<Uint8List> read(int count) async {
    final result = Uint8List(count);
    var n = 0;
    while (n < count) {
      if (offset == chunk.length) {
        if (!await iterator.moveNext().timeout(const Duration(seconds: 60))) {
          throw const TransferFailure(
            'The Drive connection ended before the transfer finished.',
          );
        }
        chunk = iterator.current;
        offset = 0;
        if (chunk.isEmpty) continue;
      }
      final take = (count - n) < (chunk.length - offset)
          ? count - n
          : chunk.length - offset;
      result.setRange(n, n + take, chunk, offset);
      n += take;
      offset += take;
    }
    return result;
  }

  Future<Map<String, dynamic>> frame() async {
    final size = ByteData.sublistView(await read(4)).getUint32(0);
    if (size < 1 || size > 65536) {
      throw const TransferFailure('Invalid Drive response.');
    }
    final value = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(await read(size))) as Map,
    );
    if (value['status'] == 'error') {
      throw TransferFailure(
        value['error'] as String? ?? 'The Drive request failed.',
      );
    }
    if (value['status'] != 'ok' && value['status'] != 'ready') {
      throw const TransferFailure('Invalid Drive response.');
    }
    return value;
  }
}

class _Session {
  _Session(this.connection) : reader = _Reader(connection.incoming);
  final DriveConnection connection;
  final _Reader reader;
}

class DriveClient {
  DriveClient({
    PrivateServicesClient? services,
    this.openConnection,
    this.authorize,
    this.cacheRoot,
  }) : services = services ?? PrivateServicesClient();
  final PrivateServicesClient services;
  final Future<DriveConnection> Function(DriveNode)? openConnection;
  final Future<Map<String, dynamic>> Function(DriveNode, DriveCommand, String)?
  authorize;
  final Future<Directory> Function()? cacheRoot;
  final _active = <DriveConnection>{};
  bool _closed = false;
  int _epoch = 0;
  Future<List<DriveNode>> nodes() async => [
    for (final value in await services.services())
      if (value['kind'] == 'drive' && value['device_id'] is String)
        DriveNode(
          value['id'] as String,
          value['device_id'] as String,
          value['name'] as String,
        ),
  ];
  Future<_Session> _begin(DriveNode node, DriveCommand command) async {
    command.validate();
    final epoch = _epoch;
    final nonce = randomTransferNonce();
    final auth = authorize != null
        ? await authorize!(node, command, nonce)
        : await services.transport.call('driveAuthorize', {
            'node': node.device,
            'nonce': nonce,
            'command': command.toJson(),
          });
    // Validate the returned scope before sending it to the node.
    driveRequestClaim(
      core: auth['core'] as String,
      device: auth['device'] as String,
      node: auth['node'] as String,
      command: DriveCommand.fromJson(
        Map<String, dynamic>.from(auth['command'] as Map),
      ),
      nonce: auth['nonce'] as String,
      expires: auth['expires'] as int,
    );
    if (auth['node'] != node.device ||
        auth['nonce'] != nonce ||
        jsonEncode(
              DriveCommand.fromJson(
                Map<String, dynamic>.from(auth['command'] as Map),
              ).toJson(),
            ) !=
            jsonEncode(command.toJson())) {
      throw const TransferFailure(
        'Core returned an inconsistent Drive authorization.',
      );
    }
    if (_closed || epoch != _epoch) {
      throw const TransferFailure('Drive operation cancelled.');
    }
    final connection = openConnection != null
        ? await openConnection!(node)
        : await (() async {
            final stream = await services.open(node.id);
            return DriveConnection(stream.incoming, stream.sink, stream.close);
          })();
    if (_closed || epoch != _epoch) {
      await connection.close();
      throw const TransferFailure('Drive operation cancelled.');
    }
    _active.add(connection);
    try {
      final raw = utf8.encode(jsonEncode(auth));
      if (raw.length > 8192) {
        throw const TransferFailure('Drive authorization is too large.');
      }
      final header = ByteData(4)..setUint32(0, raw.length);
      connection.sink.add(header.buffer.asUint8List());
      connection.sink.add(raw);
      await connection.sink.flush();
      return _Session(connection);
    } catch (_) {
      await _end(connection);
      rethrow;
    }
  }

  Future<void> _end(DriveConnection c) async {
    if (!_active.remove(c)) return;
    await c.close();
  }

  Future<Map<String, dynamic>> _metadata(
    DriveNode node,
    DriveCommand command,
  ) async {
    final s = await _begin(node, command);
    try {
      return await s.reader.frame();
    } finally {
      await _end(s.connection);
    }
  }

  Future<List<DriveVolume>> volumes(DriveNode node) async => [
    for (final v
        in (await _metadata(node, const DriveCommand(op: 'volumes')))['volumes']
            as List)
      DriveVolume.fromJson(Map<String, dynamic>.from(v as Map)),
  ];
  Future<(List<DriveEntry>, String)> list(
    DriveNode node,
    String volume,
    String path, {
    String cursor = '',
  }) async {
    final result = await _metadata(
      node,
      DriveCommand(op: 'list', volume: volume, path: path, cursor: cursor),
    );
    final next = result['next'] as String;
    if (next.isNotEmpty && (!validDrivePath(next) || next.contains('/'))) {
      throw const FormatException('Invalid Drive page.');
    }
    final entries = (result['entries'] as List)
        .map((v) => DriveEntry.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList();
    if (entries.length > 128) {
      throw const FormatException('Invalid Drive page.');
    }
    return (entries, next);
  }

  Future<void> change(DriveNode node, DriveCommand command) async {
    if (!{'mkdir', 'move', 'delete'}.contains(command.op)) {
      throw ArgumentError('Invalid Drive change.');
    }
    await _metadata(node, command);
  }

  Future<void> upload(
    DriveNode node,
    String volume,
    String path,
    TransferSource source, {
    void Function(int, int)? progress,
  }) async {
    final epoch = _epoch;
    if (source.size < 0 || source.size > maxDriveFileBytes) {
      throw const TransferFailure(
        'Drive currently supports files up to 1 GiB.',
      );
    }
    final digest = await hashes.sha256.bind(source.read(0, null)).first;
    if (_closed || epoch != _epoch) {
      throw const TransferFailure('Upload cancelled.');
    }
    final command = DriveCommand(
      op: 'upload',
      volume: volume,
      path: path,
      size: source.size,
      sha256: digest.toString(),
    );
    final s = await _begin(node, command);
    try {
      if ((await s.reader.frame())['status'] != 'ready') {
        throw const TransferFailure('The server did not accept this upload.');
      }
      var sent = 0;
      Stream<List<int>> chunks() async* {
        await for (final bytes in source.read(0, null)) {
          if (epoch != _epoch) {
            throw const TransferFailure('Upload cancelled.');
          }
          sent += bytes.length;
          if (sent > source.size) {
            throw const TransferFailure(
              'The selected file changed during upload.',
            );
          }
          yield bytes;
          progress?.call(sent, source.size);
        }
      }

      await s.connection.sink.addStream(chunks());
      await s.connection.sink.flush();
      if (sent != source.size) {
        throw const TransferFailure('The selected file changed during upload.');
      }
      final receipt = await s.reader.frame();
      if (receipt['status'] != 'ok' || receipt['sha256'] != digest.toString()) {
        throw const TransferFailure('The Drive upload was not verified.');
      }
    } finally {
      await _end(s.connection);
    }
  }

  Future<DriveDownload> download(
    DriveNode node,
    String volume,
    String path, {
    int limit = maxDriveFileBytes,
    void Function(int, int)? progress,
  }) async {
    final epoch = _epoch;
    final s = await _begin(
      node,
      DriveCommand(op: 'download', volume: volume, path: path),
    );
    Directory? temporary;
    try {
      final head = await s.reader.frame();
      final entry = DriveEntry.fromJson(
        Map<String, dynamic>.from(head['entry'] as Map),
      );
      if (entry.directory || entry.size > limit) {
        throw TransferFailure(
          limit < maxDriveFileBytes
              ? 'This file is too large for an in-app preview. Download it instead.'
              : 'Drive currently supports files up to 1 GiB.',
        );
      }
      var root = cacheRoot != null
          ? await cacheRoot!()
          : Directory(
              paths.join(
                (await getApplicationSupportDirectory()).path,
                'easyprivacy-drive',
              ),
            );
      await root.create(recursive: true);
      root = Directory(await root.resolveSymbolicLinks());
      await for (final old in root.list(followLinks: false)) {
        if (old is Directory &&
            RegExp(r'^[0-9a-f]{32}$').hasMatch(paths.basename(old.path)) &&
            DateTime.now().difference((await old.stat()).modified) >
                const Duration(hours: 24)) {
          await old.delete(recursive: true);
        }
      }
      temporary = await Directory(
        paths.join(root.path, randomTransferNonce().substring(0, 32)),
      ).create();
      final part = File(paths.join(temporary.path, 'payload.part'));
      final file = await part.open(mode: FileMode.write);
      var received = 0;
      final output = _DigestSink();
      final hasher = hashes.sha256.startChunkedConversion(output);
      try {
        while (received < entry.size) {
          if (epoch != _epoch) {
            throw const TransferFailure('Download cancelled.');
          }
          final bytes = await s.reader.read(
            (entry.size - received).clamp(0, 65536),
          );
          await file.writeFrom(bytes);
          hasher.add(bytes);
          received += bytes.length;
          progress?.call(received, entry.size);
        }
        await file.flush();
      } finally {
        hasher.close();
        await file.close();
      }
      final receipt = await s.reader.frame();
      if (epoch != _epoch) {
        throw const TransferFailure('Download cancelled.');
      }
      if (receipt['status'] != 'ok' ||
          receipt['sha256'] != output.digest.toString()) {
        throw const TransferFailure(
          'The downloaded file did not pass verification.',
        );
      }
      final finished = await part.rename(paths.join(temporary.path, 'payload'));
      return DriveDownload(finished, entry.name, entry.size);
    } catch (_) {
      if (temporary != null && await temporary.exists()) {
        await temporary.delete(recursive: true);
      }
      rethrow;
    } finally {
      await _end(s.connection);
    }
  }

  Future<void> cancel() async {
    _epoch++;
    for (final c in _active.toList()) {
      await _end(c);
    }
  }

  void close() {
    _closed = true;
    unawaited(cancel());
    services.close();
  }
}

class _DigestSink implements Sink<hashes.Digest> {
  hashes.Digest? digest;
  @override
  void add(hashes.Digest value) {
    digest = value;
  }

  @override
  void close() {}
}
