import 'package:easyprivacy_protocol/easyprivacy_protocol.dart';

abstract interface class VPNNodeClient {
  Future<List<VPNExit>> vpnExits(String token);
  Future<VPNProfile> vpnRegister(String token, String exit, String publicKey);
  Future<void> vpnDisconnect(String token);
  Future<TunnelStatus> vpnStatus(String token);
}
