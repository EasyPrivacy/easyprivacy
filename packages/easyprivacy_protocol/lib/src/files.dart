import 'dart:convert';

/// A narrowly scoped, short-lived delegation signed by an enrolled Core device.
/// These exact bytes are shared by Core (issuer) and Files (verifier).
String filesHandshakeClaim({
  required String core,
  required String device,
  required String peer,
  required String key,
  required String nonce,
  required String role,
  required int expires,
}) {
  if (!RegExp(r'^SHA256:[0-9A-Fa-f]{64}$').hasMatch(core) ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(device) ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(peer) ||
      device == peer ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(nonce) ||
      !{'sender', 'receiver'}.contains(role) ||
      base64Decode(key).length != 32 ||
      base64Encode(base64Decode(key)) != key ||
      base64Decode(key).every((b) => b == 0) ||
      expires < 1) {
    throw const FormatException('Invalid Files handshake.');
  }
  return 'EasyPrivacy Files handshake v1\n$core\n$device\n$peer\n$key\n$nonce\n$role\n$expires';
}
