import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:easyprivacy_core_sdk/easyprivacy_core_sdk.dart';

class CapabilityAccess extends StatefulWidget {
  const CapabilityAccess({super.key});
  @override
  State<CapabilityAccess> createState() => _CapabilityAccessState();
}

class _CapabilityAccessState extends State<CapabilityAccess> {
  final storage = const FlutterSecureStorage();
  final broker = PlatformBrokerTransport('core');
  final grants = <String, bool>{'vpn': false, 'files': false};
  bool loading = true;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      for (final id in grants.keys) {
        grants[id] =
            await storage.read(key: 'easyprivacy.broker.allow_$id') == 'true';
      }
    } catch (_) {
      error = 'Could not load capability access.';
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> save(String id, bool value) async {
    try {
      await storage.write(
        key: 'easyprivacy.broker.allow_$id',
        value: value.toString(),
      );
      if (mounted) setState(() => grants[id] = value);
      if (id == 'files' && !value) await broker.call('refreshGrants');
    } catch (_) {
      if (mounted) setState(() => error = 'Could not save capability access.');
    }
  }

  @override
  void dispose() {
    broker.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Connected applications',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          const Text(
            'Allow the separate EasyPrivacy applications to use this device’s core connection.',
          ),
          for (final id in grants.keys)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                id == 'vpn' ? 'EasyPrivacy VPN' : 'EasyPrivacy Files',
              ),
              value: grants[id]!,
              onChanged: loading ? null : (value) => save(id, value),
            ),
          if (error != null) Text(error!),
        ],
      ),
    ),
  );
}
