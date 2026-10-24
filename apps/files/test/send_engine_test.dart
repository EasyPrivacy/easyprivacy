import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:easyprivacy_protocol/easyprivacy_protocol.dart';
import 'package:easyprivacy_files/transfer/file_store.dart';
import 'package:easyprivacy_files/transfer/secure_channel.dart';
import 'package:easyprivacy_files/transfer/send_engine.dart';
import 'package:flutter_test/flutter_test.dart';

const corePin =
    'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

Future<TransferIdentity> testIdentity(int seed) async {
  final pair = await Ed25519().newKeyPairFromSeed(List.filled(32, seed));
  final public = (await pair.extractPublicKey()).bytes;
  final id = hashes.sha256.convert(public).toString();
  return TransferIdentity(
    core: corePin,
    device: id,
    isPaired: (_) async => true,
    sign: (peer, key, nonce, role) async {
      final expiry = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 120;
      final claim = filesHandshakeClaim(
        core: corePin,
        device: id,
        peer: peer,
        key: key,
        nonce: nonce,
        role: role,
        expires: expiry,
      );
      final signature = await Ed25519().sign(utf8.encode(claim), keyPair: pair);
      return {
        'core': corePin,
        'device': id,
        'peer': peer,
        'key': key,
        'nonce': nonce,
        'role': role,
        'expires': expiry,
        'identity': base64Encode(public),
        'signature': base64Encode(signature.bytes),
      };
    },
  );
}

Future<(SecureTransferChannel, SecureTransferChannel)> socketChannels({
  bool Function()? corrupt,
}) async {
  final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final accepting = listener.first;
  final sender = await Socket.connect(
    InternetAddress.loopbackIPv4,
    listener.port,
  );
  final receiver = await accepting;
  await listener.close();
  var skipHeader = 4;
  var flipped = false;
  final a = SecureTransferChannel(
    TransferLink(
      incoming: sender,
      sink: sender,
      close: () async => sender.destroy(),
    ),
  );
  final b = SecureTransferChannel(
    TransferLink(
      incoming: receiver.map((bytes) {
        if (corrupt?.call() == true && bytes.isNotEmpty) {
          final altered = Uint8List.fromList(bytes);
          for (var i = 0; i < altered.length; i++) {
            if (skipHeader > 0) {
              skipHeader--;
            } else if (!flipped) {
              altered[i] ^= 1;
              flipped = true;
            }
          }
          return altered;
        }
        return bytes;
      }),
      sink: receiver,
      close: () async => receiver.destroy(),
    ),
  );
  addTearDown(() async {
    await a.close();
    await b.close();
  });
  return (a, b);
}

Future<Directory> testDirectory() async {
  final dir = await Directory.systemTemp.createTemp('easyprivacy-send-test-');
  addTearDown(() async {
    final expectedParent = Directory.systemTemp.absolute.path;
    if (dir.absolute.parent.path != expectedParent ||
        !dir.path
            .split(Platform.pathSeparator)
            .last
            .startsWith('easyprivacy-send-test-')) {
      throw StateError('Unexpected test cleanup path.');
    }
    await dir.delete(recursive: true);
  });
  return dir;
}

Future<List<Object>> settle(List<Future<void>> operations) async {
  final failures = <Object>[];
  await Future.wait(
    operations.map(
      (f) => f.catchError((Object e) {
        failures.add(e);
      }),
    ),
  );
  return failures;
}

