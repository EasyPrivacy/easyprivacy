import 'dart:async';
import 'package:easyprivacy_core_sdk/easyprivacy_core_sdk.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../identity/device_identity.dart';
import '../session/core_controller.dart';
import '../storage/profile_store.dart';
import '../network/private_network.dart';

/// Runs in Core's own process/engine. It never exports enrollment material.
class CoreBrokerRuntime {
  CoreBrokerRuntime({
    CoreController? session,
    ProfileStore? store,
    FlutterSecureStorage? storage,
  }) : session = session ?? CoreController(),
       store = store ?? SecureProfileStore(),
       storage = storage ?? const FlutterSecureStorage() {
    privateNetwork = CorePrivateNetwork(this.session, this.storage);
    _monitor = Timer.periodic(
      const Duration(seconds: 10),
      (_) => unawaited(_maintain()),
    );
  }
  final CoreController session;
  final ProfileStore store;
  final FlutterSecureStorage storage;
  String? _loadedIdentity;
  bool _forgotten = false;
  Future<bool>? _connecting;
  late final CorePrivateNetwork privateNetwork;
  Timer? _monitor;
  bool _maintaining = false;

  Future<void> _maintain() async {
    if (_maintaining || !privateNetwork.configured) return;
    _maintaining = true;
    try {
      await _ensureConnected();
      final allowed =
          await storage.read(key: 'easyprivacy.broker.allow_files') == 'true';
      await privateNetwork.maintain(allowed);
    } catch (_) {
      await privateNetwork.stop(remote: false);
    } finally {
      _maintaining = false;
    }
  }

  Future<bool> _connect() async {
    final profile = await store.read();
    if (profile == null || !profile.isPaired) {
      _forgotten = true;
      if (privateNetwork.configured) await privateNetwork.stop(remote: false);
      if (session.hasSession) await session.disconnect();
      _loadedIdentity = null;
      return false;
    }
    _forgotten = false;
    final scope =
        '${profile.fingerprint}:${profile.deviceId!}:${profile.address}';
    if (_loadedIdentity != scope) {
      if (privateNetwork.configured) await privateNetwork.stop();
      await session.disconnect();
      _loadedIdentity = scope;
    }
    if (session.isDeviceConnection &&
        session.phase == ConnectionPhase.connected) {
      return true;
    }
    if (session.authorizationLost) return false;
    if (session.hasSession) {
      await session.refresh();
      return session.phase == ConnectionPhase.connected;
    }
    final identity = await DeviceIdentity.fromSeed(profile.deviceSeed!);
    if (identity.id != profile.deviceId) {
      throw const FormatException(
        'Saved enrollment is inconsistent. Pair this device again.',
      );
    }
    return session.connectDevice(
      profile.address,
      profile.fingerprint,
      identity,
    );
  }

  Future<bool> _ensureConnected() async {
    if (_connecting != null) return _connecting!;
    final pending = _connect();
    _connecting = pending;
    try {
      return await pending;
    } finally {
      _connecting = null;
    }
  }

