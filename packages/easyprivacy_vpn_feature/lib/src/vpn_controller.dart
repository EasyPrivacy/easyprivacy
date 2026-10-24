import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:easyprivacy_protocol/easyprivacy_protocol.dart';
import 'package:easyprivacy_core_sdk/easyprivacy_core_sdk.dart';
import 'vpn_keys.dart';
import 'vpn_backend.dart';

abstract interface class VPNKeyStore {
  Future<VPNKey> key(String scope);
  Future<void> delete(String scope);
  Future<String?> selection();
  Future<void> select(String id);
}

class SecureVPNKeyStore implements VPNKeyStore {
  final _storage = const FlutterSecureStorage();
  @override
  Future<String?> selection() =>
      _storage.read(key: 'easyprivacy.vpn.active-exit');
  @override
  Future<void> select(String id) =>
      _storage.write(key: 'easyprivacy.vpn.active-exit', value: id);
  Future<void> _tail = Future.value();
  Future<T> _exclusive<T>(Future<T> Function() action) async {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    await previous;
    try {
      return await action();
    } finally {
      done.complete();
    }
  }

  String _label(String scope) =>
      'easyprivacy.vpn.${sha256.convert(utf8.encode(scope))}';
  @override
  Future<VPNKey> key(String scope) => _exclusive(() async {
    final label = _label(scope);
    final saved = await _storage.read(key: label);
    if (saved != null) {
      return VPNKey.fromPrivate(saved);
    }
    final key = await VPNKey.create();
    await _storage.write(key: label, value: key.privateKey);
    return key;
  });
  @override
  Future<void> delete(String scope) =>
      _exclusive(() => _storage.delete(key: _label(scope)));
}

enum VPNPhase {
  idle,
  installing,
  provisioning,
  connecting,
  connected,
  disconnecting,
}

class VPNController extends ChangeNotifier {
  VPNController(
    this.core, {
    TunnelBackend? backend,
    VPNKeyStore? keys,
    this.pollInterval = const Duration(seconds: 3),
  }) : backend = backend ?? NativeTunnelBackend(),
       keys = keys ?? SecureVPNKeyStore() {
    core.addListener(_coreChanged);
    unawaited(restoreStatus());
  }
  final CoreConnection core;
  final TunnelBackend backend;
  final VPNKeyStore keys;
  final Duration pollInterval;
  List<VPNExit> exits = [];
  String? selectedExit, error;
  VPNPhase phase = VPNPhase.idle;
  TunnelStatus status = const TunnelStatus();
  Timer? _timer;
  bool _disposed = false, _polling = false, _busy = false, _loading = false;
  String? _scope;
  int _generation = 0;
  DateTime _lastExitCheck = DateTime.fromMillisecondsSinceEpoch(0);
  bool get busy => _busy;
  bool get active =>
      status.active ||
      phase == VPNPhase.connecting ||
      phase == VPNPhase.connected;
  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  Future<void> restoreStatus() async {
    final generation = _generation;
    try {
      final fresh = await backend.status();
      if (_disposed || _busy || phase != VPNPhase.idle) {
        return;
      }
      status = fresh;
      if (fresh.active) {
        try {
          selectedExit = await keys.selection();
        } catch (_) {
          /* Keep Disconnect usable if storage is unavailable. */
        }
        if (_disposed || _busy || generation != _generation) {
          return;
        }
        if (exits.isNotEmpty) {
          _setExits(exits);
        }
        phase = fresh.hasRecentHandshake
            ? VPNPhase.connected
            : VPNPhase.connecting;
        _startPolling();
      }
      _notify();
    } catch (_) {
      /* Management login stays usable if the local helper is unavailable. */
    }
  }

  String _message(Object e) => e is CoreException
      ? e.message
      : e is FormatException
      ? e.message
      : 'Could not complete the VPN action. Check your core and try again.';
  void _coreChanged() {
    if (_disposed) {
      return;
    }
    if (!core.hasSession) {
      if (_scope != null) {
        _scope = null;
      }
      // A management outage must not silently restore ordinary networking.
      // Explicit account/device rejection is different from a network timeout.
      if (core.authorizationLost) {
        unawaited(disconnect(removePeer: false));
      }
      return;
    }
    final scope = '${core.fingerprint}:${core.deviceId}';
    if (core.isDeviceConnection &&
        core.phase == ConnectionPhase.connected &&
        _scope != scope) {
      _scope = scope;
      unawaited(load());
    }
  }

  Future<void> load() async {
    if (_loading) {
      return;
    }
    _loading = true;
    try {
      final discovered = await core.vpnExits();
      if (selectedExit == null) {
        try {
          selectedExit = await keys.selection();
        } catch (_) {
          // Exit discovery and Disconnect remain usable during storage failures.
        }
      }
      error = null;
      status = await backend.status();
      _setExits(discovered);
      if (status.active) {
        phase = status.hasRecentHandshake
            ? VPNPhase.connected
            : VPNPhase.connecting;
        _startPolling();
      }
    } catch (e) {
      error = _message(e);
    } finally {
      _loading = false;
      _notify();
    }
  }

