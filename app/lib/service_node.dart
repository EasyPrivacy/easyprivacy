import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'core_client.dart';
import 'profile_store.dart';

class ServiceNodeStatus {
  const ServiceNodeStatus({
    this.installed = true,
    this.configured = false,
    this.active = false,
    this.running = false,
    this.name = 'Home',
    this.message = '',
    this.handshake = 0,
  });
  final bool installed, configured, active, running;
  bool get started => active || running;
  final String name, message;
  final int handshake;
  bool get connected =>
      active &&
      handshake > 0 &&
      DateTime.now().millisecondsSinceEpoch ~/ 1000 - handshake < 180;
  factory ServiceNodeStatus.fromJson(Map<String, dynamic> value) =>
      ServiceNodeStatus(
        installed: value['installed'] as bool? ?? true,
        configured: value['configured'] as bool? ?? false,
        active: value['active'] as bool? ?? false,
        running: value['running'] as bool? ?? false,
        name: value['name'] as String? ?? 'Home',
        message: value['message'] as String? ?? '',
        handshake: (value['last_handshake'] as num?)?.toInt() ?? 0,
      );
}

abstract interface class ServiceNodeClient {
  Future<ServiceNodeStatus> status();
  Future<void> install(
    CoreProfile identity,
    String name, [
    String managementAddresses = '',
  ]);
  Future<void> start();
  Future<void> stop();
}

class LinuxServiceNodeClient implements ServiceNodeClient {
  static const helper = '/usr/bin/easyprivacy-node';
  Future<String> _read(Stream<List<int>> stream) async {
    final bytes = <int>[];
    await for (final chunk in stream) {
      if (bytes.length + chunk.length > 16384) {
        throw const CoreException('Invalid service-node response.');
      }
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
  }

  Future<String> _run(String action, [Map<String, Object>? input]) async {
    if (!File(helper).existsSync()) {
      throw const CoreException(
        'Install the EasyPrivacy Ubuntu node package first.',
      );
    }
    final process = await Process.start(
      action == 'service-status' ? helper : '/usr/bin/pkexec',
      [if (action != 'service-status') helper, action],
      runInShell: false,
    );
    final output = _read(process.stdout), errors = _read(process.stderr);
    if (input != null) process.stdin.write(jsonEncode(input));
    await process.stdin.close();
    try {
      final code = await process.exitCode.timeout(const Duration(seconds: 200));
      final out = await output, err = await errors;
      if (code != 0) {
        throw CoreException(
          err.trim().isEmpty
              ? 'The service action was cancelled or could not finish.'
              : err.trim(),
        );
      }
      return out;
    } on TimeoutException {
      process.kill();
      throw const CoreException(
        'The service action timed out. Check the home service status.',
      );
    }
  }

  @override
  Future<ServiceNodeStatus> status() async {
    if (!File(helper).existsSync()) {
      return const ServiceNodeStatus(installed: false);
    }
    return ServiceNodeStatus.fromJson(
      jsonDecode(await _run('service-status')) as Map<String, dynamic>,
    );
  }

  @override
  Future<void> install(
    CoreProfile identity,
    String name, [
    String managementAddresses = '',
  ]) async {
    if (!identity.isPaired) {
      throw const CoreException('Pair this VM with your core first.');
    }
    await _run('service-install', {
      'identity': {
        'address': identity.address,
        'username': identity.username,
        'fingerprint': identity.fingerprint,
        'device_seed': identity.deviceSeed!,
        'device_id': identity.deviceId!,
      },
      'name': name,
      'uplink': '',
      'management_addresses': managementAddresses,
    });
  }

  @override
  Future<void> start() async {
    await _run('service-start');
  }

  @override
  Future<void> stop() async {
    await _run('service-stop');
  }
}

class ServiceNodePanel extends StatefulWidget {
  const ServiceNodePanel({super.key, this.profile, this.client});
  final CoreProfile? profile;
  final ServiceNodeClient? client;
  @override
  State<ServiceNodePanel> createState() => _ServiceNodePanelState();
}

class _ServiceNodePanelState extends State<ServiceNodePanel> {
  late final client = widget.client ?? LinuxServiceNodeClient();
  final name = TextEditingController(text: 'Home');
  final management = TextEditingController();
  ServiceNodeStatus status = const ServiceNodeStatus();
  bool busy = false, polling = false;
  String? error;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    unawaited(refresh());
    timer = Timer.periodic(const Duration(seconds: 5), (_) => refresh());
  }

  Future<void> refresh() async {
    if (polling || busy) return;
    polling = true;
    try {
      final fresh = await client.status();
      if (mounted) setState(() => status = fresh);
    } catch (_) {
      /* Keep explicit action errors visible; retry next poll. */
    } finally {
      polling = false;
    }
  }

  Future<void> act(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is CoreException
              ? e.message
              : 'Could not update the home service.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
        await refresh();
      }
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    name.dispose();
    management.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Home service node',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          Text(
            status.configured
                ? '${status.name}: ${status.connected
                      ? 'connected to the VPS'
                      : status.started
                      ? 'waiting for the VPS'
                      : 'stopped'}'
                : 'Offer this VM’s Internet connection and LAN through your VPS.',
          ),
          const SizedBox(height: 12),
          const Text(
            'Both Internet links are encrypted. Your VPS is trusted with the forwarded traffic. The service runs independently of this window.',
          ),
          if (!status.installed) ...[
            const SizedBox(height: 12),
            const Text(
              'Install the EasyPrivacy Ubuntu node package to enable this service.',
            ),
          ] else if (!status.configured) ...[
            const SizedBox(height: 16),
            TextField(
              controller: name,
              maxLength: 80,
              decoration: const InputDecoration(labelText: 'Home exit name'),
            ),
            TextField(
              controller: management,
              decoration: const InputDecoration(
                labelText: 'Server management IPv4 addresses',
                helperText:
                    'Comma-separated IPs, without ports. SSH to this VM is included.',
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: busy || widget.profile?.isPaired != true
                  ? null
                  : () => act(
                      () => client.install(
                        widget.profile!,
                        name.text.trim(),
                        management.text.trim(),
                      ),
                    ),
              child: const Text('Set up home exit'),
            ),
            if (widget.profile?.isPaired != true)
              const Text(
                'Pair this VM with your core above, or run sudo easyprivacy-node service-setup in a terminal.',
              ),
          ] else ...[
            const SizedBox(height: 16),
            FilledButton(
              onPressed: busy
                  ? null
                  : () => act(status.started ? client.stop : client.start),
              child: Text(
                status.started ? 'Stop home service' : 'Start home service',
              ),
            ),
          ],
          if (status.message.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(status.message),
          ],
          if (error != null) ...[
            const SizedBox(height: 12),
            Text(error!, style: TextStyle(color: Colors.orange.shade900)),
          ],
          if (busy)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: LinearProgressIndicator(),
            ),
        ],
      ),
    ),
  );
}
