import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:easyprivacy_protocol/easyprivacy_protocol.dart' hide FileMode;
import 'package:easyprivacy_files/drive/drive_client.dart';
import 'package:easyprivacy_files/transfer/send_engine.dart';
import 'package:easyprivacy_files/transfer/secure_channel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'real Go Drive node supports independent clients, explicit copies, quota, changes and cancellation',
    () async {
      final binary = Platform.environment['EP_DRIVE_GO_TEST_BIN']!;
      final process = await Process.start('wsl.exe', [
        '-d',
        'Ubuntu',
        '--',
        'env',
        'EP_DRIVE_FIXTURE=1',
        '.tools/drive-tests',
        '-test.run=^TestDriveClientFixture\$',
        '-test.v',
      ], workingDirectory: File(binary).parent.parent.path);
      final stdout = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      final errors = process.stderr.transform(utf8.decoder).join();
      final clients = <DriveClient>[];
      final root = await Directory.systemTemp.createTemp('ep-drive-client-');
      addTearDown(() async {
        for (final c in clients) {
          c.close();
        }
        await process.stdin.close();
        await process.exitCode.timeout(
          const Duration(seconds: 20),
          onTimeout: () {
            process.kill();
            return -1;
          },
        );
        await stdout.cancel();
        await errors;
        if (root.absolute.parent.path != Directory.systemTemp.absolute.path ||
            !root.path
                .split(Platform.pathSeparator)
                .last
                .startsWith('ep-drive-client-')) {
          throw StateError('Unexpected Drive fixture cleanup path.');
        }
        await root.delete(recursive: true);
      });
      Map<String, dynamic>? ready;
      while (await stdout.moveNext().timeout(const Duration(seconds: 30))) {
        if (stdout.current.startsWith('DRIVE_FIXTURE ')) {
          ready =
              jsonDecode(stdout.current.substring(14)) as Map<String, dynamic>;
          break;
        }
      }
      expect(ready, isNotNull);
      final port = ready!['port'] as int, volume = ready['volume'] as String;
      const node = DriveNode(
        'receiver.fixture',
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        'Test storage',
      );
      Future<DriveClient> make(int seed, String cacheName) async {
        final pair = await Ed25519().newKeyPairFromSeed(List.filled(32, seed));
        final public = (await pair.extractPublicKey()).bytes;
        final device = hashes.sha256.convert(public).toString();
        final client = DriveClient(
          cacheRoot: () async => Directory('${root.path}/$cacheName'),
          authorize: (_, command, nonce) async {
            final expires =
                DateTime.now()
                    .add(const Duration(minutes: 2))
                    .millisecondsSinceEpoch ~/
                1000;
            final core = 'SHA256:${'A' * 64}';
            final claim = driveRequestClaim(
              core: core,
              device: device,
              node: node.device,
              command: command,
              nonce: nonce,
              expires: expires,
            );
            final signature = await Ed25519().sign(
              utf8.encode(claim),
              keyPair: pair,
            );
            return {
              'command': command.toJson(),
              'core': core,
              'device': device,
              'node': node.device,
              'nonce': nonce,
              'expires': expires,
              'identity': base64Encode(public),
              'signature': base64Encode(signature.bytes),
            };
          },
          openConnection: (_) async {
            Socket? socket;
            final end = DateTime.now().add(const Duration(seconds: 15));
            while (socket == null) {
              try {
                socket = await Socket.connect(
                  '127.0.0.1',
                  port,
                  timeout: const Duration(seconds: 2),
                );
              } catch (_) {
                if (DateTime.now().isAfter(end)) rethrow;
                await Future<void>.delayed(const Duration(milliseconds: 300));
              }
            }
            final connected = socket;
            return DriveConnection(connected, connected, () async {
              connected.destroy();
            });
          },
        );
        clients.add(client);
        return client;
      }

      final first = await make(11, 'cache-a'),
          second = await make(29, 'cache-b');
      final original = await File(
        '${root.path}/original.md',
      ).writeAsString('independent original');
      TransferSource source(File file) => TransferSource(
        name: 'notes.md',
        size: file.lengthSync(),
        read: (start, end) => file.openRead(start, end),
      );
      expect((await first.volumes(node)).single.used, 0);
      await first.change(
        node,
        DriveCommand(op: 'mkdir', volume: volume, path: 'Documents'),
      );
      await first.upload(node, volume, 'Documents/notes.md', source(original));
      expect(await original.readAsString(), 'independent original');
      expect(
        (await second.list(node, volume, 'Documents')).$1.single.name,
        'notes.md',
      );
      expect(
        await Directory('${root.path}/cache-b').exists(),
        isFalse,
        reason: 'Metadata browsing must never download content.',
      );
      final copy = await second.download(node, volume, 'Documents/notes.md');
      expect(await copy.file.readAsString(), 'independent original');
      await original.writeAsString('local edit does not update cloud');
      final same = await first.download(node, volume, 'Documents/notes.md');
      expect(await same.file.readAsString(), 'independent original');
      await first.change(
        node,
        DriveCommand(
          op: 'move',
          volume: volume,
          path: 'Documents/notes.md',
          target: 'Documents/moved.md',
        ),
      );
      expect(
        (await second.list(node, volume, 'Documents')).$1.single.name,
        'moved.md',
      );
      await first.change(
        node,
        DriveCommand(op: 'delete', volume: volume, path: 'Documents'),
      );
      expect((await first.list(node, volume, '')).$1, isEmpty);
      expect(await copy.file.readAsString(), 'independent original');
      expect(await original.readAsString(), 'local edit does not update cloud');
      await expectLater(
        first.upload(
          node,
          volume,
          'oversized.bin',
          TransferSource(
            name: 'oversized.bin',
            size: 1024 * 1024 + 1,
            read: (_, _) => Stream.value(List.filled(1024 * 1024 + 1, 1)),
          ),
        ),
        throwsA(isA<TransferFailure>()),
      );
      var reads = 0;
      await expectLater(
        first.upload(
          node,
          volume,
          'changed.bin',
          TransferSource(
            name: 'changed.bin',
            size: 4,
            read: (_, _) => Stream.value(List.filled(4, ++reads)),
          ),
        ),
        throwsA(isA<TransferFailure>()),
      );
      expect((await first.list(node, volume, '')).$1, isEmpty);
      expect((await first.volumes(node)).single.reserved, 0);
      await expectLater(
        first.change(
          node,
          DriveCommand(op: 'delete', volume: volume, path: '../outside'),
        ),
        throwsA(isA<FormatException>()),
      );
      final bytes = List<int>.generate(256 * 1024, (i) => i % 251);
      await first.upload(
        node,
        volume,
        'large.bin',
        TransferSource(
          name: 'large.bin',
          size: bytes.length,
          read: (_, _) => Stream.value(bytes),
        ),
      );
      var cancelled = false;
      await expectLater(
        second.download(
          node,
          volume,
          'large.bin',
          progress: (done, total) {
            if (!cancelled) {
              cancelled = true;
              unawaited(second.cancel());
            }
          },
        ),
        throwsA(anything),
      );
      final cache = Directory('${root.path}/cache-b');
      // The earlier successful copy remains; no cancelled partial copy is published.
      expect((await cache.list().toList()).length, 1);
      await copy.discard();
      await same.discard();
    },
    skip:
        !Platform.isWindows ||
        Platform.environment['EP_DRIVE_GO_TEST_BIN'] == null,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
