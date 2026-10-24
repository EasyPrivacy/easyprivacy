import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:easyprivacy_protocol/easyprivacy_protocol.dart';
import 'vpn_keys.dart';

abstract interface class TunnelBackend {
  Future<TunnelStatus> status();
  Future<void> install();
  Future<void> connect(VPNProfile profile, VPNKey key);
  Future<void> disconnect();
}

class NativeTunnelBackend implements TunnelBackend {
  static const _channel = MethodChannel('org.easyprivacy/vpn');
  String get _helper =>
      '${File(Platform.resolvedExecutable).parent.path}/easyprivacy-vpn.exe';
  Future<Map<String, dynamic>> _action(
    String action, [
    Map<String, Object>? config,
  ]) async {
    if (Platform.isAndroid) {
      try {
        return Map<String, dynamic>.from(
          await _channel.invokeMethod<Map<Object?, Object?>>(action, config) ??
              {},
        );
      } on PlatformException catch (e) {
        throw CoreException(
          e.message ?? 'Android could not complete the VPN action.',
        );
      }
    }
    if (!Platform.isWindows) {
      if (action == 'status') {
        return {'installed': false, 'active': false};
      }
      throw const CoreException(
        'VPN connections are supported on Windows and Android.',
      );
    }
    if (!File(_helper).existsSync()) {
      if (action == 'status') {
        return {'installed': false, 'active': false};
      }
      throw const CoreException(
        'Extract the complete updated Windows ZIP before connecting the VPN.',
      );
    }
    final process = await Process.start(_helper, [
      '--$action',
    ], runInShell: false);
    final stdoutResult = _bounded(process.stdout),
        stderrResult = _bounded(process.stderr);
    if (config != null) {
      process.stdin.write(jsonEncode(config));
    }
    await process.stdin.close();
    try {
      final code = await process.exitCode.timeout(
        Duration(seconds: action == 'install' ? 200 : 35),
      );
      final out = await stdoutResult;
      await stderrResult;
      final result = jsonDecode(out) as Map<String, dynamic>;
      if (code != 0) {
        throw CoreException(
          result['error'] as String? ??
              'Windows could not complete the VPN action.',
        );
      }
      return result;
    } on TimeoutException {
      process.kill();
      throw const CoreException(
        'The VPN action timed out. Check the EasyPrivacy VPN service.',
      );
    }
  }

  Future<String> _bounded(Stream<List<int>> stream) async {
    final bytes = <int>[];
    await for (final chunk in stream) {
      if (bytes.length + chunk.length > 16384) {
        throw const CoreException('Invalid VPN helper output.');
      }
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
  }

  @override
  Future<TunnelStatus> status() async =>
      TunnelStatus.fromJson(await _action('status'));
  @override
  Future<void> install() async {
    await _action('install');
  }

  @override
  Future<void> connect(VPNProfile profile, VPNKey key) async {
    await _action('connect', profile.nativeConfig(key));
  }

  @override
  Future<void> disconnect() async {
    await _action('disconnect');
  }
}
