import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:easyprivacy_core_sdk/easyprivacy_core_sdk.dart';
import 'package:easyprivacy_files/providers/device_transfer_provider.dart';
import 'package:easyprivacy_files/transfer/file_store.dart';
import 'package:easyprivacy_files/transfer/secure_channel.dart';
import 'package:easyprivacy_files/transfer/send_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'sync_bridge_integration_test.dart' show bridgeIdentity;

class ReceiverBroker implements BrokerTransport {
  ReceiverBroker(this.self, this.peer);
  final TransferIdentity self, peer;
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, Object?> arguments = const {},
  ]) async {
    switch (method) {
      case 'getSummary':
        return {
          'has_session': true,
          'fingerprint': self.core,
          'device_id': self.device,
        };
      case 'filesDevices':
        return {
          'devices': [
            {
              'id': peer.device,
              'name': 'Synthetic peer',
              'service_id': 'receiver.test',
            },
          ],
        };
      case 'filesHandshake':
        return self.sign(
          arguments['peer'] as String,
          arguments['key'] as String,
          arguments['nonce'] as String,
          arguments['role'] as String,
        );
      case 'privateStatus':
        return {'active': true};
      default:
        throw StateError(method);
    }
  }

  @override
  void close() {}
}

class SocketCoreStream implements CorePrivateStream {
  SocketCoreStream(this.socket);
  final Socket socket;
  @override
  Stream<Uint8List> get incoming => socket;
  @override
  IOSink get sink => socket;
  @override
  Future<void> close() async => socket.destroy();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ReceiverClient extends PrivateServicesClient {
  ReceiverClient(BrokerTransport broker) : super(transport: broker);
  late ReceiverClient remote;
  final queue = <CorePrivateStream>[];
  final opened = <CorePrivateStream>[];
  int closedReceivers = 0;
  @override
  Future<String> registerReceiver() async => 'receiver.test';
  @override
  Future<CorePrivateStream?> accept(String receiverId) async {
    if (queue.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return queue.isEmpty ? null : queue.removeAt(0);
  }

  @override
  Future<CorePrivateStream> open(String serviceId) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = server.first;
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      server.port,
    );
    final other = await accepted;
    await server.close();
    final stream = SocketCoreStream(socket), inbound = SocketCoreStream(other);
    opened.add(stream);
    remote.opened.add(inbound);
    remote.queue.add(inbound);
    return stream;
  }

  @override
  Future<void> closeReceiver(String receiverId) async {
    closedReceivers++;
  }
}

void main() {
  test(
    'a persistent Sync channel shares its receiver with approved Send',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'ep-shared-receiver-test-',
      );
      final ia = await bridgeIdentity(41), ib = await bridgeIdentity(53);
      final ca = ReceiverClient(ReceiverBroker(ia, ib)),
          cb = ReceiverClient(ReceiverBroker(ib, ia));
      ca.remote = cb;
      cb.remote = ca;
      final a = DeviceTransferProvider(
        client: ca,
        autoStart: false,
        storeFactory: () async =>
            TransferFileStore(Directory('${root.path}/a')),
      );
      final b = DeviceTransferProvider(
        client: cb,
        autoStart: false,
        storeFactory: () async =>
            TransferFileStore(Directory('${root.path}/b')),
      );
      final started = Completer<void>(), release = Completer<void>();
      b.handlers['sync-test'] = (_, _, _, _) async {
        started.complete();
        await release.future;
      };
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await b.setReceiving(false);
        await b.receiveFor('sync', false);
        a.dispose();
        b.dispose();
        for (final stream in [...ca.opened, ...cb.opened]) {
          await stream.close();
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await root.delete(recursive: true);
      });
      await a.initialize();
      await b.initialize();
      await b.receiveFor('sync', true);
      final peer = SendDevice(ib.device, 'Synthetic peer', 'receiver.test');
      final sync = await a.openPeer(peer);
      await sync.control({'type': 'sync-test'});
      await started.future.timeout(const Duration(seconds: 5));
      await b.setReceiving(true);
      b.addListener(() {
        for (final job in b.jobs.where(
          (j) => j.phase == TransferPhase.approval,
        )) {
          b.accept(job, true);
        }
      });
      final payload = List.generate(128 * 1024, (i) => i % 251);
      await a.send(
        TransferSource(
          name: 'shared.bin',
          size: payload.length,
          read: (start, end) => Stream.value(payload.sublist(start, end)),
        ),
        peer,
      );
      expect(
        a.jobs.single.phase,
        TransferPhase.complete,
        reason: a.jobs.single.message,
      );
      expect(await b.jobs.single.record!.completed.readAsBytes(), payload);
      expect(release.isCompleted, isFalse);
      await b.setReceiving(false);
      expect(
        cb.closedReceivers,
        0,
        reason: 'Sync still owns the shared receiver.',
      );
      release.complete();
      await sync.close();
      await b.receiveFor('sync', false);
      expect(cb.closedReceivers, 1);
    },
  );
}
