import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:easyprivacy_core_sdk/easyprivacy_core_sdk.dart';
import 'package:easyprivacy_protocol/easyprivacy_protocol.dart';
import '../session/core_controller.dart';
import 'native_private_runtime.dart';

class CorePrivateNetwork {
  CorePrivateNetwork(
    this.session,
    this.storage, {
    NativePrivateRuntime Function()? runtimeFactory,
  }) : runtimeFactory = runtimeFactory ?? NativePrivateRuntime.new;
  final CoreController session;
  final FlutterSecureStorage storage;
  final NativePrivateRuntime Function() runtimeFactory;
  NativePrivateRuntime? _runtime;
  PrivateNetworkProfile? _profile;
  String? _receiver;
  DateTime? _renewed;
  DateTime? _receiverUsed;
  DateTime? lastVerified;
  String? message;
  bool _starting = false;
  int _generation = 0;
  int _filesEpoch = 0;
  bool get active => _runtime?.active == true && _profile != null;
  bool get configured => _profile != null;
  Map<String, dynamic> get status => {
    'active': active,
    'starting': _starting,
    'message': message,
    'receiver_active': _receiver != null,
    if (lastVerified != null)
      'last_verified': lastVerified!.toUtc().toIso8601String(),
  };

  Future<void> _foreground(bool active) async {
    if (Platform.isAndroid) {
      await const MethodChannel(
        'org.easyprivacy/core_host',
      ).invokeMethod<void>('privateForeground', {'active': active});
    }
  }

  Future<Map<String, dynamic>> start() async {
    if (active) return status;
    if (_starting) {
      throw const BrokerException(
        'core_busy',
        'The private connection is starting.',
      );
    }
    _starting = true;
    final generation = ++_generation;
    var registered = false;
    try {
      final scope = '${session.fingerprint}:${session.deviceId}';
      final label =
          'easyprivacy.private.key.${sha256.convert(utf8.encode(scope))}';
      final saved = await storage.read(key: label);
      final algorithm = cryptography.X25519();
      final pair = saved == null
          ? await algorithm.newKeyPair()
          : await algorithm.newKeyPairFromSeed(base64Decode(saved));
      final privateKey = base64Encode(await pair.extractPrivateKeyBytes());
      final publicKey = base64Encode((await pair.extractPublicKey()).bytes);
      if (saved == null) await storage.write(key: label, value: privateKey);
      final profile = await session.privateRegister(publicKey);
      registered = true;
      if (generation != _generation) {
        throw const BrokerException(
          'cancelled',
          'Private connection start cancelled.',
        );
      }
      final endpoint = Uri.parse('https://${profile.endpoint}');
      final addresses = await InternetAddress.lookup(
        endpoint.host,
      ).timeout(const Duration(seconds: 8));
      if (addresses.isEmpty) {
        throw const BrokerException(
          'core_unavailable',
          'Could not resolve the private connection endpoint.',
        );
      }
      final address = addresses.firstWhere(
        (a) => a.type == InternetAddressType.IPv4,
        orElse: () => addresses.first,
      );
      final resolved = address.type == InternetAddressType.IPv6
          ? '[${address.address}]:${endpoint.port}'
          : '${address.address}:${endpoint.port}';
      final runtime = runtimeFactory();
      _runtime = runtime;
      await runtime.start({
        'PrivateKey': privateKey,
        'PeerPublicKey': profile.publicKey,
        'Address': profile.localAddress,
        'AllowedPrefix': profile.subnet,
        'Endpoint': resolved,
        'Services': <String, String>{},
      });
      if (generation != _generation) {
        throw const BrokerException(
          'cancelled',
          'Private connection start cancelled.',
        );
      }
      _profile = profile;
      await _foreground(true);
      await probe();
      message = null;
      return status;
    } catch (e) {
      message = e.toString();
      _profile = null;
      await _runtime?.stop();
      _runtime = null;
      if (registered) {
        try {
          await session.privateDisconnect();
        } catch (_) {}
      }
      await _foreground(false);
      rethrow;
    } finally {
      _starting = false;
    }
  }

  Future<Map<String, dynamic>> probe() async {
    final profile = _requireProfile();
    final ticket = await _issue('core', profile.probe);
    final stream = await CorePrivateStream.connect(ticket);
    final watch = Stopwatch()..start();
    try {
      final random = Random.secure();
      final nonce = List.generate(32, (_) => random.nextInt(256));
      stream.sink.add(nonce);
      await stream.sink.flush();
      final reply = <int>[];
      await for (final chunk in stream.incoming.timeout(
        const Duration(seconds: 10),
      )) {
        reply.addAll(chunk);
        if (reply.length >= 32) break;
      }
      if (reply.length != 32 ||
          List.generate(32, (i) => reply[i] == nonce[i]).contains(false)) {
        throw const BrokerException(
          'private_probe_failed',
          'Could not verify the private connection.',
        );
      }
      lastVerified = DateTime.now();
      message = null;
      return {...status, 'latency_ms': watch.elapsedMilliseconds};
    } finally {
      await stream.close();
    }
  }

