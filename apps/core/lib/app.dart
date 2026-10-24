import 'dart:async';
import 'features/settings/capability_access.dart';
import 'features/settings/private_connection.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:easyprivacy_core/runtime/session/core_controller.dart';
import 'package:easyprivacy_core/runtime/storage/profile_store.dart';
import 'package:easyprivacy_core/runtime/identity/device_identity.dart';
import 'package:easyprivacy_core/runtime/identity/pairing_client.dart';
import 'package:easyprivacy_core/features/devices/device_dialogs.dart';
import 'package:easyprivacy_vpn_feature/easyprivacy_vpn.dart';
import 'package:easyprivacy_core/features/nodes/service_node.dart';
import 'package:easyprivacy_ui/easyprivacy_ui.dart';

class EasyPrivacyApp extends StatefulWidget {
  const EasyPrivacyApp({
    super.key,
    this.controller,
    this.store,
    this.pairer = pairCore,
    this.enroller = enrollVerifiedCore,
  });
  final CoreController? controller;
  final ProfileStore? store;
  final Future<VerifiedCore> Function(CoreAddress, String, String) pairer;
  final Future<void> Function(VerifiedCore, String, String) enroller;
  @override
  State<EasyPrivacyApp> createState() => _EasyPrivacyAppState();
}

class _EasyPrivacyAppState extends State<EasyPrivacyApp> {
  late final CoreController controller = widget.controller ?? CoreController();
  late final ProfileStore store = widget.store ?? SecureProfileStore();
  late final VPNController vpn;
  VPNPresenceController? vpnPresence;
  final address = TextEditingController();
  final username = TextEditingController();
  final password = TextEditingController();
  final fingerprint = TextEditingController();
  final pairingCode = TextEditingController();
  final deviceName = TextEditingController(
    text: Platform.isAndroid ? 'My Android phone' : 'My desktop',
  );
  final form = GlobalKey<FormState>();
  bool hidePassword = true;
  bool loadingProfile = true;
  String? storageNotice;
  CoreProfile? savedProfile;
  bool showLegacy = false;
  bool pairingBusy = false;
  bool managementBusy = false;
  String? pairingError;
  VerifiedCore? verifiedCore;

  @override
  void initState() {
    super.initState();
    vpn = VPNController(controller);
    if (Platform.isAndroid || Platform.isWindows) {
      vpnPresence = VPNPresenceController(vpn);
    }
    unawaited(_loadProfile());
  }

  Future<void> _loadProfile() async {
    try {
      final saved = await store.read();
      if (!mounted) return;
      if (saved != null) {
        savedProfile = saved;
        showLegacy = !saved.isPaired;
        address.text = saved.address;
        username.text = saved.username;
        fingerprint.text = saved.fingerprint;
      }
    } catch (_) {
      storageNotice =
          'Saved pairing could not be loaded. Check secure storage or pair again with a new code from your core.';
    } finally {
      if (mounted) setState(() => loadingProfile = false);
    }
    if (mounted && savedProfile?.isPaired == true) unawaited(_connectPaired());
  }

