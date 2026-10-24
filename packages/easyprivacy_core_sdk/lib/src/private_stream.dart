import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'broker_transport.dart';

/// Bytes use a pinned, single-use local TLS connection rather than RPC payloads.
class CorePrivateStream {
  CorePrivateStream._(this._socket, this._iterator, this._first);
  final SecureSocket _socket;
  final StreamIterator<Uint8List> _iterator;
  final Uint8List _first;
  bool _read = false;
  IOSink get sink => _socket;
  Stream<Uint8List> get incoming async* {
    if (_read) throw StateError('A private stream can only be read once.');
    _read = true;
    try {
      if (_first.isNotEmpty) yield _first;
      while (await _iterator.moveNext()) {
        yield _iterator.current;
      }
    } finally {
      await _iterator.cancel();
      _socket.destroy();
    }
  }

  Future<void> close() async {
    _socket.destroy();
    await _iterator.cancel();
  }

  static Future<CorePrivateStream> connect(Map<String, dynamic> ticket) async {
    final port = ticket['port'], pin = ticket['pin'], token = ticket['ticket'];
    if (ticket['protocol'] != 1 ||
        port is! int ||
        port < 1 ||
        port > 65535 ||
        pin is! String ||
        !RegExp(r'^SHA256:[0-9A-F]{64}$').hasMatch(pin) ||
        token is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(token)) {
      throw const BrokerException(
        'invalid_response',
        'Core returned an invalid private stream.',
      );
    }
    bool matches(X509Certificate cert) =>
        'SHA256:${sha256.convert(cert.der).toString().toUpperCase()}' == pin &&
        !DateTime.now().isBefore(cert.startValidity) &&
        DateTime.now().isBefore(cert.endValidity);
    final socket = await SecureSocket.connect(
      '127.0.0.1',
      port,
      context: SecurityContext(withTrustedRoots: false),
      onBadCertificate: matches,
      timeout: const Duration(seconds: 10),
    );
    StreamIterator<Uint8List>? iterator;
    try {
      if (socket.peerCertificate == null || !matches(socket.peerCertificate!)) {
        throw const BrokerException(
          'identity_mismatch',
          'Could not verify the local Core stream.',
        );
      }
      socket.write('${jsonEncode({'protocol': 1, 'ticket': token})}\n');
      await socket.flush();
      iterator = StreamIterator(socket);
      if (!await iterator.moveNext().timeout(const Duration(seconds: 15)) ||
          iterator.current.isEmpty ||
          iterator.current.first != 0) {
        throw const BrokerException(
          'stream_unavailable',
          'The private service did not accept the connection.',
        );
      }
      return CorePrivateStream._(
        socket,
        iterator,
        Uint8List.sublistView(iterator.current, 1),
      );
    } catch (_) {
      socket.destroy();
      await iterator?.cancel();
      rethrow;
    }
  }
}

class PrivateServicesClient {
  PrivateServicesClient({BrokerTransport? transport})
    : transport = transport ?? PlatformBrokerTransport('files');
  final BrokerTransport transport;
  Future<Map<String, dynamic>> status() => transport.call('privateStatus');
  Future<List<Map<String, dynamic>>> services() async =>
      ((await transport.call('listServices'))['services'] as List)
          .map((v) => Map<String, dynamic>.from(v as Map))
          .toList();
  Future<CorePrivateStream> open(String serviceId) async =>
      CorePrivateStream.connect(
        await transport.call('openStream', {'service_id': serviceId}),
      );
  Future<String> registerReceiver() async =>
      (await transport.call('registerReceiver'))['receiver_id'] as String;
  Future<CorePrivateStream?> accept(String receiverId) async {
    final result = await transport.call('acceptReceiver', {
      'receiver_id': receiverId,
    });
    return result['waiting'] == true ? null : CorePrivateStream.connect(result);
  }

  Future<void> closeReceiver(String receiverId) async {
    await transport.call('closeReceiver', {'receiver_id': receiverId});
  }

  void close() => transport.close();
}
