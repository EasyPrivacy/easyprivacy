import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:easyprivacy_core_sdk/easyprivacy_core_sdk.dart';
import 'package:path/path.dart' as paths;
import 'package:path_provider/path_provider.dart';
import '../transfer/file_store.dart';
import '../transfer/secure_channel.dart';
import '../transfer/send_engine.dart';

enum TransferPhase {
  preparing,
  approval,
  transferring,
  complete,
  interrupted,
  cancelled,
  declined,
}

class SendDevice {
  const SendDevice(this.id, this.name, this.service);
  final String id, name;
  final String? service;
  bool get online => service != null;
}

class TransferJob {
  TransferJob({
    required this.name,
    required this.size,
    required this.peer,
    required this.incoming,
    this.phase = TransferPhase.preparing,
    this.source,
    this.offer,
    this.record,
  });
  final String name;
  final int size;
  final SendDevice peer;
  final bool incoming;
  TransferPhase phase;
  int bytes = 0;
  String? message;
  bool saved = false;
  bool running = false;
  final TransferSource? source;
  TransferOffer? offer;
  StoredTransfer? record;
  Completer<bool>? decision;
  TransferCancellation cancellation = TransferCancellation();
  bool get active =>
      running ||
      {
        TransferPhase.preparing,
        TransferPhase.approval,
        TransferPhase.transferring,
      }.contains(phase);
}

