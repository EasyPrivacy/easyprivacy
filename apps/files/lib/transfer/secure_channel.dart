import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:easyprivacy_protocol/easyprivacy_protocol.dart';

const transferChunkBytes = 64 * 1024;

class TransferFailure implements Exception {
  const TransferFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class TransferCancelled extends TransferFailure {
  const TransferCancelled() : super('Transfer cancelled.');
}

String randomTransferNonce() => List.generate(
  32,
  (_) => Random.secure().nextInt(256),
).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

typedef HandshakeSigner =
    Future<Map<String, dynamic>> Function(
      String peer,
      String key,
      String nonce,
      String role,
    );

class TransferIdentity {
  const TransferIdentity({
    required this.core,
    required this.device,
    required this.sign,
    required this.isPaired,
  });
  final String core, device;
  final HandshakeSigner sign;
  final Future<bool> Function(String device) isPaired;
}

String _claim(Map<String, dynamic> a) => filesHandshakeClaim(
  core: a['core'] as String,
  device: a['device'] as String,
  peer: a['peer'] as String,
  key: a['key'] as String,
  nonce: a['nonce'] as String,
  role: a['role'] as String,
  expires: a['expires'] as int,
);

Future<void> verifyFilesAttestation(
  Map<String, dynamic> a, {
  required String core,
  required String device,
  required String peer,
  required String nonce,
  required String role,
}) async {
  try {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (a.length != 9 ||
        a['core'] != core ||
        a['device'] != device ||
        a['peer'] != peer ||
        a['nonce'] != nonce ||
        a['role'] != role ||
        a['expires'] is! int ||
        (a['expires'] as int) < now ||
        (a['expires'] as int) > now + 180) {
      throw const FormatException();
    }
    final identity = base64Decode(a['identity'] as String);
    final signature = base64Decode(a['signature'] as String);
    if (identity.length != 32 ||
        signature.length != 64 ||
        hashes.sha256.convert(identity).toString() != device ||
        !await Ed25519().verify(
          utf8.encode(_claim(a)),
          signature: Signature(
            signature,
            publicKey: SimplePublicKey(identity, type: KeyPairType.ed25519),
          ),
        )) {
      throw const FormatException();
    }
  } catch (_) {
    throw const TransferFailure('Could not verify the paired device.');
  }
}

/// A bounded byte connection; production uses only CorePrivateStream.
class TransferLink {
  TransferLink({
    required this.incoming,
    required this.sink,
    required this.close,
  });
  final Stream<List<int>> incoming;
  final IOSink sink;
  final Future<void> Function() close;
}

class _Reader {
  _Reader(Stream<List<int>> stream) : iterator = StreamIterator(stream);
  final StreamIterator<List<int>> iterator;
  List<int> pending = const [];
  int position = 0;
  Future<Uint8List> read(int length) async {
    if (length < 1 || length > transferChunkBytes + 64) {
      throw const TransferFailure('Invalid transfer frame size.');
    }
    final out = Uint8List(length);
    var offset = 0;
    while (offset < length) {
      if (position == pending.length) {
        if (!await iterator.moveNext()) {
          throw const TransferFailure(
            'Connection interrupted. Retry to resume.',
          );
        }
        pending = iterator.current;
        position = 0;
        continue;
      }
      final count = min(length - offset, pending.length - position);
      out.setRange(offset, offset + count, pending, position);
      position += count;
      offset += count;
    }
    return out;
  }
}

/// Fresh X25519 keys authenticated by the existing enrolled device identities.
/// Directional HKDF keys and sequenced AEAD records protect metadata and bytes
/// beyond the WireGuard hops, including from a passive core-node operator.
class SecureTransferChannel {
  SecureTransferChannel(this.link) : _reader = _Reader(link.incoming);
  final TransferLink link;
  final _Reader _reader;
  SecretKey? _sendKey, _receiveKey;
  List<int> _transcript = const [];
  final _cipher = AesGcm.with256bits();
  int _sent = 0, _received = 0;
  bool _closed = false;
  Future<void> _writing = Future.value();

  Future<void> _writeFrame(List<int> bytes) async {
    if (_closed) throw const TransferFailure('Transfer cancelled.');
    if (bytes.isEmpty || bytes.length > transferChunkBytes + 64) {
      throw const TransferFailure('Invalid transfer frame size.');
    }
    final header = ByteData(4)..setUint32(0, bytes.length);
    link.sink.add(header.buffer.asUint8List());
    link.sink.add(bytes);
    await link.sink.flush().timeout(const Duration(seconds: 30));
  }

  Future<Uint8List> _readFrame(Duration timeout) async => (() async {
    final header = await _reader.read(4);
    final length = ByteData.sublistView(header).getUint32(0);
    return _reader.read(length);
  })().timeout(timeout);

  Future<Map<String, dynamic>> _readHello() async {
    final bytes = await _readFrame(const Duration(seconds: 30));
    if (bytes.length > 4096) {
      throw const TransferFailure('Invalid device handshake.');
    }
    return Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
  }

