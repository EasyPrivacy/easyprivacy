import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as crypto;
import 'package:easyprivacy_core/runtime/network/native_private_runtime.dart';
import 'package:easyprivacy_core_sdk/easyprivacy_core_sdk.dart';
import 'package:easyprivacy_protocol/easyprivacy_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final executable = Platform.environment['EASYPRIVACY_CORE_RUNTIME'];
  test(
    'Dart SDK streams bytes through actual native WireGuard processes',
    () async {
      final algorithm = crypto.X25519();
      final a = await algorithm.newKeyPair(), b = await algorithm.newKeyPair();
      final sender = NativePrivateRuntime(executablePath: executable);
      final receiver = NativePrivateRuntime(executablePath: executable);
      addTearDown(sender.stop);
      addTearDown(receiver.stop);
      final bConfig = {
        'PrivateKey': base64Encode(await b.extractPrivateKeyBytes()),
        'PeerPublicKey': base64Encode((await a.extractPublicKey()).bytes),
        'Address': '10.87.0.3',
        'AllowedPrefix': '10.87.0.0/24',
        'Services': <String, String>{},
      };
      final started = await receiver.start(bConfig);
      await sender.start({
        'PrivateKey': base64Encode(await a.extractPrivateKeyBytes()),
        'PeerPublicKey': base64Encode((await b.extractPublicKey()).bytes),
        'Address': '10.87.0.2',
        'AllowedPrefix': '10.87.0.0/24',
        'Endpoint': '127.0.0.1:${started['udp_port']}',
        'Services': <String, String>{},
      });
      final id = List.filled(32, 'a').join();
      await receiver.call('receive', {'receiver': id});
      final ticket = await sender.call('issue', {
        'capability': 'files',
        'service': 'receiver.$id',
        'address': '10.87.0.3',
        'port': 41931,
      });
      await expectLater(
        CorePrivateStream.connect({
          ...ticket,
          'pin': 'SHA256:${List.filled(64, '0').join()}',
        }),
        throwsA(anything),
      );
      final outgoing = await CorePrivateStream.connect(ticket);
      addTearDown(outgoing.close);
      final incomingTicket = await receiver.call('accept', {'receiver': id});
      expect(incomingTicket['waiting'], isNot(true));
      final incoming = await CorePrivateStream.connect(incomingTicket);
      addTearDown(incoming.close);
      final payload = List<int>.generate(3 * 1024 * 1024, (i) => i % 251);
      final received = <int>[];
      final complete = Completer<void>(), closed = Completer<void>();
      final subscription = incoming.incoming.listen(
        (chunk) {
          received.addAll(chunk);
          if (received.length >= payload.length && !complete.isCompleted) {
            complete.complete();
          }
        },
        onDone: () => closed.complete(),
        onError: (Object e) {
          if (!complete.isCompleted) complete.completeError(e);
          if (!closed.isCompleted) closed.complete();
        },
      );
      addTearDown(subscription.cancel);
      outgoing.sink.add(payload);
      await outgoing.sink.flush();
      await complete.future.timeout(const Duration(seconds: 20));
      expect(received.length, payload.length);
      expect(sha256.convert(received), sha256.convert(payload));
      final replies = StreamIterator(outgoing.incoming);
      addTearDown(replies.cancel);
      incoming.sink.add(utf8.encode('receipt'));
      await incoming.sink.flush();
      expect(
        await replies.moveNext().timeout(const Duration(seconds: 10)),
        isTrue,
      );
      expect(utf8.decode(replies.current), 'receipt');
      await sender.call('revoke', {'capability': 'files'});
      expect(
        await replies.moveNext().timeout(const Duration(seconds: 10)),
        isFalse,
      );
      await closed.future.timeout(const Duration(seconds: 10));
      await expectLater(
        CorePrivateStream.connect(ticket),
        throwsA(isA<BrokerException>()),
      );
      await receiver.call('closeReceiver', {'receiver': id});
      await expectLater(
        receiver.call('accept', {'receiver': id}),
        throwsA(isA<BrokerException>()),
      );
    },
    skip: executable == null
        ? 'Set EASYPRIVACY_CORE_RUNTIME to the built native helper.'
        : false,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'private profiles reject routes, ports, and expired receiver leases',
    () {
      final profile = PrivateNetworkProfile.fromJson({
        'protocol': 1,
        'public_key': base64Encode(List.filled(32, 1)),
        'endpoint': 'example.test:51821',
        'address': '10.87.0.2/32',
        'subnet': '10.87.0.0/24',
        'mtu': 1280,
        'keepalive': 25,
        'probe': {'id': 'core.probe', 'address': '10.87.0.1', 'port': 41930},
      });
      final target = {
        'id': 'receiver.${List.filled(32, 'a').join()}',
        'address': '10.87.0.3',
        'port': 41931,
        'expires_at': DateTime.now()
            .add(const Duration(minutes: 2))
            .toUtc()
            .toIso8601String(),
      };
      profile.validateTarget(PrivateServiceTarget.fromJson(target));
      for (final invalid in [
        {...target, 'address': '8.8.8.8'},
        {...target, 'port': 443},
        {...target, 'expires_at': null},
      ]) {
        expect(() => PrivateServiceTarget.fromJson(invalid), throwsA(anything));
      }
      for (final invalid in [
        {...target, 'address': '10.88.0.3'},
        {...target, 'address': profile.localAddress},
        {
          ...target,
          'expires_at': DateTime.now()
              .subtract(const Duration(seconds: 1))
              .toUtc()
              .toIso8601String(),
        },
      ]) {
        expect(
          () => profile.validateTarget(PrivateServiceTarget.fromJson(invalid)),
          throwsFormatException,
        );
      }
    },
  );
}