  void _setExits(List<VPNExit> discovered) {
    exits = List.of(discovered);
    if (active &&
        selectedExit != null &&
        !exits.any((e) => e.id == selectedExit)) {
      exits.add(
        VPNExit(
          selectedExit!,
          'Unavailable exit',
          false,
          'The selected exit is unavailable. Traffic remains stopped; disconnect to choose another exit.',
        ),
      );
    }
    selectedExit = exits.any((e) => e.id == selectedExit)
        ? selectedExit
        : exits.firstOrNull?.id;
  }

  void select(String id) {
    if (!_busy && !active) {
      selectedExit = id;
      error = null;
      _notify();
    }
  }

  Future<void> connect() async {
    if (_busy || active) {
      return;
    }
    final exit = exits.where((e) => e.id == selectedExit).firstOrNull;
    if (exit == null || !exit.ready) {
      error = exit?.message ?? 'Configure the VPN exit on your core first.';
      _notify();
      return;
    }
    final generation = ++_generation;
    _busy = true;
    error = null;
    phase = VPNPhase.provisioning;
    _notify();
    var registered = false;
    bool current() => !_disposed && generation == _generation;
    try {
      status = await backend.status();
      if (!current()) {
        return;
      }
      if (status.active) {
        phase = status.hasRecentHandshake
            ? VPNPhase.connected
            : VPNPhase.connecting;
        _startPolling();
        return;
      }
      if (!status.installed) {
        phase = VPNPhase.installing;
        _notify();
        await backend.install();
        if (!current()) {
          return;
        }
      }
      phase = VPNPhase.provisioning;
      _notify();
      final key = await keys.key(
        '${core.fingerprint}:${core.deviceId}:${exit.id}',
      );
      if (!current()) {
        return;
      }
      final profile = await core.vpnRegister(exit.id, key.publicKey);
      registered = true;
      if (!current()) {
        return;
      }
      if (profile.exitId != exit.id) {
        throw const CoreException('The core returned a different VPN exit.');
      }
      await keys.select(exit.id);
      if (!current()) {
        return;
      }
      phase = VPNPhase.connecting;
      _notify();
      await backend.connect(profile, key);
      if (!current()) {
        await backend.disconnect();
        return;
      }
      status = await backend.status();
      phase = status.hasRecentHandshake
          ? VPNPhase.connected
          : VPNPhase.connecting;
      _startPolling();
    } catch (e) {
      if (current()) {
        error = _message(e);
        phase = VPNPhase.idle;
        try {
          await backend.disconnect();
        } catch (_) {}
        status = const TunnelStatus();
      }
    } finally {
      if (registered && (!current() || phase == VPNPhase.idle)) {
        try {
          await core.vpnDisconnect();
        } catch (_) {}
      }
      _busy = false;
      _notify();
    }
  }

  void _startPolling() {
    _timer?.cancel();
    _timer = Timer.periodic(pollInterval, (_) => unawaited(refresh()));
  }

  Future<void> refresh() async {
    if (_polling || _disposed || _busy) {
      return;
    }
    _polling = true;
    final generation = _generation;
    try {
      final fresh = await backend.status();
      if (_disposed || generation != _generation) {
        return;
      }
      status = fresh;
      if (!fresh.active) {
        phase = VPNPhase.idle;
        _timer?.cancel();
      } else {
        phase = fresh.hasRecentHandshake
            ? VPNPhase.connected
            : VPNPhase.connecting;
      }
      if (fresh.active &&
          selectedExit == 'home' &&
          core.hasSession &&
          DateTime.now().difference(_lastExitCheck) >=
              const Duration(seconds: 15)) {
        _lastExitCheck = DateTime.now();
        final discovered = await core.vpnExits();
        if (!_disposed && generation == _generation) {
          _setExits(discovered);
        }
      }
    } catch (e) {
      if (!_disposed && generation == _generation) {
        error = _message(e);
      }
    } finally {
      _polling = false;
      _notify();
    }
  }

  Future<bool> disconnect({bool removePeer = true}) async {
    ++_generation;
    _timer?.cancel();
    if (!active && !_busy) {
      try {
        status = await backend.status();
        if (!status.active) {
          return true;
        }
      } catch (e) {
        error = _message(e);
        _notify();
        return false;
      }
    }
    phase = VPNPhase.disconnecting;
    _notify();
    try {
      await backend.disconnect();
      status = const TunnelStatus();
      phase = VPNPhase.idle;
      error = null;
      if (removePeer && core.isDeviceConnection) {
        try {
          await core.vpnDisconnect();
        } catch (_) {
          /* Local tunnel is down even if server is unreachable. */
        }
      }
      return true;
    } catch (e) {
      error = _message(e);
      return false;
    } finally {
      _notify();
    }
  }

  Future<void> forgetKeys(String fingerprint, String deviceId) async {
    for (final id in {'vps', 'home', ...exits.map((e) => e.id)}) {
      await keys.delete('$fingerprint:$deviceId:$id');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _timer?.cancel();
    core.removeListener(_coreChanged);
    super.dispose();
  }
}