/// Files owns transfer jobs and storage. Core provides only scoped discovery,
/// device-key delegations and byte streams; no file path crosses that boundary.
class DeviceTransferProvider extends ChangeNotifier {
  DeviceTransferProvider({
    PrivateServicesClient? client,
    Future<TransferFileStore> Function()? storeFactory,
    bool autoStart = true,
  }) : client = client ?? PrivateServicesClient(),
       storeFactory =
           storeFactory ??
           (() async => TransferFileStore(
             Directory(
               paths.join(
                 (await getApplicationSupportDirectory()).path,
                 'easyprivacy-send',
               ),
             ),
           )) {
    if (autoStart) unawaited(initialize());
  }
  final PrivateServicesClient client;
  final Future<TransferFileStore> Function() storeFactory;
  final engine = SendEngine();
  final List<TransferJob> jobs = [];
  List<SendDevice> devices = [];
  bool receiving = false, refreshing = false, connected = false;
  String? error;
  TransferFileStore? _store;
  Timer? _timer;
  bool _disposed = false, _busy = false;
  int _receiveGeneration = 0;
  String? _receiver;
  bool _receiveStarting = false;
  DateTime _heartbeat = DateTime(0);
  TransferCancellation? _connectionCancellation;
  bool get busy => _busy;
  void changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    try {
      _store = await storeFactory();
      final records = await _store!.records();
      for (final record in records) {
        final complete = await record.verified;
        final job = TransferJob(
          name: record.offer.name,
          size: record.offer.size,
          peer: SendDevice(record.sender, 'Paired device', null),
          incoming: true,
          phase: complete ? TransferPhase.complete : TransferPhase.interrupted,
          offer: record.offer,
          record: record,
        );
        job.bytes = complete
            ? record.offer.size
            : (await record.partial.exists()
                  ? await record.partial.length()
                  : 0);
        job.message = complete
            ? 'Verified. Save a copy to keep this file.'
            : 'Ask the sender to retry; the partial file can resume.';
        jobs.add(job);
      }
      await refresh();
      if (!_disposed) {
        _timer = Timer.periodic(
          const Duration(seconds: 5),
          (_) => unawaited(refresh()),
        );
      }
    } catch (e) {
      error = e.toString();
      changed();
    }
  }

  Future<void> refresh() async {
    if (_disposed || refreshing) return;
    refreshing = true;
    try {
      final status = await client.status();
      connected = status['active'] == true;
      if (!connected) {
        throw const TransferFailure(
          'Start the private connection in EasyPrivacy Core.',
        );
      }
      devices = await _devices();
      if (receiving && DateTime.now().difference(_heartbeat).inSeconds >= 15) {
        final id = await client.registerReceiver();
        _heartbeat = DateTime.now();
        if (id != _receiver) {
          _receiver = id;
          unawaited(_listen(id, ++_receiveGeneration));
        }
      }
      error = null;
    } catch (e) {
      error = e.toString();
      connected = false;
      devices = [];
    } finally {
      refreshing = false;
      changed();
    }
  }

  Future<List<SendDevice>> _devices() async {
    final devices = <SendDevice>[];
    String? after;
    do {
      final result = await client.transport.call('filesDevices', {
        'after': ?after,
      });
      devices.addAll(
        (result['devices'] as List).map(
          (v) => SendDevice(
            v['id'] as String,
            v['name'] as String,
            v['service_id'] as String?,
          ),
        ),
      );
      final next = result['next'] as String?;
      if (next != null && (next == after || devices.length >= 256)) {
        throw const TransferFailure('Invalid device directory.');
      }
      after = next;
    } while (after != null);
    return devices;
  }

  Future<TransferIdentity> _identity() async {
    final summary = await client.transport.call('getSummary');
    if (summary['has_session'] != true ||
        summary['fingerprint'] is! String ||
        summary['device_id'] is! String) {
      throw const TransferFailure(
        'Enable Files access and connect this device in Core.',
      );
    }
    return TransferIdentity(
      core: summary['fingerprint'] as String,
      device: summary['device_id'] as String,
      sign: (peer, key, nonce, role) => client.transport.call(
        'filesHandshake',
        {'peer': peer, 'key': key, 'nonce': nonce, 'role': role},
      ),
      isPaired: (id) async => (await _devices()).any((d) => d.id == id),
    );
  }

  Future<void> setReceiving(bool enabled) async {
    if (!enabled) {
      receiving = false;
      ++_receiveGeneration;
      _connectionCancellation?.cancel();
      for (final job in jobs.where((j) => j.incoming && j.active)) {
        cancel(job);
      }
      final id = _receiver;
      _receiver = null;
      if (id != null) {
        try {
          await client.closeReceiver(id);
        } catch (_) {}
      }
      changed();
      return;
    }
    if (receiving || _disposed || _receiveStarting) return;
    _receiveStarting = true;
    final startGeneration = ++_receiveGeneration;
    try {
      _store ??= await storeFactory();
      final id = await client.registerReceiver();
      if (_disposed || startGeneration != _receiveGeneration) {
        await client.closeReceiver(id);
        return;
      }
      _receiver = id;
      receiving = true;
      error = null;
      _heartbeat = DateTime.now();
      unawaited(_listen(id, startGeneration));
    } catch (e) {
      error = e.toString();
    } finally {
      _receiveStarting = false;
    }
    changed();
  }

  Future<void> _listen(String id, int generation) async {
    try {
      while (!_disposed && receiving && generation == _receiveGeneration) {
        final stream = await client.accept(id);
        if (stream == null) continue;
        if (_disposed || generation != _receiveGeneration || _busy) {
          await stream.close();
          continue;
        }
        _busy = true;
        try {
          await _incoming(
            SecureTransferChannel(
              TransferLink(
                incoming: stream.incoming,
                sink: stream.sink,
                close: stream.close,
              ),
            ),
          );
        } finally {
          _busy = false;
        }
        changed();
      }
    } catch (e) {
      if (!_disposed && generation == _receiveGeneration) {
        error = e.toString();
        await setReceiving(false);
      }
    }
  }

  Future<void> _incoming(SecureTransferChannel channel) async {
    TransferJob? job;
    final cancellation = TransferCancellation()..attach(channel.cancel);
    _connectionCancellation = cancellation;
    try {
      final identity = await _identity();
      final sender = await channel.handshake(identity);
      final peers = await _devices();
      final peer = peers.where((d) => d.id == sender).single;
      final message = await channel.readControl();
      if (message['type'] != 'offer') {
        throw const TransferFailure('Expected a file offer.');
      }
      final offer = TransferOffer.fromJson(message);
      if (offer.id !=
          TransferOffer.identifier(
            identity.core,
            sender,
            identity.device,
            offer.name,
            offer.size,
            offer.digest,
          )) {
        throw const TransferFailure('Invalid transfer identity.');
      }
      cancellation.check();
      jobs.removeWhere(
        (j) => j.incoming && !j.active && j.offer?.id == offer.id,
      );
      job =
          TransferJob(
              name: offer.name,
              size: offer.size,
              peer: peer,
              incoming: true,
              phase: TransferPhase.approval,
              offer: offer,
            )
            ..decision = Completer<bool>()
            ..running = true
            ..cancellation = cancellation;
      _add(job);
      final accepted = await job.decision!.future.timeout(
        const Duration(minutes: 4),
        onTimeout: () => false,
      );
      cancellation.check();
      if (!accepted) {
        await channel.control({'type': 'decline'});
        job.phase = TransferPhase.declined;
        return;
      }
      job.record = await _store!.prepare(
        offer,
        identity.core,
        sender,
        identity.device,
      );
      await engine.receive(
        channel,
        job.record!,
        cancellation,
        (bytes) => _progress(job!, bytes),
      );
      job.phase = TransferPhase.complete;
      job.message = 'SHA-256 verified. Save a copy to keep this file.';
    } catch (e) {
      if (job != null) {
        job.phase = cancellation.cancelled || e is TransferCancelled
            ? TransferPhase.cancelled
            : TransferPhase.interrupted;
        job.message = cancellation.cancelled || e is TransferCancelled
            ? 'Partial file removed.'
            : e.toString();
      } else if (!cancellation.cancelled) {
        error = e.toString();
      }
    } finally {
      await cancellation.closed;
      await channel.close();
      if (cancellation.cancelled) await job?.record?.delete();
      job?.running = false;
      _connectionCancellation = null;
      changed();
    }
  }

  void accept(TransferJob job, bool accepted) {
    if (job.decision?.isCompleted == false) job.decision!.complete(accepted);
  }

  DateTime _lastProgress = DateTime(0);
  void _progress(TransferJob job, int bytes) {
    job.phase = TransferPhase.transferring;
    job.bytes = bytes;
    final now = DateTime.now();
    if (bytes == job.size ||
        now.difference(_lastProgress).inMilliseconds > 100) {
      _lastProgress = now;
      changed();
    }
  }

  void _add(TransferJob job) {
    while (jobs.length >= 16) {
      final index = jobs.indexWhere((j) => !j.active && j.record == null);
      if (index == -1) break;
      jobs.removeAt(index);
    }
    jobs.insert(0, job);
    changed();
  }

  Future<void> send(TransferSource source, SendDevice peer) async {
    if (_busy || _disposed) return;
    _busy = true;
    final job = TransferJob(
      name: safeTransferName(source.name),
      size: source.size,
      peer: peer,
      incoming: false,
      source: source,
    );
    job.running = true;
    _add(job);
    SecureTransferChannel? channel;
    try {
      final identity = await _identity();
      final offer = await engine.offer(
        source,
        identity,
        peer.id,
        job.cancellation,
      );
      job.offer = offer;
      final current = (await _devices()).where(
        (d) => d.id == peer.id && d.online,
      );
      if (current.length != 1) {
        throw const TransferFailure(
          'Open Files and enable receiving on the other device, then retry.',
        );
      }
      job.cancellation.check();
      final stream = await client.open(current.single.service!);
      channel = SecureTransferChannel(
        TransferLink(
          incoming: stream.incoming,
          sink: stream.sink,
          close: stream.close,
        ),
      );
      job.cancellation.attach(channel.cancel);
      job.cancellation.check();
      await channel.handshake(identity, recipient: peer.id);
      await engine.send(
        channel,
        offer,
        source,
        job.cancellation,
        (bytes) => _progress(job, bytes),
        () {
          job.phase = TransferPhase.approval;
          changed();
        },
      );
      job.phase = TransferPhase.complete;
      job.message = 'The recipient verified this file.';
    } catch (e) {
      job.phase = job.cancellation.cancelled || e is TransferCancelled
          ? TransferPhase.cancelled
          : TransferPhase.interrupted;
      job.message = job.cancellation.cancelled
          ? 'Transfer cancelled.'
          : e.toString();
    } finally {
      await job.cancellation.closed;
      await channel?.close();
      job.running = false;
      _busy = false;
      changed();
    }
  }

  void cancel(TransferJob job) {
    job.cancellation.cancel();
    accept(job, false);
    job.phase = TransferPhase.cancelled;
    changed();
  }

  Future<void> remove(TransferJob job) async {
    if (job.active) return;
    try {
      await job.record?.delete();
      jobs.remove(job);
    } catch (e) {
      error = e.toString();
    }
    changed();
  }

  Future<void> saved(TransferJob job) async {
    await job.record?.delete();
    job.record = null;
    job.saved = true;
    job.message = 'Saved to your chosen location.';
    changed();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _connectionCancellation?.cancel();
    for (final job in jobs.where((j) => j.active)) {
      cancel(job);
    }
    unawaited(setReceiving(false).whenComplete(client.close));
    super.dispose();
  }
}