void main() {
  late TransferIdentity sender, receiver;
  final engine = SendEngine();
  setUp(() async {
    sender = await testIdentity(11);
    receiver = await testIdentity(29);
  });
  TransferSource source(List<int> bytes) => TransferSource(
    name: 'example.bin',
    size: bytes.length,
    read: (start, end) => Stream.fromIterable([bytes.sublist(start, end)]),
  );

  Future<List<Object>> transfer(
    TransferOffer offer,
    TransferSource file,
    TransferFileStore store, {
    TransferCancellation? cancel,
    void Function(int, SecureTransferChannel)? receivingProgress,
    void Function(int)? sendingProgress,
  }) async {
    final (a, b) = await socketChannels();
    final cancellation = cancel ?? TransferCancellation();
    cancellation.attach(b.close);
    return settle([
      (() async {
        try {
          await a.handshake(sender, recipient: receiver.device);
          await engine.send(
            a,
            offer,
            file,
            TransferCancellation(),
            sendingProgress ?? (_) {},
            () {},
          );
        } finally {
          await a.close();
        }
      })(),
      (() async {
        try {
          await b.handshake(receiver);
          final input = await b.readControl();
          expect(input['type'], 'offer');
          final received = TransferOffer.fromJson(input);
          final record = await store.prepare(
            received,
            receiver.core,
            sender.device,
            receiver.device,
          );
          await engine.receive(
            b,
            record,
            cancellation,
            (n) => receivingProgress?.call(n, b),
          );
        } finally {
          await b.close();
        }
      })(),
    ]);
  }

  for (final size in [0, 1, 8 * 1024 * 1024]) {
    test(
      'encrypted Send verifies $size bytes and recipient receipt',
      () async {
        final bytes = Uint8List.fromList(List.generate(size, (i) => i % 251));
        final file = source(bytes),
            store = TransferFileStore(await testDirectory());
        final offer = await engine.offer(
          file,
          sender,
          receiver.device,
          TransferCancellation(),
        );
        expect(await transfer(offer, file, store), isEmpty);
        final record = (await store.records()).single;
        expect(await record.verified, isTrue);
        expect(
          await hashes.sha256.bind(record.completed.openRead()).first,
          hashes.sha256.convert(bytes),
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  test(
    'interruption retains partial file; fresh authenticated connection resumes',
    () async {
      final file = source(
        Uint8List.fromList(List.generate(512 * 1024, (i) => i % 239)),
      );
      final store = TransferFileStore(await testDirectory());
      final offer = await engine.offer(
        file,
        sender,
        receiver.device,
        TransferCancellation(),
      );
      var interrupted = false;
      final failures = await transfer(
        offer,
        file,
        store,
        receivingProgress: (n, channel) {
          if (n >= 128 * 1024 && !interrupted) {
            interrupted = true;
            unawaited(channel.close());
          }
        },
      );
      expect(failures, isNotEmpty);
      final partial = (await store.records()).single;
      final prefix = await partial.partial.length();
      expect(prefix, greaterThanOrEqualTo(128 * 1024));
      int? resumed;
      expect(
        await transfer(
          offer,
          file,
          store,
          sendingProgress: (n) => resumed ??= n,
        ),
        isEmpty,
      );
      expect(resumed, prefix);
      expect(await partial.verified, isTrue);
    },
  );

  test('explicit cancellation removes the recipient partial copy', () async {
    final file = source(Uint8List(512 * 1024)),
        store = TransferFileStore(await testDirectory());
    final offer = await engine.offer(
      file,
      sender,
      receiver.device,
      TransferCancellation(),
    );
    final cancellation = TransferCancellation();
    expect(
      await transfer(
        offer,
        file,
        store,
        cancel: cancellation,
        receivingProgress: (n, _) {
          if (n >= 128 * 1024) cancellation.cancel();
        },
      ),
      isNotEmpty,
    );
    expect(await store.records(), isEmpty);
  });

  test('changed source fails integrity; no unverified copy survives', () async {
    final bytes = Uint8List(256 * 1024), file = source(bytes);
    final offer = await engine.offer(
      file,
      sender,
      receiver.device,
      TransferCancellation(),
    );
    bytes[777] = 1;
    final store = TransferFileStore(await testDirectory());
    expect(await transfer(offer, file, store), isNotEmpty);
    expect(await store.records(), isEmpty);
  });

  test(
    'recipient decline sends no file bytes and creates no partial',
    () async {
      final (a, b) = await socketChannels();
      final file = source([1, 2, 3]);
      final offer = await engine.offer(
        file,
        sender,
        receiver.device,
        TransferCancellation(),
      );
      final results = await settle([
        (() async {
          try {
            await a.handshake(sender, recipient: receiver.device);
            await engine.send(
              a,
              offer,
              file,
              TransferCancellation(),
              (_) {},
              () {},
            );
          } finally {
            await a.close();
          }
        })(),
        (() async {
          try {
            await b.handshake(receiver);
            await b.readControl();
            await b.control({'type': 'decline'});
          } finally {
            await b.close();
          }
        })(),
      ]);
      expect(results.single.toString(), contains('declined'));
    },
  );

  test('encrypted record corruption is rejected', () async {
    var corrupt = false;
    final (a, b) = await socketChannels(corrupt: () => corrupt);
    await Future.wait([
      a.handshake(sender, recipient: receiver.device),
      b.handshake(receiver),
    ]);
    corrupt = true;
    final rejected = expectLater(
      b.readControl(timeout: const Duration(seconds: 3)),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
    await a.control({'type': 'offer', 'name': 'private.txt'});
    await rejected;
  });

  test(
    'authenticated sender cancellation removes the remote partial file',
    () async {
      final (a, b) = await socketChannels();
      await Future.wait([
        a.handshake(sender, recipient: receiver.device),
        b.handshake(receiver),
      ]);
      final file = source(Uint8List(256 * 1024));
      final offer = await engine.offer(
        file,
        sender,
        receiver.device,
        TransferCancellation(),
      );
      await a.control({'type': 'offer', ...offer.toJson()});
      await b.readControl();
      final store = TransferFileStore(await testDirectory());
      final record = await store.prepare(
        offer,
        receiver.core,
        sender.device,
        receiver.device,
      );
      final received = expectLater(
        engine.receive(b, record, TransferCancellation(), (_) {}),
        throwsA(isA<TransferCancelled>()),
      );
      expect((await a.readControl())['type'], 'accept');
      await a.data(Uint8List(64 * 1024));
      await a.cancel();
      await received;
      expect(await store.records(), isEmpty);
    },
  );

  test(
    'attestation binds identity, core, recipient, role, freshness and key',
    () async {
      final key = base64Encode(
        (await X25519().newKeyPair().then((p) => p.extractPublicKey())).bytes,
      );
      final nonce = randomTransferNonce();
      final certificate = await sender.sign(
        receiver.device,
        key,
        nonce,
        'sender',
      );
      Future<void> verify(Map<String, dynamic> c) => verifyFilesAttestation(
        c,
        core: corePin,
        device: sender.device,
        peer: receiver.device,
        nonce: nonce,
        role: 'sender',
      );
      await verify(certificate);
      for (final alteration in [
        {'device': receiver.device},
        {'core': corePin.replaceAll('A', 'B')},
        {'peer': sender.device},
        {'role': 'receiver'},
        {'expires': 1},
        {'key': base64Encode(List.filled(32, 99))},
        {'signature': base64Encode(List.filled(64, 0))},
      ]) {
        await expectLater(
          verify({...certificate, ...alteration}),
          throwsA(isA<TransferFailure>()),
        );
      }
    },
  );

  test(
    'unsafe names, excessive sizes and oversized frames fail closed',
    () async {
      for (final name in [
        '../secret',
        'C:\\private',
        '.',
        '',
        'a\nb',
        'NUL.txt',
      ]) {
        expect(
          () => TransferOffer(
            id: 'a' * 32,
            name: name,
            size: 1,
            digest: 'b' * 64,
          ),
          throwsA(isA<TransferFailure>()),
        );
      }
      expect(
        () => TransferOffer(
          id: 'a' * 32,
          name: 'ok',
          size: maxTransferBytes + 1,
          digest: 'b' * 64,
        ),
        throwsA(isA<TransferFailure>()),
      );
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepting = listener.first;
      final socket = await Socket.connect(
            InternetAddress.loopbackIPv4,
            listener.port,
          ),
          other = await accepting;
      await listener.close();
      final channel = SecureTransferChannel(
        TransferLink(
          incoming: other,
          sink: other,
          close: () async => other.destroy(),
        ),
      );
      try {
        final handshake = channel.handshake(receiver);
        socket.add(
          (ByteData(4)..setUint32(0, 0xffffffff)).buffer.asUint8List(),
        );
        await socket.flush();
        await expectLater(handshake, throwsA(isA<TransferFailure>()));
      } finally {
        socket.destroy();
        await channel.close();
      }
    },
  );

  test(
    'retention removes only owned records; completed retransmission is safe',
    () async {
      final root = await testDirectory(),
          store = TransferFileStore(root),
          file = source([1, 2]);
      final offer = await engine.offer(
        file,
        sender,
        receiver.device,
        TransferCancellation(),
      );
      expect(await transfer(offer, file, store), isEmpty);
      expect(await transfer(offer, file, store), isEmpty);
      final recordFile = File('${root.path}/${offer.id}/record.json');
      final json =
          jsonDecode(await recordFile.readAsString()) as Map<String, dynamic>;
      json['created'] = DateTime.now()
          .subtract(const Duration(hours: 25))
          .toIso8601String();
      await recordFile.writeAsString(jsonEncode(json));
      final unrelated = await File(
        '${root.path}/keep.txt',
      ).writeAsString('untouched');
      expect(await store.records(), isEmpty);
      expect(await unrelated.readAsString(), 'untouched');
    },
  );
}
