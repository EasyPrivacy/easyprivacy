import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:easyprivacy_protocol/easyprivacy_protocol.dart';
import 'package:easyprivacy_files/sync/core_sync_bridge.dart';
import 'package:easyprivacy_files/sync/sync_engine.dart';
import 'package:easyprivacy_files/transfer/secure_channel.dart';
import 'package:flutter_test/flutter_test.dart';

Future<TransferIdentity> bridgeIdentity(int seed) async {
  final pair = await Ed25519().newKeyPairFromSeed(List.filled(32, seed));
  final public = (await pair.extractPublicKey()).bytes;
  final id = hashes.sha256.convert(public).toString();
  const core =
      'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
  return TransferIdentity(
    core: core,
    device: id,
    isPaired: (_) async => true,
    sign: (peer, key, nonce, role) async {
      final expires = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 120;
      final claim = filesHandshakeClaim(
        core: core,
        device: id,
        peer: peer,
        key: key,
        nonce: nonce,
        role: role,
        expires: expires,
      );
      return {
        'core': core,
        'device': id,
        'peer': peer,
        'key': key,
        'nonce': nonce,
        'role': role,
        'expires': expires,
        'identity': base64Encode(public),
        'signature': base64Encode(
          (await Ed25519().sign(utf8.encode(claim), keyPair: pair)).bytes,
        ),
      };
    },
  );
}

void main() {
  test(
    'real Syncthing replicas use encrypted bridges for edits, deletes and conflicts',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'easyprivacy-sync-bridge-test-',
      );
      final a = SyncEngine(root: Directory('${root.path}/a')),
          b = SyncEngine(root: Directory('${root.path}/b'));
      final ia = await bridgeIdentity(11), ib = await bridgeIdentity(29);
      final failures = <Object>[];
      var allow = true, connections = 0;
      late CoreSyncBridge ba, bb;
      final channels = <SecureTransferChannel>[];
      Future<SecureTransferChannel> open(
        TransferIdentity self,
        TransferIdentity other,
        SyncEngine selfEngine,
        CoreSyncBridge remote,
      ) async {
        connections++;
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
            accept = server.first;
        final socket = await Socket.connect(
              InternetAddress.loopbackIPv4,
              server.port,
            ),
            accepted = await accept;
        await server.close();
        final outbound = SecureTransferChannel(
          TransferLink(
            incoming: socket,
            sink: socket,
            close: () async => socket.destroy(),
          ),
        );
        final inbound = SecureTransferChannel(
          TransferLink(
            incoming: accepted,
            sink: accepted,
            close: () async => accepted.destroy(),
          ),
        );
        channels.addAll([outbound, inbound]);
        unawaited(() async {
          try {
            await inbound.handshake(other);
            final message = await inbound.readControl();
            await remote.incoming(
              SyncPeer(self.device, selfEngine.deviceId!, 'Synthetic device'),
              inbound,
              message,
            );
          } catch (e) {
            if (allow) failures.add(e);
          } finally {
            await inbound.close();
          }
        }());
        await outbound.handshake(self, recipient: other.device);
        return outbound;
      }

      addTearDown(() async {
        allow = false;
        await ba.close();
        await bb.close();
        for (final channel in channels) {
          await channel.close();
        }
        await a.stop();
        await b.stop();
        if (root.absolute.parent.path != Directory.systemTemp.absolute.path ||
            !root.path
                .split(Platform.pathSeparator)
                .last
                .startsWith('easyprivacy-sync-bridge-test-')) {
          throw StateError('Unexpected cleanup path.');
        }
        await root.delete(recursive: true);
      });
      ba = CoreSyncBridge(
        engine: a,
        allowed: (_) => allow,
        open: (_) => open(ia, ib, a, bb),
      );
      bb = CoreSyncBridge(
        engine: b,
        allowed: (_) => allow,
        open: (_) => open(ib, ia, b, ba),
      );
      await a.start();
      await b.start();
      await ba.add(SyncPeer(ib.device, b.deviceId!, 'Synthetic B'));
      await bb.add(SyncPeer(ia.device, a.deviceId!, 'Synthetic A'));
      final folder = 'ep-${'a' * 32}';
      await a.configureFolder(folder, 'Test', b.deviceId!);
      await b.configureFolder(folder, 'Test', a.deviceId!);
      Future<void> until(
        Future<bool> Function() condition,
        String reason,
      ) async {
        final deadline = DateTime.now().add(const Duration(seconds: 45));
        while (DateTime.now().isBefore(deadline)) {
          if (await condition()) return;
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        fail(
          '$reason; stream failures: $failures; A: ${a.diagnostics.take(5).join(' | ')}; B: ${b.diagnostics.take(5).join(' | ')}',
        );
      }

      final af = File('${a.folder(folder).path}/example.txt'),
          bf = File('${b.folder(folder).path}/example.txt');
      await af.writeAsString('from A');
      await a.scan(folder);
      await until(
        () async => await bf.exists() && await bf.readAsString() == 'from A',
        'A to B did not sync',
      );
      await bf.writeAsString('from B, changed');
      await b.scan(folder);
      await until(
        () async => await af.readAsString() == 'from B, changed',
        'B to A did not sync',
      );
      await af.delete();
      await a.scan(folder);
      await until(() async => !await bf.exists(), 'Deletion did not propagate');
      expect(
        await Directory('${b.folder(folder).path}/.stversions').exists(),
        isTrue,
      );
      await af.writeAsString('shared baseline');
      await a.scan(folder);
      await until(
        () async =>
            await bf.exists() && await bf.readAsString() == 'shared baseline',
        'Baseline did not sync',
      );
      allow = false;
      await ba.disconnect(ib.device);
      await bb.disconnect(ia.device);
      await af.writeAsString('independent A edit');
      await a.scan(folder);
      await bf.writeAsString('independent B edit');
      await b.scan(folder);
      allow = true;
      await until(
        () async =>
            (await a.folder(folder).list().toList()).any(
              (e) => e.path.contains('.sync-conflict-'),
            ) ||
            (await b.folder(folder).list().toList()).any(
              (e) => e.path.contains('.sync-conflict-'),
            ),
        'Concurrent edit did not retain a conflict copy',
      );
      expect(connections, greaterThan(0));
      for (final engine in [a, b]) {
        final config = await engine.call('GET', 'config') as Map;
        expect((config['options'] as Map)['relaysEnabled'], isFalse);
        expect(jsonEncode(config['devices']), isNot(contains('dynamic')));
      }
    },
    skip: Platform.environment['EASYPRIVACY_SYNC_ENGINE'] == null,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