  PrivateNetworkProfile _requireProfile() {
    if (!active) {
      throw const BrokerException(
        'private_connection_required',
        'Start the private connection in EasyPrivacy Core first.',
      );
    }
    return _profile!;
  }

  Future<Map<String, dynamic>> _issue(
    String capability,
    PrivateServiceTarget target,
  ) async {
    final profile = _requireProfile();
    profile.validateTarget(target);
    return _runtime!.call('issue', {
      'capability': capability,
      'service': target.id,
      'address': target.address,
      'port': target.port,
    });
  }

  Future<List<PrivateServiceTarget>> services() async {
    final profile = _requireProfile();
    final targets = await session.privateServices();
    for (final target in targets) {
      profile.validateTarget(target);
    }
    return targets;
  }

  Future<Map<String, dynamic>> open(String serviceId) async {
    final epoch = _filesEpoch;
    final targets = await services();
    _checkFilesEpoch(epoch);
    final matches = targets.where((v) => v.id == serviceId);
    if (matches.length != 1) {
      throw const BrokerException(
        'not_authorized',
        'This private service is unavailable or not granted.',
      );
    }
    final ticket = await _issue('files', matches.single);
    if (epoch != _filesEpoch) {
      await _runtime?.call('revoke', {'capability': 'files'});
      _checkFilesEpoch(epoch);
    }
    return ticket;
  }

  void _checkFilesEpoch(int epoch) {
    if (epoch != _filesEpoch) {
      throw const BrokerException(
        'grant_required',
        'Files access changed. Try again after enabling Files in Core.',
      );
    }
  }

  Future<Map<String, dynamic>> registerReceiver({bool fromApp = true}) async {
    if (fromApp) _receiverUsed = DateTime.now();
    final epoch = _filesEpoch;
    final profile = _requireProfile();
    final lease = await session.privateReceiver();
    if (epoch != _filesEpoch) {
      try {
        await session.privateReceiverDisconnect();
      } catch (_) {}
      _checkFilesEpoch(epoch);
    }
    profile.validateTargetForReceiver(lease);
    if (lease.deviceId != session.deviceId) {
      throw const BrokerException(
        'invalid_response',
        'The receiver belongs to a different device.',
      );
    }
    final id = lease.id.substring('receiver.'.length);
    if (_receiver != id) {
      if (_receiver != null) {
        await _runtime!.call('closeReceiver', {'receiver': _receiver});
      }
      try {
        await _runtime!.call('receive', {'receiver': id});
        if (epoch != _filesEpoch) {
          await _runtime?.call('closeReceiver', {'receiver': id});
          _checkFilesEpoch(epoch);
        }
      } catch (_) {
        try {
          await session.privateReceiverDisconnect();
        } catch (_) {}
        rethrow;
      }
    }
    _receiver = id;
    _renewed = DateTime.now();
    return {
      'receiver_id': id,
      'expires_at': lease.expiresAt?.toUtc().toIso8601String(),
    };
  }

  Future<Map<String, dynamic>> acceptReceiver(String id) async {
    _requireProfile();
    if (id != _receiver) {
      throw const BrokerException(
        'not_authorized',
        'This receiver is not registered.',
      );
    }
    _receiverUsed = DateTime.now();
    return _runtime!.call('accept', {'receiver': id});
  }

  Future<void> closeReceiver(String id) async {
    if (id != _receiver) {
      throw const BrokerException(
        'not_authorized',
        'This receiver is not registered.',
      );
    }
    _receiver = null;
    _renewed = null;
    await _runtime?.call('closeReceiver', {'receiver': id});
    try {
      await session.privateReceiverDisconnect();
    } catch (_) {}
  }

  Future<void> revokeFiles() async {
    ++_filesEpoch;
    if (_runtime?.active != true) return;
    await _runtime!.call('revoke', {'capability': 'files'});
    if (_receiver != null) {
      _receiver = null;
      _renewed = null;
      try {
        await session.privateReceiverDisconnect();
      } catch (_) {}
    }
  }

  Future<void> maintain(bool filesAllowed) async {
    if (_profile == null) return;
    if (!active || session.authorizationLost) {
      await stop(remote: false);
      message = 'Private connection stopped. Start it again in Core.';
      return;
    }
    if (!filesAllowed) {
      await revokeFiles();
      return;
    }
    if (_receiver != null &&
        DateTime.now().difference(_receiverUsed ?? DateTime(0)) >=
            const Duration(seconds: 45)) {
      await closeReceiver(_receiver!);
      return;
    }
    if (_receiver != null &&
        DateTime.now().difference(_renewed ?? DateTime(0)) >=
            const Duration(seconds: 30) &&
        session.phase == ConnectionPhase.connected) {
      try {
        await registerReceiver(fromApp: false);
      } catch (_) {
        await revokeFiles();
      }
    }
  }

  Future<void> stop({bool remote = true}) async {
    ++_generation;
    ++_filesEpoch;
    _profile = null;
    _receiver = null;
    _renewed = null;
    lastVerified = null;
    await _runtime?.stop();
    _runtime = null;
    if (remote) {
      try {
        await session.privateReceiverDisconnect();
        await session.privateDisconnect();
      } catch (_) {}
    }
    await _foreground(false);
  }
}
