import 'dart:async';
import 'package:flutter/foundation.dart';
import 'core_client.dart';
import 'device_identity.dart';
import 'vpn_types.dart';

enum ConnectionPhase { disconnected, connecting, connected, unreachable }

class CoreController extends ChangeNotifier {
  CoreController({
    this.clientFactory = _defaultClient,
    this.pollInterval = const Duration(seconds: 10),
  });
  static NodeClient _defaultClient(CoreAddress address, String fingerprint) =>
      CoreClient(address, fingerprint);
  final NodeClient Function(CoreAddress, String) clientFactory;
  final Duration pollInterval;
  ConnectionPhase phase = ConnectionPhase.disconnected;
  CoreStatus? coreStatus;
  DateTime? lastChecked;
  String? error;
  String? address;
  String? fingerprint;
  bool authorizationLost = false;
  String? _token;
  NodeClient? _client;
  DeviceIdentity? _identity;
  Timer? _timer;
  int _generation = 0;
  bool _disposed = false;
  bool _refreshing = false;
  bool get hasSession => _token != null;
  bool get isDeviceConnection => hasSession && _identity != null;
  String? get deviceId => _identity?.id;

  Future<bool> connectDevice(
    String rawAddress,
    String fingerprint,
    DeviceIdentity identity,
  ) => connect(rawAddress, fingerprint, '', '', identity: identity);

  Future<bool> connect(
    String rawAddress,
    String fingerprint,
    String username,
    String password, {
    DeviceIdentity? identity,
  }) async {
    if (phase == ConnectionPhase.connecting) return false;
    final generation = ++_generation;
    _timer?.cancel();
    _token = null;
    coreStatus = null;
    lastChecked = null;
    phase = ConnectionPhase.connecting;
    authorizationLost = false;
    error = null;
    notifyListeners();
    try {
      final parsed = CoreAddress.parse(rawAddress);
      final client = clientFactory(parsed, normalizeFingerprint(fingerprint));
      final token = identity == null
          ? await client.signIn(username, password)
          : await (client as DeviceNodeClient).signInDevice(identity);
      CoreStatus status;
      try {
        status = await client.status(token);
      } catch (_) {
        unawaited(client.signOut(token).catchError((_) {}));
        rethrow;
      }
      if (_disposed || generation != _generation) {
        unawaited(client.signOut(token).catchError((_) {}));
        return false;
      }
      _client = client;
      _identity = identity;
      _token = token;
      address = parsed.label;
      this.fingerprint = normalizeFingerprint(fingerprint);
      coreStatus = status;
      lastChecked = DateTime.now();
      phase = ConnectionPhase.connected;
      _timer = Timer.periodic(pollInterval, (_) => unawaited(refresh()));
      notifyListeners();
      return true;
    } catch (exception) {
      if (_disposed || generation != _generation) return false;
      error = _message(exception);
      authorizationLost =
          identity != null &&
          exception is CoreException &&
          (exception.statusCode == 401 || exception.statusCode == 403);
      phase = ConnectionPhase.disconnected;
      notifyListeners();
      return false;
    }
  }

  Future<void> refresh() async {
    final client = _client, token = _token;
    if (_refreshing || client == null || token == null) return;
    _refreshing = true;
    final generation = _generation;
    try {
      final status = await client.status(token);
      if (_disposed || generation != _generation) return;
      coreStatus = status;
      lastChecked = DateTime.now();
      phase = ConnectionPhase.connected;
      error = null;
    } catch (exception) {
      if (_disposed || generation != _generation) return;
      error = _message(exception);
      phase = ConnectionPhase.unreachable;
      if (exception is CoreException && exception.statusCode == 401) {
        final identity = _identity;
        if (identity != null && client is DeviceNodeClient) {
          String? freshToken;
          try {
            freshToken = await client.signInDevice(identity);
            final status = await client.status(freshToken);
            if (_disposed || generation != _generation) {
              unawaited(client.signOut(freshToken).catchError((_) {}));
              return;
            }
            _token = freshToken;
            coreStatus = status;
            lastChecked = DateTime.now();
            phase = ConnectionPhase.connected;
            error = null;
          } catch (renewError) {
            if (freshToken != null) {
              unawaited(client.signOut(freshToken).catchError((_) {}));
            }
            if (_disposed || generation != _generation) return;
            error = _message(renewError);
            authorizationLost =
                renewError is CoreException &&
                (renewError.statusCode == 401 || renewError.statusCode == 403);
            _token = null;
            _timer?.cancel();
            phase = ConnectionPhase.disconnected;
          }
        } else {
          _token = null;
          _timer?.cancel();
          phase = ConnectionPhase.disconnected;
        }
      }
    } finally {
      _refreshing = false;
      if (!_disposed && generation == _generation) notifyListeners();
    }
  }

  Future<void> disconnect({bool authorizationLost = false}) async {
    ++_generation;
    _timer?.cancel();
    final client = _client, token = _token;
    _token = null;
    _client = null;
    _identity = null;
    coreStatus = null;
    lastChecked = null;
    phase = ConnectionPhase.disconnected;
    error = null;
    this.authorizationLost = authorizationLost;
    notifyListeners();
    if (client != null && token != null) {
      try {
        await client.signOut(token);
      } catch (_) {
        // Local access is discarded even if the server is unavailable. The
        // server-side token also expires after its fixed one-hour lifetime.
      }
    }
  }

  (DeviceNodeClient, String) _deviceSession() {
    final client = _client, token = _token;
    if (!isDeviceConnection ||
        client is! DeviceNodeClient ||
        token == null ||
        phase != ConnectionPhase.connected) {
      throw const CoreException('Connect with a paired device first.');
    }
    return (client, token);
  }

  Future<PairingCode> createPairingCode() {
    final (client, token) = _deviceSession();
    return client.createPairingCode(token);
  }

  Future<List<PairedDevice>> devices() {
    final (client, token) = _deviceSession();
    return client.devices(token);
  }

  (VPNNodeClient, String) _vpnSession() {
    final (client, token) = _deviceSession();
    if (client is! VPNNodeClient) {
      throw const CoreException('Update the core to enable VPN connections.');
    }
    return (client as VPNNodeClient, token);
  }

  Future<List<VPNExit>> vpnExits() {
    final (c, t) = _vpnSession();
    return c.vpnExits(t);
  }

  Future<VPNProfile> vpnRegister(String exit, String publicKey) {
    final (c, t) = _vpnSession();
    return c.vpnRegister(t, exit, publicKey);
  }

  Future<void> vpnDisconnect() {
    final (c, t) = _vpnSession();
    return c.vpnDisconnect(t);
  }

  Future<TunnelStatus> vpnStatus() {
    final (c, t) = _vpnSession();
    return c.vpnStatus(t);
  }

  Future<void> revokeDevice(String id) async {
    final (client, token) = _deviceSession();
    await client.revokeDevice(token, id);
    if (id == deviceId) await disconnect(authorizationLost: true);
  }

  String _message(Object exception) => switch (exception) {
    CoreException() => exception.message,
    FormatException() => exception.message,
    _ =>
      'Could not complete the connection. Check your core settings and try again.',
  };

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _timer?.cancel();
    final client = _client, token = _token;
    if (client != null && token != null) {
      unawaited(client.signOut(token).catchError((_) {}));
    }
    super.dispose();
  }
}
