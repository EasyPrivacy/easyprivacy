import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'file_store.dart';
import 'secure_channel.dart';

class TransferSource {
  const TransferSource({
    required this.name,
    required this.size,
    required this.read,
  });
  final String name;
  final int size;
  final Stream<List<int>> Function(int start, int? end) read;
}

class TransferCancellation {
  bool cancelled = false;
  Future<void>? _closing;
  Future<void> get closed => _closing ?? Future.value();
  final Set<Future<void> Function()> _closers = {};
  void check() {
    if (cancelled) throw const TransferCancelled();
  }

  void attach(Future<void> Function() close) {
    _closers.add(close);
    if (cancelled) unawaited(close());
  }

  void detach(Future<void> Function() close) => _closers.remove(close);
  void cancel() {
    if (cancelled) return;
    cancelled = true;
    _closing = Future.wait(
      _closers.toList().map(
        (close) => close().then<void>((_) {}, onError: (Object _) {}),
      ),
    );
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

Stream<List<int>> boundedTransferChunks(Stream<List<int>> input) async* {
  await for (final chunk in input) {
    for (var offset = 0; offset < chunk.length; offset += transferChunkBytes) {
      final end = offset + transferChunkBytes;
      yield chunk.sublist(offset, end > chunk.length ? chunk.length : end);
    }
  }
}

class SendEngine {
  Future<TransferOffer> offer(
    TransferSource source,
    TransferIdentity identity,
    String recipient,
    TransferCancellation cancellation,
  ) async {
    if (source.size < 0 || source.size > maxTransferBytes) {
      throw const TransferFailure('File size is not supported.');
    }
    final output = _DigestSink(), hash = sha256;
    final sink = hash.startChunkedConversion(output);
    var count = 0;
    await for (final bytes in boundedTransferChunks(source.read(0, null))) {
      cancellation.check();
      count += bytes.length;
      if (count > source.size) {
        throw const TransferFailure(
          'The selected file changed. Select it again.',
        );
      }
      sink.add(bytes);
    }
    sink.close();
    cancellation.check();
    if (count != source.size) {
      throw const TransferFailure(
        'The selected file changed. Select it again.',
      );
    }
    final digest = output.value.toString(),
        name = safeTransferName(source.name);
    return TransferOffer(
      id: TransferOffer.identifier(
        identity.core,
        identity.device,
        recipient,
        name,
        count,
        digest,
      ),
      name: name,
      size: count,
      digest: digest,
    );
  }

  Future<void> send(
    SecureTransferChannel channel,
    TransferOffer offer,
    TransferSource source,
    TransferCancellation cancellation,
    void Function(int) progress,
    void Function() waiting,
  ) async {
    await channel.control({'type': 'offer', ...offer.toJson()});
    waiting();
    final response = await channel.readControl(
      timeout: const Duration(minutes: 5),
    );
    cancellation.check();
    if (response['type'] == 'decline') {
      throw const TransferFailure('The recipient declined this file.');
    }
    final offset = response['offset'];
    if (response['type'] != 'accept' ||
        offset is! int ||
        offset < 0 ||
        offset > offer.size) {
      throw const TransferFailure('Invalid recipient response.');
    }
    var sent = offset;
    progress(sent);
    await for (final bytes in boundedTransferChunks(
      source.read(offset, null),
    )) {
      cancellation.check();
      if (sent + bytes.length > offer.size) {
        throw const TransferFailure(
          'The selected file changed. Select it again.',
        );
      }
      await channel.data(bytes);
      sent += bytes.length;
      progress(sent);
    }
    if (sent != offer.size) {
      throw const TransferFailure(
        'The selected file changed. Select it again.',
      );
    }
    await channel.control({'type': 'finish', 'sha256': offer.digest});
    final receipt = await channel.readControl();
    cancellation.check();
    if (receipt['type'] != 'complete' ||
        receipt['id'] != offer.id ||
        receipt['sha256'] != offer.digest) {
      throw const TransferFailure(
        'The recipient did not verify this file. Retry to resume.',
      );
    }
  }

  Future<void> receive(
    SecureTransferChannel channel,
    StoredTransfer record,
    TransferCancellation cancellation,
    void Function(int) progress,
  ) async {
    final output = _DigestSink();
    final hash = sha256.startChunkedConversion(output);
    RandomAccessFile? file;
    final alreadyComplete = await record.verified;
    final payload = alreadyComplete ? record.completed : record.partial;
    if (await FileSystemEntity.type(payload.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const TransferFailure('The partial file is unavailable.');
    }
    var received = await payload.length();
    if (received > record.offer.size) {
      await record.delete();
      throw const TransferFailure('Invalid partial file.');
    }
    // Rehash the prefix instead of trusting persisted in-memory digest state.
    await for (final chunk in payload.openRead()) {
      cancellation.check();
      hash.add(chunk);
    }
    try {
      if (!alreadyComplete) {
        file = await payload.open(mode: FileMode.append);
      }
      await channel.control({'type': 'accept', 'offset': received});
      progress(received);
      while (received < record.offer.size) {
        cancellation.check();
        final (type, bytes) = await channel.read();
        if (type != 1 ||
            bytes.isEmpty ||
            bytes.length > transferChunkBytes ||
            received + bytes.length > record.offer.size) {
          throw const TransferFailure('Invalid file data.');
        }
        await file!.writeFrom(bytes);
        hash.add(bytes);
        received += bytes.length;
        progress(received);
      }
      final finish = await channel.readControl();
      hash.close();
      if (finish['type'] != 'finish' ||
          finish['sha256'] != record.offer.digest ||
          output.value.toString() != record.offer.digest) {
        await file?.close();
        file = null;
        await record.delete();
        throw const TransferFailure(
          'File integrity check failed. Send the file again.',
        );
      }
      cancellation.check();
      if (file != null) {
        await file.flush();
        await file.close();
        file = null;
      }
      if (!alreadyComplete) await payload.rename(record.completed.path);
      await channel.control({
        'type': 'complete',
        'id': record.offer.id,
        'sha256': record.offer.digest,
      });
    } on TransferCancelled {
      await file?.close();
      file = null;
      await record.delete();
      rethrow;
    } finally {
      await file?.close();
      if (cancellation.cancelled) await record.delete();
    }
  }
}
