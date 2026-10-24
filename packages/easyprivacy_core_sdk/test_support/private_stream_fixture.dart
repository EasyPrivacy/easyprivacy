import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:easyprivacy_core_sdk/easyprivacy_core_sdk.dart';

/// Synthetic two-way payload; never reads or writes a personal file.
const fixtureBytes = 8 * 1024 * 1024;
const _chunkSize = 64 * 1024;

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

class _Reader {
  _Reader(CorePrivateStream stream)
    : iterator = StreamIterator(stream.incoming);
  final StreamIterator<Uint8List> iterator;
  Uint8List pending = Uint8List(0);
  Future<Uint8List> read(int length) async {
    if (length < 1 || length > _chunkSize) {
      throw StateError('Fixture read exceeds its memory budget.');
    }
    final result = Uint8List(length);
    var offset = 0;
    while (offset < length) {
      if (pending.isEmpty) {
        if (!await iterator.moveNext()) throw StateError('Truncated stream.');
        pending = iterator.current;
        continue;
      }
      final count = pending.length < length - offset
          ? pending.length
          : length - offset;
      result.setRange(offset, offset + count, pending);
      pending = Uint8List.sublistView(pending, count);
      offset += count;
    }
    return result;
  }

  Future<void> close() => iterator.cancel();
}

Uint8List _pattern(int phase) =>
    Uint8List.fromList(List.generate(_chunkSize, (i) => (i + phase) % 251));

Future<Digest> _writePayload(CorePrivateStream stream, int phase) async {
  final header = Uint8List(12)..setRange(0, 8, ascii.encode('EPTEST01'));
  ByteData.sublistView(header).setUint32(8, fixtureBytes);
  stream.sink.add(header);
  final output = _DigestSink();
  final hash = sha256.startChunkedConversion(output);
  final chunk = _pattern(phase);
  for (var remaining = fixtureBytes; remaining > 0; remaining -= chunk.length) {
    hash.add(chunk);
    stream.sink.add(chunk);
    await stream.sink.flush();
  }
  hash.close();
  return output.value!;
}

Future<Digest> _readPayload(_Reader reader, int phase) async {
  final header = await reader.read(12);
  if (ascii.decode(header.sublist(0, 8)) != 'EPTEST01' ||
      ByteData.sublistView(header).getUint32(8) != fixtureBytes) {
    throw StateError('Unexpected synthetic transfer header.');
  }
  final output = _DigestSink(), expected = _DigestSink();
  final hash = sha256.startChunkedConversion(output);
  final expectedHash = sha256.startChunkedConversion(expected);
  final pattern = _pattern(phase);
  for (var remaining = fixtureBytes; remaining > 0; remaining -= _chunkSize) {
    hash.add(await reader.read(_chunkSize));
    expectedHash.add(pattern);
  }
  hash.close();
  expectedHash.close();
  if (output.value != expected.value) {
    throw StateError('Payload hash mismatch.');
  }
  return output.value!;
}

void _checkReceipt(List<int> bytes, Digest expected) {
  if (bytes.length != expected.bytes.length ||
      List.generate(
        bytes.length,
        (i) => bytes[i] != expected.bytes[i],
      ).any((v) => v)) {
    throw StateError('Peer receipt hash mismatch.');
  }
}

Future<void> runFixtureSender(CorePrivateStream stream) async {
  final reader = _Reader(stream);
  try {
    final sent = await _writePayload(stream, 0);
    _checkReceipt(await reader.read(32), sent);
    final received = await _readPayload(reader, 17);
    stream.sink.add(received.bytes);
    await stream.sink.flush();
    if ((await reader.read(1)).single != 0) {
      throw StateError('Peer did not finish.');
    }
  } finally {
    await reader.close();
    await stream.close();
  }
}

Future<void> runFixtureReceiver(CorePrivateStream stream) async {
  final reader = _Reader(stream);
  try {
    final received = await _readPayload(reader, 0);
    stream.sink.add(received.bytes);
    await stream.sink.flush();
    final sent = await _writePayload(stream, 17);
    _checkReceipt(await reader.read(32), sent);
    stream.sink.add([0]);
    await stream.sink.flush();
  } finally {
    await reader.close();
    await stream.close();
  }
}
