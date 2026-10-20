import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class CoreProfile {
  const CoreProfile({
    required this.address,
    required this.username,
    required this.fingerprint,
    this.deviceSeed,
    this.deviceId,
  });
  final String address;
  final String username;
  final String fingerprint;
  final String? deviceSeed;
  final String? deviceId;
  bool get isPaired => deviceSeed != null && deviceId != null;
}

abstract interface class ProfileStore {
  Future<CoreProfile?> read();
  Future<void> save(CoreProfile profile);
  Future<void> delete();
}

class SecureProfileStore implements ProfileStore {
  final _storage = const FlutterSecureStorage();
  static const _key = 'easyprivacy.revamp.core';
  @override
  Future<CoreProfile?> read() async {
    final text = await _storage.read(key: _key);
    if (text == null) return null;
    final value = jsonDecode(text) as Map<String, dynamic>;
    if ((value['device_seed'] == null) != (value['device_id'] == null)) {
      throw const FormatException('Incomplete saved device identity.');
    }
    return CoreProfile(
      address: value['address'] as String,
      username: value['username'] as String,
      fingerprint: value['fingerprint'] as String,
      deviceSeed: value['device_seed'] as String?,
      deviceId: value['device_id'] as String?,
    );
  }

  @override
  Future<void> save(CoreProfile profile) => _storage.write(
    key: _key,
    value: jsonEncode({
      'address': profile.address,
      'username': profile.username,
      'fingerprint': profile.fingerprint,
      'device_seed': profile.deviceSeed,
      'device_id': profile.deviceId,
    }),
  );
  @override
  Future<void> delete() => _storage.delete(key: _key);
}
