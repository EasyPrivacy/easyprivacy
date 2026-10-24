import 'package:flutter/foundation.dart';
import 'package:easyprivacy_protocol/easyprivacy_protocol.dart';

enum ConnectionPhase { disconnected, connecting, connected, unreachable }

/// Public capability interface. No enrollment signing or owner token is exposed.
abstract class CoreConnection extends ChangeNotifier {
  bool get hasSession;
  bool get isDeviceConnection;
  bool get authorizationLost;
  String? get fingerprint;
  String? get deviceId;
  ConnectionPhase get phase;
  Future<List<VPNExit>> vpnExits();
  Future<VPNProfile> vpnRegister(String exit, String publicKey);
  Future<void> vpnDisconnect();
  Future<TunnelStatus> vpnStatus();
}