  Future<Map<String, dynamic>> handle(
    String capability,
    String method,
    Map<String, dynamic> arguments,
  ) async {
    if (!{'core', 'vpn', 'files'}.contains(capability)) {
      throw const BrokerException(
        'not_authorized',
        'This application cannot use Core.',
      );
    }
    final allowedMethods = capability == 'core'
        ? {
            'getSummary',
            'privateStatus',
            'privateStart',
            'privateStop',
            'privateProbe',
            'refreshGrants',
          }
        : capability == 'vpn'
        ? {
            'getSummary',
            'vpnExits',
            'vpnRegister',
            'vpnDisconnect',
            'vpnStatus',
          }
        : {
            'getSummary',
            'privateStatus',
            'listServices',
            'openStream',
            'registerReceiver',
            'acceptReceiver',
            'closeReceiver',
          };
    if (!allowedMethods.contains(method)) {
      throw const BrokerException(
        'not_authorized',
        'This capability cannot perform that operation.',
      );
    }
    final granted =
        capability == 'core' ||
        await storage.read(key: 'easyprivacy.broker.allow_$capability') ==
            'true';
    if (method != 'getSummary' && !granted) {
      throw BrokerException(
        'grant_required',
        'Enable $capability access in EasyPrivacy Core.',
      );
    }
    if (method == 'privateStatus') return privateNetwork.status;
    if (method == 'refreshGrants') {
      if (await storage.read(key: 'easyprivacy.broker.allow_files') != 'true') {
        await privateNetwork.revokeFiles();
      }
      return {'updated': true};
    }
    if (method == 'privateStop') {
      await privateNetwork.stop();
      return privateNetwork.status;
    }
    if (method == 'privateProbe') return privateNetwork.probe();
    final bool connected;
    try {
      connected = await _ensureConnected();
    } catch (_) {
      if (method == 'privateStart') await privateNetwork.stop(remote: false);
      rethrow;
    }
    if (method == 'getSummary') {
      return {
        'protocol': 1,
        'has_session': connected && granted,
        'authorization_lost':
            session.authorizationLost || !granted || _forgotten,
        if (granted && connected) 'device_id': session.deviceId,
        if (granted && connected) 'fingerprint': session.fingerprint,
        if (granted && connected) 'core_name': session.coreStatus?.name,
        if (capability != 'vpn') 'private_connection': privateNetwork.status,
        'message': !granted
            ? 'Enable $capability access in Core.'
            : !connected
            ? (session.error ?? 'Pair this device in EasyPrivacy Core first.')
            : null,
      };
    }
    if (!connected) {
      if (method == 'privateStart') await privateNetwork.stop(remote: false);
      throw BrokerException(
        session.authorizationLost ? 'revoked' : 'core_unavailable',
        session.error ?? 'Connect this device in EasyPrivacy Core first.',
      );
    }
    switch (method) {
      case 'privateStart':
        unawaited(
          privateNetwork.start().then<void>((_) {}, onError: (Object _) {}),
        );
        return privateNetwork.status;
      case 'openStream':
        if (arguments.length != 1 || arguments['service_id'] is! String) {
          throw const BrokerException(
            'invalid_request',
            'Choose an authorized service.',
          );
        }
        return privateNetwork.open(arguments['service_id'] as String);
      case 'registerReceiver':
        if (arguments.isNotEmpty) {
          throw const BrokerException(
            'invalid_request',
            'Receiver parameters are assigned by Core.',
          );
        }
        return privateNetwork.registerReceiver();
      case 'acceptReceiver':
      case 'closeReceiver':
        if (arguments.length != 1 || arguments['receiver_id'] is! String) {
          throw const BrokerException('invalid_request', 'Invalid receiver.');
        }
        if (method == 'acceptReceiver') {
          return privateNetwork.acceptReceiver(
            arguments['receiver_id'] as String,
          );
        }
        await privateNetwork.closeReceiver(arguments['receiver_id'] as String);
        return {'closed': true};
      case 'vpnExits':
        final exits = await session.vpnExits();
        return {
          'exits': exits
              .map(
                (e) => {
                  'id': e.id,
                  'name': e.name,
                  'ready': e.ready,
                  'message': e.message,
                },
              )
              .toList(),
        };
      case 'vpnRegister':
        if (arguments.keys.any((k) => !{'exit_id', 'public_key'}.contains(k)) ||
            arguments['exit_id'] is! String ||
            arguments['public_key'] is! String) {
          throw const BrokerException(
            'invalid_request',
            'Invalid VPN provisioning request.',
          );
        }
        final profile = await session.vpnRegister(
          arguments['exit_id'] as String,
          arguments['public_key'] as String,
        );
        return {
          'exit_id': profile.exitId,
          'exit_name': profile.exitName,
          'public_key': profile.publicKey,
          'endpoint': profile.endpoint,
          'address': profile.address,
          'address_v6': profile.addressV6,
          'dns': profile.dns,
          'mtu': profile.mtu,
          'keepalive': profile.keepalive,
          'management_routes': profile.managementRoutes,
          'allowed_ips': ['0.0.0.0/0', '::/0'],
        };
      case 'vpnDisconnect':
        await session.vpnDisconnect();
        return {'disconnected': true};
      case 'vpnStatus':
        final status = await session.vpnStatus();
        return {
          'installed': status.installed,
          'active': status.active,
          'last_handshake': status.handshake,
          'received': status.received,
          'sent': status.sent,
        };
      case 'listServices':
        if (!privateNetwork.active) {
          return {'services': <Map<String, Object>>[]};
        }
        return {
          'services': (await privateNetwork.services())
              .map((s) => s.toJson())
              .toList(),
        };
      default:
        throw const BrokerException(
          'unsupported',
          'Update this application and Core together.',
        );
    }
  }

  Future<void> shutdown() async {
    _monitor?.cancel();
    await privateNetwork.stop(remote: false);
    session.dispose();
  }

  void dispose() {
    unawaited(shutdown());
  }
}
