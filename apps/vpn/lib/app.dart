import 'package:flutter/material.dart';
import 'package:easyprivacy_core_sdk/easyprivacy_core_sdk.dart';
import 'package:easyprivacy_ui/easyprivacy_ui.dart';
import 'package:easyprivacy_vpn_feature/easyprivacy_vpn.dart';

class EasyPrivacyVpnApp extends StatefulWidget {
  const EasyPrivacyVpnApp({super.key, this.connection});
  final BrokerCoreConnection? connection;
  @override
  State<EasyPrivacyVpnApp> createState() => _EasyPrivacyVpnAppState();
}

class _EasyPrivacyVpnAppState extends State<EasyPrivacyVpnApp> {
  late final core = widget.connection ?? BrokerCoreConnection();
  late final vpn = VPNController(core);
  late final presence = VPNPresenceController(vpn);
  @override
  void dispose() {
    presence.dispose();
    vpn.dispose();
    if (widget.connection == null) core.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'EasyPrivacy VPN',
    debugShowCheckedModeBanner: false,
    theme: buildEasyPrivacyTheme(),
    home: Scaffold(
      appBar: AppBar(title: const Text('EasyPrivacy VPN')),
      body: ListenableBuilder(
        listenable: core,
        builder: (context, _) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  core.coreName ?? 'Your private Internet connection',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                if (!core.hasSession) ...[
                  Text(
                    core.error ??
                        'Open Core, pair this device, and enable VPN access.',
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: core.refresh,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Check Core'),
                  ),
                ],
                const SizedBox(height: 16),
                VPNPanel(controller: vpn),
                const SizedBox(height: 16),
                VPNNotificationSettings(controller: presence),
                const SizedBox(height: 16),
                const Text(
                  'Enrollment and service settings are managed in EasyPrivacy Core. Core’s encrypted connections use the underlying network so they remain independent of this VPN. Disconnect remains available if Core is unreachable.',
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
