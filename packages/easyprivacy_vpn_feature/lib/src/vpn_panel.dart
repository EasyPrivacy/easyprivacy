import 'dart:io';
import 'package:flutter/material.dart';
import 'vpn_controller.dart';
import 'package:easyprivacy_ui/easyprivacy_ui.dart';

class VPNPanel extends StatelessWidget {
  const VPNPanel({super.key, required this.controller});
  final VPNController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final c = controller;
      final homeUnavailable =
          c.active &&
          c.selectedExit == 'home' &&
          c.exits.any((e) => e.id == 'home' && !e.ready);
      final title = homeUnavailable
          ? 'Home exit unavailable'
          : switch (c.phase) {
              VPNPhase.idle => 'VPN disconnected',
              VPNPhase.installing => 'Setting up VPN',
              VPNPhase.provisioning => 'Preparing your VPN',
              VPNPhase.connecting => 'Waiting for the VPN server',
              VPNPhase.connected => 'VPN connected',
              VPNPhase.disconnecting => 'Disconnecting VPN',
            };
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    c.phase == VPNPhase.connected
                        ? Icons.shield
                        : Icons.shield_outlined,
                    color: easyPrivacyGreen,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (c.exits.isNotEmpty)
                DropdownButtonFormField<String>(
                  key: const Key('vpn-exit'),
                  initialValue: c.selectedExit,
                  decoration: const InputDecoration(labelText: 'Internet exit'),
                  items: c.exits
                      .map(
                        (e) =>
                            DropdownMenuItem(value: e.id, child: Text(e.name)),
                      )
                      .toList(),
                  onChanged: c.busy || c.active
                      ? null
                      : (v) {
                          if (v != null) {
                            c.select(v);
                          }
                        },
                ),
              const SizedBox(height: 12),
              const Text(
                'Internet traffic uses the selected server. IPv6 is blocked while this VPN is active.',
              ),
              if (Platform.isWindows && !c.status.installed && !c.active) ...[
                const SizedBox(height: 12),
                const Text(
                  'Windows asks for administrator approval once to set up EasyPrivacy’s VPN service.',
                ),
              ],
              if (c.phase == VPNPhase.connected) ...[
                const SizedBox(height: 12),
                Text(
                  'Received ${_bytes(c.status.received)} · Sent ${_bytes(c.status.sent)}',
                ),
              ],
              if (c.error != null) ...[
                const SizedBox(height: 12),
                Text(c.error!, style: TextStyle(color: Colors.orange.shade900)),
              ],
              if (c.exits.any((e) => e.id == c.selectedExit && !e.ready)) ...[
                const SizedBox(height: 12),
                Text(
                  c.exits
                      .firstWhere((e) => e.id == c.selectedExit && !e.ready)
                      .message,
                ),
              ],
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const Key('vpn-connect'),
                onPressed: c.busy
                    ? null
                    : c.active
                    ? () => c.disconnect()
                    : c.exits.any((e) => e.id == c.selectedExit && e.ready)
                    ? c.connect
                    : null,
                icon: Icon(c.active ? Icons.link_off : Icons.shield_outlined),
                label: Text(c.active ? 'Disconnect VPN' : 'Connect VPN'),
              ),
              if (!c.active)
                TextButton(
                  onPressed: c.busy ? null : c.load,
                  child: const Text('Refresh VPN exits'),
                ),
            ],
          ),
        ),
      );
    },
  );
  String _bytes(int value) {
    if (value < 1024) {
      return '$value B';
    }
    if (value < 1024 * 1024) {
      return '${(value / 1024).toStringAsFixed(1)} KB';
    }
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
