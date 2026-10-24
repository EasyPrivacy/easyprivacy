import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:easyprivacy_protocol/easyprivacy_protocol.dart';
import 'package:easyprivacy_core_sdk/easyprivacy_core_sdk.dart';
import 'package:easyprivacy_core/runtime/broker/core_broker_runtime.dart';
import 'package:easyprivacy_core/runtime/storage/profile_store.dart';
import 'package:easyprivacy_core/runtime/session/core_controller.dart';
import 'package:easyprivacy_core/runtime/identity/device_identity.dart';

const pin =
    'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

class FilesStore implements ProfileStore {
  FilesStore(this.profile);
  final CoreProfile profile;
  int reads = 0;
  @override
  Future<CoreProfile?> read() async {
    reads++;
    return profile;
  }

  @override
  Future<void> save(CoreProfile profile) async {}
  @override
  Future<void> delete() async {}
}

class FilesSession extends CoreController {
  FilesSession(this.id, this.peers) {
    phase = ConnectionPhase.connected;
  }
  final String id;
  List<PairedDevice> peers;
  Future<void> Function()? beforeDevices;
  @override
  bool get hasSession => true;
  @override
  bool get isDeviceConnection => true;
  @override
  String? get deviceId => id;
  @override
  String? get fingerprint => pin;
  @override
  Future<void> disconnect({bool authorizationLost = false}) async {}
  @override
  Future<List<PairedDevice>> devices() async {
    await beforeDevices?.call();
    return peers;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DeviceIdentity identity, peer;
  late FilesStore store;
  late FilesSession session;
  late CoreBrokerRuntime runtime;
  late Map<String, dynamic> request;
  setUp(() async {
    identity = await DeviceIdentity.fromSeed(base64Encode(List.filled(32, 11)));
    peer = await DeviceIdentity.fromSeed(base64Encode(List.filled(32, 29)));
    store = FilesStore(
      CoreProfile(
        address: 'example.test',
        username: 'owner',
        fingerprint: pin,
        deviceSeed: identity.encodedSeed,
        deviceId: identity.id,
      ),
    );
    session = FilesSession(identity.id, [
      PairedDevice(peer.id, 'Laptop', false),
    ]);
    FlutterSecureStorage.setMockInitialValues({
      'easyprivacy.broker.allow_files': 'true',
    });
    runtime = CoreBrokerRuntime(store: store, session: session);
    request = {
      'peer': peer.id,
      'key': base64Encode(List.filled(32, 99)),
      'nonce': 'a' * 64,
      'role': 'sender',
    };
  });
  tearDown(() => runtime.shutdown());

  test(
    'Files delegation is scoped to an enrolled peer, role and ephemeral key',
    () async {
      final result = await runtime.handle('files', 'filesHandshake', request);
      expect(result.keys.toSet(), {
        'core',
        'device',
        'peer',
        'key',
        'nonce',
        'role',
        'expires',
        'identity',
        'signature',
      });
      final claim = filesHandshakeClaim(
        core: pin,
        device: identity.id,
        peer: peer.id,
        key: request['key'] as String,
        nonce: request['nonce'] as String,
        role: 'sender',
        expires: result['expires'] as int,
      );
      expect(
        await Ed25519().verify(
          utf8.encode(claim),
          signature: Signature(
            base64Decode(result['signature'] as String),
            publicKey: SimplePublicKey(
              identity.publicKey,
              type: KeyPairType.ed25519,
            ),
          ),
        ),
        isTrue,
      );
      expect(
        result['device'],
        sha256.convert(base64Decode(result['identity'] as String)).toString(),
      );
      expect(jsonEncode(result), isNot(contains(identity.encodedSeed)));
    },
  );
  test('VPN and ungranted Files cannot request a delegation', () async {
    await expectLater(
      runtime.handle('vpn', 'filesHandshake', request),
      throwsA(isA<BrokerException>()),
    );
    FlutterSecureStorage.setMockInitialValues({});
    await expectLater(
      runtime.handle('files', 'filesHandshake', request),
      throwsA(isA<BrokerException>()),
    );
    expect(store.reads, 0);
  });
  test(
    'unknown/revoked peers and arbitrary signing input are rejected',
    () async {
      for (final changes in [
        {'role': 'owner-login'},
        {'key': base64Encode(List.filled(32, 0))},
        {'nonce': 'message to sign'},
      ]) {
        await expectLater(
          runtime.handle('files', 'filesHandshake', {...request, ...changes}),
          throwsFormatException,
        );
      }
      await expectLater(
        runtime.handle('files', 'filesHandshake', {
          ...request,
          'message': 'arbitrary',
        }),
        throwsA(isA<BrokerException>()),
      );
      session.peers = [PairedDevice(peer.id, 'Laptop', true)];
      await expectLater(
        runtime.handle('files', 'filesHandshake', request),
        throwsA(isA<BrokerException>()),
      );
    },
  );
  test(
    'grant revocation during an asynchronous request prevents issuance',
    () async {
      session.beforeDevices = () => const FlutterSecureStorage().write(
        key: 'easyprivacy.broker.allow_files',
        value: 'false',
      );
      await expectLater(
        runtime.handle('files', 'filesHandshake', request),
        throwsA(
          isA<BrokerException>().having(
            (e) => e.code,
            'code',
            'grant_required',
          ),
        ),
      );
    },
  );
  test('device pages fit the broker budget and omit revoked entries', () async {
    session.peers = List.generate(
      40,
      (i) =>
          PairedDevice(i.toRadixString(16).padLeft(64, '0'), '界' * 80, i == 7),
    );
    String? after;
    final found = <String>[];
    do {
      final result = await runtime.handle('files', 'filesDevices', {
        'after': ?after,
      });
      expect(utf8.encode(jsonEncode(result)).length, lessThan(16 * 1024));
      found.addAll((result['devices'] as List).map((v) => v['id'] as String));
      after = result['next'] as String?;
    } while (after != null);
    expect(found.length, 39);
    expect(found.toSet().length, 39);
  });
}
