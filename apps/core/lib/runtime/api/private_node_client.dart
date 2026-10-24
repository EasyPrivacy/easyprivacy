import 'package:easyprivacy_protocol/easyprivacy_protocol.dart';

abstract interface class PrivateNodeClient {
  Future<PrivateNetworkProfile> privateRegister(String token, String publicKey);
  Future<void> privateDisconnect(String token);
  Future<List<PrivateServiceTarget>> privateServices(String token);
  Future<PrivateServiceTarget> privateReceiver(String token);
  Future<void> privateReceiverDisconnect(String token);
}
