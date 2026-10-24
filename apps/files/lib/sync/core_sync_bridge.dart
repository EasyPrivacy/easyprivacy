import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../transfer/secure_channel.dart';
import '../transfer/send_engine.dart';
import 'sync_engine.dart';

class SyncPeer {
  const SyncPeer(this.coreId, this.engineId, this.name);
  final String coreId, engineId, name;
}

/// Syncthing sees only loopback sockets. This adapter carries the original BEP
/// TLS connection through an authenticated, encrypted Core stream in both
/// directions; it never resolves or dials a remote Internet/LAN address.
class CoreSyncBridge {
  CoreSyncBridge({
    required this.engine,
    required this.open,
    required this.allowed,
  });
  final SyncEngine engine;
  final Future<SecureTransferChannel> Function(SyncPeer) open;
  final bool Function(SyncPeer) allowed;
  final _listeners = <String, ServerSocket>{};
  final _channels = <String, Set<SecureTransferChannel>>{};
  bool _disposed = false;

  Future<void> add(SyncPeer peer) async {
    if (_disposed || !validSyncDevice(peer.engineId)) {
      throw const TransferFailure('Invalid Sync peer.');
    }
    var listener = _listeners[peer.coreId];
    if (listener == null) {
      listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      _listeners[peer.coreId] = listener;
      listener.listen((socket) => unawaited(_outgoing(peer, socket)));
    }
    await engine.configurePeer(peer.engineId, peer.name, listener.port);
  }

  Future<void> _outgoing(SyncPeer peer, Socket socket) async {
    SecureTransferChannel? channel;
    try {
      if (_disposed ||
          !allowed(peer) ||
          (_channels[peer.coreId]?.length ?? 0) >= 2) {
        throw const TransferFailure('Sync peer is paused.');
      }
      channel = await open(peer);
      if (_disposed || !allowed(peer)) {
        throw const TransferFailure('Sync peer is paused.');
      }
      _channels.putIfAbsent(peer.coreId, () => {}).add(channel);
      await channel.control({
        'type': 'sync-connect',
        'device_id': engine.deviceId,
      });
      final response = await channel.readControl();
      if (response['type'] != 'sync-connected' ||
          response['device_id'] != peer.engineId) {
        throw const TransferFailure(
          'The other device has not enabled this Sync link.',
        );
      }
      await bridgeSyncSocket(socket, channel);
    } catch (_) {
      socket.destroy();
    } finally {
      if (channel != null) {
        _channels[peer.coreId]?.remove(channel);
        await channel.close();
      }
    }
  }

  Future<void> incoming(
    SyncPeer peer,
    SecureTransferChannel channel,
    Map<String, dynamic> request,
  ) async {
    if (_disposed ||
        !allowed(peer) ||
        request['device_id'] != peer.engineId ||
        (_channels[peer.coreId]?.length ?? 0) >= 2) {
      throw const TransferFailure('This Sync connection is not authorized.');
    }
    _channels.putIfAbsent(peer.coreId, () => {}).add(channel);
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        engine.syncPort!,
        timeout: const Duration(seconds: 5),
      );
      await channel.control({
        'type': 'sync-connected',
        'device_id': engine.deviceId,
      });
      // Syncthing routinely closes duplicate or idle connections. Only the
      // authentication/authorization errors above should reach the Send UI.
      try {
        await bridgeSyncSocket(socket, channel);
      } catch (_) {}
    } finally {
      socket?.destroy();
      _channels[peer.coreId]?.remove(channel);
    }
  }

  Future<void> disconnect(String coreId) async {
    for (final channel
        in _channels[coreId]?.toList() ?? <SecureTransferChannel>[]) {
      await channel.close();
    }
    _channels.remove(coreId);
  }

  Future<void> close() async {
    _disposed = true;
    for (final listener in _listeners.values) {
      await listener.close();
    }
    _listeners.clear();
    for (final peer in _channels.keys.toList()) {
      await disconnect(peer);
    }
  }
}

Future<void> bridgeSyncSocket(
  Socket socket,
  SecureTransferChannel channel,
) async {
  var pingPending = false;
  final timer = Timer.periodic(const Duration(seconds: 10), (_) async {
    if (pingPending) return;
    pingPending = true;
    try {
      await channel.control({'type': 'sync-ping'});
    } catch (_) {
      socket.destroy();
      await channel.close();
    } finally {
      pingPending = false;
    }
  });
  final upload = (() async {
    await for (final bytes in boundedTransferChunks(socket)) {
      await channel.data(bytes);
    }
  })();
  final download = (() async {
    while (true) {
      final (type, bytes) = await channel.read();
      if (type == 0 &&
          bytes.length <= 4096 &&
          (jsonDecode(utf8.decode(bytes)) as Map)['type'] == 'sync-ping') {
        continue;
      }
      if (type != 1 || bytes.isEmpty || bytes.length > transferChunkBytes) {
        throw const TransferFailure('Invalid Sync stream.');
      }
      socket.add(bytes);
      await socket.flush().timeout(const Duration(seconds: 30));
    }
  })();
  // Listen to both futures before either can fail during remote shutdown.
  final settled = Future.wait(
    [upload, download].map((f) => f.then<void>((_) {}, onError: (Object _) {})),
  );
  try {
    await Future.any([upload, download]);
  } finally {
    timer.cancel();
    socket.destroy();
    await channel.close();
    await settled.timeout(
      const Duration(seconds: 3),
      onTimeout: () => <void>[],
    );
  }
}