  Future<void> _connect() async {
    if (!form.currentState!.validate()) return;
    final profile = CoreProfile(
      address: address.text.trim(),
      username: username.text.trim(),
      fingerprint: normalizeFingerprint(fingerprint.text),
    );
    final secret = password.text;
    password.clear();
    final connected = await controller.connect(
      profile.address,
      profile.fingerprint,
      profile.username,
      secret,
    );
    if (!connected || !mounted) return;
    try {
      await store.save(profile);
      if (mounted) {
        setState(() {
          storageNotice = null;
          savedProfile = profile;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => storageNotice =
              'Connected, but core settings could not be saved on this device.',
        );
      }
    }
  }

  String _errorText(Object error) => switch (error) {
    CoreException() => error.message,
    FormatException() => error.message,
    _ =>
      'Could not complete this action. Check the core connection and try again.',
  };

  Future<void> _pair() async {
    if (!form.currentState!.validate() || pairingBusy) return;
    final code = pairingCode.text;
    pairingCode.clear();
    setState(() {
      pairingBusy = true;
      pairingError = null;
    });
    try {
      final parsed = CoreAddress.parse(address.text);
      final result = await widget.pairer(parsed, code, deviceName.text.trim());
      if (!mounted) {
        result.clear();
        return;
      }
      final previous = savedProfile;
      if (previous != null &&
          normalizeFingerprint(previous.fingerprint) != result.fingerprint) {
        result.clear();
        throw const CoreException(
          'The core identity differs from your saved core. Verify the change in your trusted terminal before forgetting the saved core and pairing again.',
        );
      }
      setState(() => verifiedCore = result);
    } catch (error) {
      if (mounted) setState(() => pairingError = _errorText(error));
    } finally {
      if (mounted) setState(() => pairingBusy = false);
    }
  }

  Future<void> _enroll() async {
    final result = verifiedCore;
    if (result == null || pairingBusy || !form.currentState!.validate()) return;
    final secret = password.text;
    password.clear();
    setState(() {
      pairingBusy = true;
      pairingError = null;
    });
    try {
      await widget.enroller(result, username.text.trim(), secret);
      if (!mounted) return;
      final profile = CoreProfile(
        address: result.address.label,
        username: username.text.trim(),
        fingerprint: result.fingerprint,
        deviceSeed: result.identity.encodedSeed,
        deviceId: result.identity.id,
      );
      result.clear();
      verifiedCore = null;
      // Save only after both core verification and account authentication.
      try {
        await store.save(profile);
      } catch (_) {
        throw const CoreException(
          'The device was enrolled, but its key could not be saved securely. Check device storage, create a new code, and pair again.',
        );
      }
      if (!mounted) return;
      setState(() {
        savedProfile = profile;
        storageNotice = null;
      });
      await _connectPaired();
    } catch (error) {
      if (mounted) {
        setState(() {
          pairingError = _errorText(error);
          if (error is CoreException && error.statusCode == 410) {
            verifiedCore?.clear();
            verifiedCore = null;
          }
        });
      }
    } finally {
      if (mounted) setState(() => pairingBusy = false);
    }
  }

  Future<void> _connectPaired() async {
    final profile = savedProfile;
    if (profile == null || !profile.isPaired) return;
    try {
      final identity = await DeviceIdentity.fromSeed(profile.deviceSeed!);
      if (identity.id != profile.deviceId) {
        throw const FormatException(
          'The saved device identity is invalid. Pair a new device identity.',
        );
      }
      if (!mounted || savedProfile != profile) return;
      await controller.connectDevice(
        profile.address,
        profile.fingerprint,
        identity,
      );
    } catch (error) {
      if (mounted) setState(() => pairingError = _errorText(error));
    }
  }

  Future<void> _forget() async {
    if (!await vpn.disconnect()) {
      return;
    }
    try {
      final profile = savedProfile;
      if (profile?.isPaired == true) {
        await vpn.forgetKeys(profile!.fingerprint, profile.deviceId!);
      }
      await store.delete();
    } catch (_) {
      if (mounted) {
        setState(
          () => storageNotice =
              'Saved pairing or VPN keys could not be deleted from secure storage.',
        );
      }
      return;
    }
    await controller.disconnect();
    if (!mounted) return;
    setState(() {
      savedProfile = null;
      verifiedCore?.clear();
      verifiedCore = null;
      showLegacy = false;
      pairingError = null;
      storageNotice = null;
      fingerprint.clear();
      username.clear();
      password.clear();
      pairingCode.clear();
    });
  }

  Future<void> _addDevice(BuildContext context) async {
    if (managementBusy) return;
    setState(() {
      managementBusy = true;
      storageNotice = null;
    });
    try {
      final code = await controller.createPairingCode();
      if (!context.mounted || !controller.isDeviceConnection) return;
      await showDialog<void>(
        context: context,
        builder: (_) =>
            PairingCodeDialog(code: code, address: controller.address ?? ''),
      );
    } catch (error) {
      if (mounted) setState(() => storageNotice = _errorText(error));
    } finally {
      if (mounted) setState(() => managementBusy = false);
    }
  }

  @override
  void dispose() {
    vpnPresence?.dispose();
    vpn.dispose();
    verifiedCore?.clear();
    controller.dispose();
    address.dispose();
    username.dispose();
    password.dispose();
    fingerprint.dispose();
    pairingCode.dispose();
    deviceName.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'EasyPrivacy Core',
    debugShowCheckedModeBanner: false,
    theme: buildEasyPrivacyTheme(),
    home: ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Scaffold(
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 1000;
              return Row(
                children: [
                  if (wide) Expanded(child: _welcomePanel(context)),
                  Expanded(
                    child: Center(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.symmetric(
                          horizontal: wide ? 56 : 24,
                          vertical: 32,
                        ),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 520),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (!wide) ...[
                                _brand(),
                                const SizedBox(height: 36),
                              ],
                              if (controller.hasSession)
                                _connection(context)
                              else
                                _signIn(context),
                              if (!controller.hasSession)
                                ListenableBuilder(
                                  listenable: vpn,
                                  builder: (context, _) => vpn.active
                                      ? Padding(
                                          padding: const EdgeInsets.only(
                                            top: 24,
                                          ),
                                          child: ExpansionTile(
                                            title: const Text(
                                              'Previous VPN connection',
                                            ),
                                            subtitle: const Text(
                                              'Migration controls for the original combined app',
                                            ),
                                            children: [
                                              VPNPanel(controller: vpn),
                                            ],
                                          ),
                                        )
                                      : const SizedBox.shrink(),
                                ),
                              if (storageNotice != null) ...[
                                const SizedBox(height: 16),
                                Text(storageNotice!),
                              ],
                              if (Platform.isLinux) ...[
                                const SizedBox(height: 24),
                                ServiceNodePanel(profile: savedProfile),
                              ],
                              const SizedBox(height: 16),
                              if (vpnPresence != null) ...[
                                VPNNotificationSettings(
                                  controller: vpnPresence!,
                                ),
                                const SizedBox(height: 16),
                              ],
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton(
                                  onPressed: () => showLicensePage(
                                    context: context,
                                    applicationName: 'EasyPrivacy',
                                  ),
                                  child: const Text('Licenses'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );

  Widget _brand() => Row(
    children: [
      Image.asset(
        'packages/easyprivacy_ui/assets/easyprivacy-mark.png',
        width: 36,
        height: 36,
      ),
      const SizedBox(width: 12),
      const Text(
        'EasyPrivacy',
        style: TextStyle(
          fontSize: 23,
          fontWeight: FontWeight.w700,
          color: easyPrivacyInk,
        ),
      ),
    ],
  );

  Widget _welcomePanel(BuildContext context) => Container(
    color: easyPrivacySoftGreen,
    padding: const EdgeInsets.all(56),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _brand(),
        const Spacer(),
        const Icon(Icons.shield_outlined, size: 62, color: easyPrivacyGreen),
        const SizedBox(height: 26),
        Text(
          'Your privacy.\nYour infrastructure.',
          style: Theme.of(context).textTheme.headlineLarge,
        ),
        const SizedBox(height: 20),
        Text(
          'A simple connection to the core you control.',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        const Spacer(),
        const Text('Your data should remain yours.'),
      ],
    ),
  );

  Widget _signIn(BuildContext context) {
    if (savedProfile?.isPaired == true) return _rememberedDevice(context);
    if (verifiedCore != null) return _enrollmentSignIn(context);
    if (showLegacy) return _legacySignIn(context);
    final busy = loadingProfile || pairingBusy;
    return Form(
      key: form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Pair with your core',
            style: Theme.of(context).textTheme.headlineLarge,
          ),
          const SizedBox(height: 12),
          const Text(
            'Create a code in your core terminal or on an already paired device.',
          ),
          const SizedBox(height: 28),
          TextFormField(
            key: const Key('core-address'),
            controller: address,
            enabled: !busy,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Core address',
              hintText: 'server.example:7444',
            ),
            validator: (value) {
              try {
                CoreAddress.parse(value ?? '');
                return null;
              } on FormatException catch (e) {
                return e.message;
              }
            },
          ),
          const SizedBox(height: 16),
          TextFormField(
            key: const Key('device-name'),
            controller: deviceName,
            enabled: !busy,
            decoration: const InputDecoration(labelText: 'This device’s name'),
            validator: (value) => (value?.trim().isEmpty ?? true)
                ? 'Enter a name for this device.'
                : null,
          ),
          const SizedBox(height: 16),
          TextFormField(
            key: const Key('pairing-code'),
            controller: pairingCode,
            enabled: !busy,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'Pairing code',
              hintText: '1234 5678',
            ),
            onFieldSubmitted: (_) {
              if (!busy) unawaited(_pair());
            },
            validator: (value) {
              try {
                normalizePairingCode(value ?? '');
                return null;
              } on FormatException catch (e) {
                return e.message;
              }
            },
          ),
          if (pairingError != null) ...[
            const SizedBox(height: 16),
            _notice(pairingError!),
          ],
          const SizedBox(height: 24),
          FilledButton.icon(
            key: const Key('pair-device'),
            onPressed: busy ? null : _pair,
            icon: const Icon(Icons.devices),
            label: Text(pairingBusy ? 'Verifying…' : 'Verify core'),
          ),
          const SizedBox(height: 16),
          const Text(
            'Verify your core first. Then sign in with its username and password to authorize this device.',
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: busy
                ? null
                : () {
                    setState(() => showLegacy = true);
                  },
            child: const Text('Use existing fingerprint login'),
          ),
        ],
      ),
    );
  }

  Widget _enrollmentSignIn(BuildContext context) {
    final core = verifiedCore!;
    return Form(
      key: form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(
            Icons.verified_user_outlined,
            size: 54,
            color: easyPrivacyGreen,
          ),
          const SizedBox(height: 20),
          Text(
            'Core verified',
            style: Theme.of(context).textTheme.headlineLarge,
          ),
          const SizedBox(height: 12),
          SelectableText(core.address.label),
          const SizedBox(height: 12),
          const Text(
            'Sign in with the account created during core setup to authorize this device. Your password is sent only to the verified core and is never saved.',
          ),
          const SizedBox(height: 28),
          TextFormField(
            key: const Key('username'),
            controller: username,
            enabled: !pairingBusy,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'Username'),
            validator: (value) => (value?.trim().isEmpty ?? true)
                ? 'Enter your core username.'
                : null,
          ),
          const SizedBox(height: 16),
          TextFormField(
            key: const Key('password'),
            controller: password,
            enabled: !pairingBusy,
            obscureText: hidePassword,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) {
              if (!pairingBusy) unawaited(_enroll());
            },
            decoration: InputDecoration(
              labelText: 'Password',
              suffixIcon: IconButton(
                tooltip: hidePassword ? 'Show password' : 'Hide password',
                onPressed: () => setState(() => hidePassword = !hidePassword),
                icon: Icon(
                  hidePassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
            ),
            validator: (value) =>
                (value?.isEmpty ?? true) ? 'Enter your core password.' : null,
          ),
          if (pairingError != null) ...[
            const SizedBox(height: 16),
            _notice(pairingError!),
          ],
          const SizedBox(height: 24),
          FilledButton.icon(
            key: const Key('authorize-device'),
            onPressed: pairingBusy ? null : _enroll,
            icon: const Icon(Icons.link),
            label: Text(pairingBusy ? 'Authorizing…' : 'Authorize device'),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: pairingBusy
                ? null
                : () => setState(() {
                    core.clear();
                    verifiedCore = null;
                    pairingError = null;
                    password.clear();
                  }),
            child: const Text('Use a new code'),
          ),
        ],
      ),
    );
  }

  Widget _rememberedDevice(BuildContext context) {
    final busy =
        loadingProfile ||
        pairingBusy ||
        controller.phase == ConnectionPhase.connecting;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Your paired core',
          style: Theme.of(context).textTheme.headlineLarge,
        ),
        const SizedBox(height: 20),
        SelectableText(savedProfile!.address),
        const SizedBox(height: 12),
        const Text('This device reconnects using its saved private key.'),
        if (controller.error != null || pairingError != null) ...[
          const SizedBox(height: 16),
          _notice(pairingError ?? controller.error!),
        ],
        const SizedBox(height: 24),
        FilledButton.icon(
          key: const Key('connect-paired'),
          onPressed: busy ? null : _connectPaired,
          icon: const Icon(Icons.link),
          label: Text(busy ? 'Connecting…' : 'Connect'),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: busy ? null : _forget,
          child: const Text('Forget this core'),
        ),
      ],
    );
  }

  Widget _legacySignIn(BuildContext context) {
    final busy =
        controller.phase == ConnectionPhase.connecting || loadingProfile;
    return Form(
      key: form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Connect to your core',
            style: Theme.of(context).textTheme.headlineLarge,
          ),
          const SizedBox(height: 12),
          const Text(
            'Use the login and fingerprint from your core’s setup terminal.',
          ),
          const SizedBox(height: 28),
          TextFormField(
            key: const Key('core-address'),
            controller: address,
            enabled: !busy,
            autocorrect: false,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Core address',
              hintText: 'server.example:7444',
            ),
            validator: (value) {
              try {
                CoreAddress.parse(value ?? '');
                return null;
              } on FormatException catch (error) {
                return error.message;
              }
            },
          ),
          const SizedBox(height: 16),
          TextFormField(
            key: const Key('core-fingerprint'),
            controller: fingerprint,
            enabled: !busy,
            autocorrect: false,
            enableSuggestions: false,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Core fingerprint',
              hintText: 'SHA256:…',
              helperText:
                  'Copy the fingerprint shown by setup or the identity command.',
            ),
            validator: (value) {
              try {
                normalizeFingerprint(value ?? '');
                return null;
              } on FormatException catch (error) {
                return error.message;
              }
            },
          ),
          const SizedBox(height: 16),
          TextFormField(
            key: const Key('username'),
            controller: username,
            enabled: !busy,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'Username'),
            validator: (value) => (value?.trim().isEmpty ?? true)
                ? 'Enter your core username.'
                : null,
          ),
          const SizedBox(height: 16),
          TextFormField(
            key: const Key('password'),
            controller: password,
            enabled: !busy,
            obscureText: hidePassword,
            autocorrect: false,
            enableSuggestions: false,
            onFieldSubmitted: (_) {
              if (!busy) unawaited(_connect());
            },
            decoration: InputDecoration(
              labelText: 'Password',
              suffixIcon: IconButton(
                tooltip: hidePassword ? 'Show password' : 'Hide password',
                onPressed: () => setState(() => hidePassword = !hidePassword),
                icon: Icon(
                  hidePassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
            ),
            validator: (value) =>
                (value?.isEmpty ?? true) ? 'Enter your core password.' : null,
          ),
          if (controller.error != null) ...[
            const SizedBox(height: 16),
            _notice(controller.error!),
          ],
          const SizedBox(height: 24),
          FilledButton.icon(
            key: const Key('connect'),
            onPressed: busy ? null : _connect,
            icon: busy
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.link),
            label: Text(busy ? 'Connecting…' : 'Connect'),
          ),
          const SizedBox(height: 16),
          const Text(
            'The fingerprint verifies your core before your password is sent. Your password is never saved on this device.',
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: busy
                ? null
                : () {
                    setState(() => showLegacy = false);
                  },
            child: const Text('Use a pairing code'),
          ),
          if (savedProfile != null)
            TextButton(
              onPressed: busy ? null : _forget,
              child: const Text('Forget this core'),
            ),
        ],
      ),
    );
  }

  Widget _connection(BuildContext context) {
    final reachable = controller.phase == ConnectionPhase.connected;
    final status = controller.coreStatus!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(
          reachable ? Icons.verified_user_outlined : Icons.cloud_off_outlined,
          size: 54,
          color: reachable ? easyPrivacyGreen : Colors.orange.shade800,
        ),
        const SizedBox(height: 20),
        Text(
          reachable ? 'Core connected' : 'Core unreachable',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineLarge,
        ),
        const SizedBox(height: 12),
        const Text('Core management connection', textAlign: TextAlign.center),
        if (controller.isDeviceConnection) const CapabilityAccess(),
        if (controller.isDeviceConnection && widget.controller == null)
          const PrivateConnectionPanel(),
        if (controller.isDeviceConnection && !Platform.isLinux) ...[
          const SizedBox(height: 24),
          Card(
            child: ExpansionTile(
              title: const Text('Previous VPN connection'),
              subtitle: const Text(
                'Use the separate EasyPrivacy VPN app for new connections.',
              ),
              children: [VPNPanel(controller: vpn)],
            ),
          ),
        ],
        const SizedBox(height: 28),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  status.name,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                SelectableText(controller.address ?? ''),
                const SizedBox(height: 12),
                Text('Core version: ${status.version}'),
                const SizedBox(height: 8),
                Text(
                  'Last checked: ${controller.lastChecked?.toLocal().toString().split('.').first ?? 'Unknown'}',
                ),
                const SizedBox(height: 8),
                Text(
                  'Session expires: ${status.expiresAt.toLocal().toString().split('.').first}',
                ),
              ],
            ),
          ),
        ),
        if (controller.error != null) ...[
          const SizedBox(height: 16),
          _notice(controller.error!),
        ],
        const SizedBox(height: 24),
        if (controller.isDeviceConnection) ...[
          FilledButton.icon(
            key: const Key('add-device'),
            onPressed: !reachable || managementBusy
                ? null
                : () => _addDevice(context),
            icon: const Icon(Icons.add_link),
            label: Text(managementBusy ? 'Creating code…' : 'Add device'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const Key('manage-devices'),
            onPressed: !reachable || managementBusy
                ? null
                : () {
                    showDialog<void>(
                      context: context,
                      builder: (_) => DevicesDialog(controller: controller),
                    );
                  },
            icon: const Icon(Icons.devices),
            label: const Text('Paired devices'),
          ),
          const SizedBox(height: 12),
        ],
        OutlinedButton.icon(
          onPressed: controller.refresh,
          icon: const Icon(Icons.refresh),
          label: const Text('Check connection'),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: () async {
            if (await vpn.disconnect()) {
              await controller.disconnect();
            }
          },
          icon: const Icon(Icons.link_off),
          label: const Text('Disconnect'),
        ),
      ],
    );
  }

  Widget _notice(String text) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFFFFF4E5),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(text, style: const TextStyle(color: Color(0xFF7A4200))),
  );
}
