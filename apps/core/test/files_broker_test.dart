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
  List<PrivateServiceTarget> targets = [];
  @override
  Future<List<PrivateServiceTarget>> privateServices() async => targets;
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

  Map<String, dynamic> driveRequest() {
    session.targets = [
      PrivateServiceTarget.fromJson({
        'id': 'receiver.${'1' * 32}',
        'kind': 'drive',
        'name': 'Storage node',
        'device_id': peer.id,
        'address': '10.87.0.4',
        'port': 41931,
        'expires_at': DateTime.now()
            .add(const Duration(minutes: 2))
            .toUtc()
            .toIso8601String(),
      }),
    ];
    return {
      'node': peer.id,
      'nonce': 'c' * 64,
      'command': const DriveCommand(
        op: 'download',
        volume: '11111111111111111111111111111111',
        path: 'café/notes.md',
      ).toJson(),
    };
  }

  test(
    'Drive delegation signs one exact command without exporting enrollment',
    () async {
      final request = driveRequest();
      final result = await runtime.handle('files', 'driveAuthorize', request);
      final command = DriveCommand.fromJson(
        Map<String, dynamic>.from(result['command'] as Map),
      );
      final claim = driveRequestClaim(
        core: pin,
        device: identity.id,
        node: peer.id,
        command: command,
        nonce: result['nonce'] as String,
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
      expect(command.path, 'café/notes.md');
      expect(jsonEncode(result), isNot(contains(identity.encodedSeed)));
    },
  );
  test(
    'Drive requires Files grant, an active Drive advertisement and a paired node',
    () async {
      final request = driveRequest();
      await expectLater(
        runtime.handle('vpn', 'driveAuthorize', request),
        throwsA(isA<BrokerException>()),
      );
      session.targets = [];
      await expectLater(
        runtime.handle('files', 'driveAuthorize', request),
        throwsA(isA<BrokerException>()),
      );
      driveRequest();
      session.peers = [PairedDevice(peer.id, 'Revoked storage', true)];
      await expectLater(
        runtime.handle('files', 'driveAuthorize', request),
        throwsA(isA<BrokerException>()),
      );
    },
  );
  test(
    'Drive refuses traversal, extra fields and a grant revoked during issuance',
    () async {
      final request = driveRequest();
      await expectLater(
        runtime.handle('files', 'driveAuthorize', {
          ...request,
          'url': 'https://example.test',
        }),
        throwsA(isA<BrokerException>()),
      );
      await expectLater(
        runtime.handle('files', 'driveAuthorize', {
          ...request,
          'command': {...(request['command'] as Map), 'path': '../private'},
        }),
        throwsA(isA<FormatException>()),
      );
      session.beforeDevices = () async {
        FlutterSecureStorage.setMockInitialValues({});
      };
      await expectLater(
        runtime.handle('files', 'driveAuthorize', request),
        throwsA(isA<BrokerException>()),
      );
    },
  );
  test('Drive claim matches the node interoperability vector', () {
    expect(
      driveRequestClaim(
        core: pin,
        device: 'a' * 64,
        node: 'b' * 64,
        command: const DriveCommand(
          op: 'download',
          volume: '11111111111111111111111111111111',
          path: 'café/notes.md',
        ),
        nonce: 'c' * 64,
        expires: 1900000000,
      ),
      'EasyPrivacy Drive request v1\n$pin\n${'a' * 64}\n${'b' * 64}\ndownload\n${'1' * 32}\nY2Fmw6kvbm90ZXMubWQ=\n\n\n0\n\n${'c' * 64}\n1900000000',
    );
  });

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
