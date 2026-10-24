import 'dart:async';
import 'package:easyprivacy_protocol/easyprivacy_protocol.dart';
import 'core_connection.dart';
import 'broker_transport.dart';

class BrokerCoreConnection extends CoreConnection {
  BrokerCoreConnection({
    this.capability = 'vpn',
    BrokerTransport? transport,
    bool autoStart = true,
  }) : transport = transport ?? PlatformBrokerTransport(capability) {
    if (autoStart) {
      unawaited(refresh());
      _timer = Timer.periodic(const Duration(seconds: 5), (_) => refresh());
    }
  }
  final String capability;
  final BrokerTransport transport;
  Timer? _timer;
  bool _disposed = false, _refreshing = false;
  @override
  bool hasSession = false;
  @override
  bool isDeviceConnection = false;
  @override
  bool authorizationLost = false;
  @override
  String? fingerprint;
  @override
  String? deviceId;
  @override
  ConnectionPhase phase = ConnectionPhase.disconnected;
  String? error;
  String? coreName;

  Future<void> refresh() async {
    if (_disposed || _refreshing) return;
    _refreshing = true;
    try {
      final state = await transport.call('getSummary');
      if (_disposed) return;
      if (state['protocol'] != 1) {
        throw const BrokerException(
          'version_mismatch',
          'Update Core and this application together.',
        );
      }
      hasSession = state['has_session'] == true;
      isDeviceConnection = hasSession && state['device_id'] is String;
      authorizationLost = state['authorization_lost'] == true;
      fingerprint = state['fingerprint'] as String?;
      deviceId = state['device_id'] as String?;
      coreName = state['core_name'] as String?;
      phase = hasSession
          ? ConnectionPhase.connected
          : ConnectionPhase.disconnected;
      error = state['message'] as String?;
    } catch (e) {
      if (!_disposed) {
        phase = ConnectionPhase.unreachable;
        error = e.toString();
      }
    } finally {
      _refreshing = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  Future<List<VPNExit>> vpnExits() async {
    final result = await transport.call('vpnExits');
    return (result['exits'] as List)
        .map((v) => VPNExit.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList();
  }

  @override
  Future<VPNProfile> vpnRegister(String exit, String publicKey) async =>
      VPNProfile.fromJson(
        await transport.call('vpnRegister', {
          'exit_id': exit,
          'public_key': publicKey,
        }),
      );
  @override
  Future<void> vpnDisconnect() async {
    await transport.call('vpnDisconnect');
  }

  @override
  Future<TunnelStatus> vpnStatus() async =>
      TunnelStatus.fromJson(await transport.call('vpnStatus'));
  Future<List<PrivateServiceTarget>> services() async {
    final result = await transport.call('listServices');
    return (result['services'] as List)
        .map(
          (v) => PrivateServiceTarget.fromJson(
            Map<String, dynamic>.from(v as Map),
          ),
        )
        .toList();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    transport.close();
    super.dispose();
  }
}
