import 'dart:async';
import 'package:flutter/material.dart';
import 'package:easyprivacy_core_sdk/easyprivacy_core_sdk.dart';

class PrivateConnectionPanel extends StatefulWidget {
  const PrivateConnectionPanel({super.key});
  @override
  State<PrivateConnectionPanel> createState() => _PrivateConnectionPanelState();
}

class _PrivateConnectionPanelState extends State<PrivateConnectionPanel> {
  final transport = PlatformBrokerTransport('core');
  Map<String, dynamic> status = {};
  String? error;
  bool busy = false, refreshing = false;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    unawaited(refresh());
    timer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(refresh()),
    );
  }

  Future<void> refresh() async {
    if (refreshing || busy) return;
    refreshing = true;
    try {
      final value = await transport.call('privateStatus');
      if (mounted) {
        setState(() {
          status = value;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      refreshing = false;
    }
  }

  Future<void> action(String method) async {
    setState(() => busy = true);
    try {
      final value = await transport.call(method);
      if (mounted) {
        setState(() {
          status = value;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    transport.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = status['active'] == true,
        starting = status['starting'] == true;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Private service connection',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'Connect your EasyPrivacy services without routing this device’s Internet traffic. Requires an updated core node.',
            ),
            const SizedBox(height: 12),
            Text(
              starting
                  ? 'Starting private connection…'
                  : active
                  ? 'Private connection enabled'
                  : 'Private connection stopped',
            ),
            if (error != null || status['message'] is String)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(error ?? status['message'] as String),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: busy || starting
                      ? null
                      : () => action(active ? 'privateStop' : 'privateStart'),
                  child: Text(
                    active
                        ? 'Stop private connection'
                        : 'Start private connection',
                  ),
                ),
                if (active)
                  OutlinedButton(
                    onPressed: busy ? null : () => action('privateProbe'),
                    child: const Text('Check connection'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