  Future<String> handshake(
    TransferIdentity identity, {
    String? recipient,
  }) async {
    final pair = await X25519().newKeyPair();
    final key = base64Encode((await pair.extractPublicKey()).bytes);
    late final Map<String, dynamic> sender, receiver;
    final sending = recipient != null;
    if (sending) {
      sender = await identity.sign(
        recipient,
        key,
        randomTransferNonce(),
        'sender',
      );
      await _writeFrame(utf8.encode(jsonEncode(sender)));
      receiver = await _readHello();
      await verifyFilesAttestation(
        receiver,
        core: identity.core,
        device: recipient,
        peer: identity.device,
        nonce: sender['nonce'] as String,
        role: 'receiver',
      );
    } else {
      sender = await _readHello();
      final device = sender['device'];
      if (device is! String || !await identity.isPaired(device)) {
        throw const TransferFailure(
          'The sending device is not paired with this core.',
        );
      }
      await verifyFilesAttestation(
        sender,
        core: identity.core,
        device: device,
        peer: identity.device,
        nonce: sender['nonce'] as String,
        role: 'sender',
      );
      receiver = await identity.sign(
        device,
        key,
        sender['nonce'] as String,
        'receiver',
      );
      await _writeFrame(utf8.encode(jsonEncode(receiver)));
    }
    // Canonical claims avoid JSON key-order dependencies across implementations.
    _transcript = hashes.sha256
        .convert(
          utf8.encode(
            '${_claim(sender)}\n${sender['identity']}\n${sender['signature']}\n'
            '${_claim(receiver)}\n${receiver['identity']}\n${receiver['signature']}',
          ),
        )
        .bytes;
    final other = sending ? receiver : sender;
    final shared = await X25519().sharedSecretKey(
      keyPair: pair,
      remotePublicKey: SimplePublicKey(
        base64Decode(other['key'] as String),
        type: KeyPairType.x25519,
      ),
    );
    if ((await shared.extractBytes()).every((b) => b == 0)) {
      throw const TransferFailure('Invalid device key agreement.');
    }
    Future<SecretKey> derive(String direction) =>
        Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
          secretKey: shared,
          nonce: _transcript,
          info: utf8.encode('EasyPrivacy Files v1 $direction'),
        );
    _sendKey = await derive(sending ? 'sender' : 'receiver');
    _receiveKey = await derive(sending ? 'receiver' : 'sender');
    await control({'type': 'ready'});
    if ((await readControl())['type'] != 'ready') {
      throw const TransferFailure('Device handshake did not finish.');
    }
    return other['device'] as String;
  }

  List<int> _nonce(int sequence) {
    if (sequence >= 0x100000000) {
      throw const TransferFailure('Transfer session limit reached.');
    }
    return (ByteData(12)..setUint64(4, sequence)).buffer.asUint8List();
  }

  Future<void> _send(int type, List<int> bytes) {
    final pending = _writing.then((_) async {
      final nonce = _nonce(_sent++);
      final box = await _cipher.encrypt(
        [type, ...bytes],
        secretKey: _sendKey!,
        nonce: nonce,
        aad: [..._transcript, ...nonce],
      );
      await _writeFrame([...box.cipherText, ...box.mac.bytes]);
    });
    _writing = pending.then<void>((_) {}, onError: (Object _) {});
    return pending;
  }

  Future<(int, Uint8List)> read({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final bytes = await _readFrame(timeout);
    if (bytes.length < 17) {
      throw const TransferFailure('Invalid encrypted transfer record.');
    }
    final nonce = _nonce(_received++);
    final plain = await _cipher.decrypt(
      SecretBox(
        bytes.sublist(0, bytes.length - 16),
        nonce: nonce,
        mac: Mac(bytes.sublist(bytes.length - 16)),
      ),
      secretKey: _receiveKey!,
      aad: [..._transcript, ...nonce],
    );
    if (plain.isEmpty) throw const TransferFailure('Empty transfer record.');
    if (plain.first == 0 &&
        plain.length <= 4097 &&
        (jsonDecode(utf8.decode(plain.sublist(1))) as Map)['type'] ==
            'cancel') {
      throw const TransferCancelled();
    }
    return (plain.first, Uint8List.fromList(plain.sublist(1)));
  }

  Future<void> control(Map<String, Object?> value) async {
    final bytes = utf8.encode(jsonEncode(value));
    if (bytes.length > 4096) {
      throw const TransferFailure('Transfer metadata is too large.');
    }
    await _send(0, bytes);
  }

  Future<Map<String, dynamic>> readControl({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final (type, bytes) = await read(timeout: timeout);
    if (type != 0 || bytes.length > 4096) {
      throw const TransferFailure('Unexpected transfer message.');
    }
    return Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
  }

  Future<void> data(List<int> bytes) async {
    if (bytes.isEmpty || bytes.length > transferChunkBytes) {
      throw const TransferFailure('Invalid file chunk.');
    }
    await _send(1, bytes);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await link.close();
    await _reader.iterator.cancel();
  }

  Future<void> cancel() async {
    try {
      if (_sendKey != null && !_closed) {
        await control({'type': 'cancel'}).timeout(const Duration(seconds: 2));
      }
    } catch (_) {
      /* A lost connection is recovered using its partial file. */
    } finally {
      await close();
    }
  }
}
