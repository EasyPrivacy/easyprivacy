import 'dart:async';
import 'package:flutter/material.dart';
import 'package:easyprivacy_core/runtime/api/core_client.dart';
import 'package:easyprivacy_core/runtime/session/core_controller.dart';

class PairingCodeDialog extends StatefulWidget {
  const PairingCodeDialog({
    super.key,
    required this.code,
    required this.address,
  });
  final PairingCode code;
  final String address;
  @override
  State<PairingCodeDialog> createState() => _PairingCodeDialogState();
}

class _PairingCodeDialogState extends State<PairingCodeDialog> {
  Timer? timer;
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seconds = widget.code.expiresAt.difference(DateTime.now()).inSeconds;
    final remaining = seconds < 0 ? 0 : seconds;
    return AlertDialog(
      title: const Text('Pair another device'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(widget.address),
          const SizedBox(height: 20),
          if (remaining > 0) ...[
            SelectableText(
              '${widget.code.code.substring(0, 4)} ${widget.code.code.substring(4)}',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 12),
            Text(
              'Expires in ${remaining ~/ 60}:${(remaining % 60).toString().padLeft(2, '0')}',
            ),
            const SizedBox(height: 12),
            const Text(
              'Enter this code on the new device, then sign in with the core account. It works for one device, with five code attempts maximum.',
            ),
          ] else
            const Text(
              'This code has expired. Close this window and create a new code.',
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class DevicesDialog extends StatefulWidget {
  const DevicesDialog({super.key, required this.controller});
  final CoreController controller;
  @override
  State<DevicesDialog> createState() => _DevicesDialogState();
}

class _DevicesDialogState extends State<DevicesDialog> {
  late Future<List<PairedDevice>> devices = widget.controller.devices();
  bool busy = false;
  String? error;
  Future<void> _revoke(PairedDevice device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Revoke ${device.name}?'),
        content: const Text(
          'Its current connections will end. It will need a new pairing code to connect again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Revoke device'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.controller.revokeDevice(device.id);
      if (!mounted) return;
      if (!widget.controller.hasSession) {
        Navigator.pop(context);
        return;
      }
      setState(() => devices = widget.controller.devices());
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is CoreException
              ? e.message
              : 'Could not revoke the device.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Paired devices'),
    content: SizedBox(
      width: 440,
      height: 360,
      child: Column(
        children: [
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(error!),
            ),
          Expanded(
            child: FutureBuilder<List<PairedDevice>>(
              future: devices,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Text(
                    'Could not load devices. Check your core connection.',
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final list = snapshot.data!;
                return ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const Divider(),
                  itemBuilder: (context, index) {
                    final device = list[index];
                    final current = device.id == widget.controller.deviceId;
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(device.name),
                      subtitle: Text(
                        device.revoked
                            ? 'Revoked'
                            : current
                            ? 'This device'
                            : 'Authorized',
                      ),
                      trailing: device.revoked
                          ? null
                          : IconButton(
                              tooltip: 'Revoke device',
                              onPressed: busy ? null : () => _revoke(device),
                              icon: const Icon(Icons.link_off),
                            ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  );
}
