import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'vpn_controller.dart';

abstract interface class VPNPresenceBackend {
  void listen(Future<void> Function(String) action);
  Future<String?> pendingAction();
  Future<bool> update(Map<String, Object> state);
  Future<bool> requestPermission();
  Future<void> openSettings();
  void dispose();
}

class NativeVPNPresenceBackend implements VPNPresenceBackend {
  static const channel = MethodChannel('org.easyprivacy/presence');
  @override
  void listen(Future<void> Function(String) action) {
    channel.setMethodCallHandler((call) => action(call.method));
  }

  @override
  Future<String?> pendingAction() =>
      channel.invokeMethod<String>('pendingAction');
  @override
  Future<bool> update(Map<String, Object> state) async =>
      await channel.invokeMethod<bool>('update', state) ?? true;
  @override
  Future<bool> requestPermission() async =>
      await channel.invokeMethod<bool>('requestPermission') ?? true;
  @override
  Future<void> openSettings() => channel.invokeMethod<void>('openSettings');
  @override
  void dispose() => channel.setMethodCallHandler(null);
}

abstract interface class VPNPresencePreferences {
  Future<bool> read();
  Future<void> write(bool value);
}

class SecureVPNPresencePreferences implements VPNPresencePreferences {
  static const _key = 'easyprivacy.vpn.always-show-notification';
  final _storage = const FlutterSecureStorage();
  @override
  Future<bool> read() async => await _storage.read(key: _key) == 'true';
  @override
  Future<void> write(bool value) => _storage.write(key: _key, value: '$value');
}

/// Keeps the notification/tray attached to the tunnel, not management login.
class VPNPresenceController extends ChangeNotifier with WidgetsBindingObserver {
  VPNPresenceController(
    this.vpn, {
    VPNPresenceBackend? backend,
    VPNPresencePreferences? preferences,
  }) : backend = backend ?? NativeVPNPresenceBackend(),
       preferences = preferences ?? SecureVPNPresencePreferences() {
    this.backend.listen(handleAction);
    vpn.addListener(_changed);
    vpn.core.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initialize());
  }

  final VPNController vpn;
  final VPNPresenceBackend backend;
  final VPNPresencePreferences preferences;
  bool alwaysShow = false, ready = false, saving = false;
  bool notificationsEnabled = true;
  String? error;
  bool _disposed = false, _updating = false, _dirty = false;
  bool _pendingConnect = false, _acting = false;

  bool get canConnect =>
      vpn.core.isDeviceConnection &&
      vpn.core.hasSession &&
      !vpn.busy &&
      !vpn.active &&
      vpn.exits.any((exit) => exit.id == vpn.selectedExit && exit.ready);

  Map<String, Object> get state => {
    'visible':
        alwaysShow ||
        vpn.active ||
        vpn.busy ||
        vpn.phase == VPNPhase.disconnecting,
    'alwaysShow': alwaysShow,
    'status': vpn.error != null && !vpn.busy
        ? (vpn.active
              ? 'VPN needs attention — open EasyPrivacy'
              : 'VPN disconnected — open EasyPrivacy')
        : switch (vpn.phase) {
            VPNPhase.idle => 'VPN disconnected',
            VPNPhase.installing => 'Setting up VPN',
            VPNPhase.provisioning => 'Preparing VPN',
            VPNPhase.connecting => 'Waiting for VPN server',
            VPNPhase.connected => 'VPN connected',
            VPNPhase.disconnecting => 'Disconnecting VPN',
          },
    'action': vpn.active ? 'disconnect' : 'connect',
    'actionEnabled':
        !vpn.busy &&
        vpn.phase != VPNPhase.disconnecting &&
        (vpn.active || canConnect),
  };

  Future<void> _initialize() async {
    try {
      alwaysShow = await preferences.read();
    } catch (_) {
      // Default to connected-only when settings storage is unavailable.
    }
    if (_disposed) return;
    ready = true;
    try {
      if (await backend.pendingAction() == 'connect') _pendingConnect = true;
    } on MissingPluginException {
      // Widget tests do not host the native runners.
    } on PlatformException {
      error =
          'Could not read the notification action. Open the app to connect.';
    }
    _changed();
  }

  void _changed() {
    if (_disposed || !ready) return;
    notifyListeners();
    unawaited(_publish());
    if (_pendingConnect && canConnect && !_acting) {
      _pendingConnect = false;
      unawaited(handleAction('connect'));
    }
  }

  Future<void> _publish() async {
    _dirty = true;
    if (_updating || _disposed) return;
    _updating = true;
    try {
      while (_dirty && !_disposed) {
        _dirty = false;
        try {
          final enabled = await backend.update(state);
          if (!_disposed && notificationsEnabled != enabled) {
            notificationsEnabled = enabled;
            notifyListeners();
          }
        } on MissingPluginException {
          // Tests and unsupported platforms have no indicator channel.
        } on PlatformException {
          if (!_disposed) {
            error = 'Could not update the VPN indicator. Use the app controls.';
            notifyListeners();
          }
        }
      }
    } finally {
      _updating = false;
    }
  }

  Future<void> setAlwaysShow(bool value) async {
    if (saving || !ready) return;
    saving = true;
    error = null;
    notifyListeners();
    try {
      if (value) notificationsEnabled = await backend.requestPermission();
      await preferences.write(value);
      if (!_disposed) alwaysShow = value;
    } catch (_) {
      error = 'Could not save the notification setting. Try again.';
    } finally {
      saving = false;
      _changed();
    }
  }

  Future<void> handleAction(String action) async {
    if (_disposed || _acting) return;
    if (action == 'connect' && !canConnect) {
      // A notification may launch a cold app before pairing is restored.
      _pendingConnect = !vpn.active;
      return;
    }
    if (action != 'connect' && action != 'disconnect') return;
    _pendingConnect = false;
    _acting = true;
    try {
      if (action == 'connect') {
        await vpn.connect();
      } else {
        await vpn.disconnect();
      }
    } finally {
      _acting = false;
      _changed();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(vpn.refresh());
      _changed();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    vpn.removeListener(_changed);
    vpn.core.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    backend.dispose();
    super.dispose();
  }
}

class VPNNotificationSettings extends StatelessWidget {
  const VPNNotificationSettings({super.key, required this.controller});
  final VPNPresenceController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: const Key('always-show-vpn'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Always show VPN status'),
          subtitle: Text(
            Platform.isAndroid
                ? 'Keep a notification with Connect available when disconnected.'
                : 'Keep EasyPrivacy in the system tray when disconnected.',
          ),
          value: controller.alwaysShow,
          onChanged: controller.ready && !controller.saving
              ? controller.setAlwaysShow
              : null,
        ),
        const Text(
          'Otherwise, the VPN indicator appears only while the VPN is active.',
        ),
        if (!controller.notificationsEnabled) ...[
          const Text('Notifications are disabled in Android settings.'),
          TextButton(
            onPressed: controller.backend.openSettings,
            child: const Text('Open notification settings'),
          ),
        ],
        if (controller.error != null) Text(controller.error!),
      ],
    ),
  );
}
