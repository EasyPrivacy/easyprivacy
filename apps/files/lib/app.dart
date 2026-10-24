import 'package:flutter/material.dart';
import 'package:easyprivacy_core_sdk/easyprivacy_core_sdk.dart';
import 'package:easyprivacy_ui/easyprivacy_ui.dart';
import 'providers/device_transfer_provider.dart';
import 'screens/send_screen.dart';
import 'providers/folder_sync_provider.dart';
import 'screens/sync_screen.dart';

class EasyPrivacyFilesApp extends StatefulWidget {
  const EasyPrivacyFilesApp({
    super.key,
    this.connection,
    this.transfers,
    this.sync,
  });
  final BrokerCoreConnection? connection;
  final DeviceTransferProvider? transfers;
  final FolderSyncProvider? sync;
  @override
  State<EasyPrivacyFilesApp> createState() => _EasyPrivacyFilesAppState();
}

class _EasyPrivacyFilesAppState extends State<EasyPrivacyFilesApp> {
  late final core =
      widget.connection ?? BrokerCoreConnection(capability: 'files');
  late final transfers = widget.transfers ?? DeviceTransferProvider();
  late final sync = widget.sync ?? FolderSyncProvider(transfers: transfers);
  @override
  void dispose() {
    if (widget.connection == null) core.dispose();
    if (widget.sync == null) sync.dispose();
    if (widget.transfers == null) transfers.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'EasyPrivacy Files',
    theme: buildEasyPrivacyTheme(),
    debugShowCheckedModeBanner: false,
    home: DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('EasyPrivacy Files'),
          actions: [
            Builder(
              builder: (context) => IconButton(
                tooltip: 'About Files',
                icon: const Icon(Icons.info_outline),
                onPressed: () => showAboutDialog(
                  context: context,
                  applicationName: 'EasyPrivacy Files',
                  applicationVersion: '1.0.0 (development)',
                ),
              ),
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.send_outlined), text: 'Send'),
              Tab(icon: Icon(Icons.sync), text: 'Sync'),
              Tab(icon: Icon(Icons.cloud_outlined), text: 'Drive'),
            ],
          ),
        ),
        body: ListenableBuilder(
          listenable: core,
          builder: (context, _) => Column(
            children: [
              Material(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                child: ListTile(
                  leading: Icon(core.hasSession ? Icons.link : Icons.link_off),
                  title: Text(
                    core.hasSession
                        ? (core.coreName ?? 'Core connected')
                        : (core.error ?? 'Connect through EasyPrivacy Core'),
                  ),
                  trailing: IconButton(
                    onPressed: core.refresh,
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Check Core',
                  ),
                ),
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    SendScreen(provider: transfers),
                    SyncScreen(provider: sync),
                    const _Mode(
                      icon: Icons.cloud_outlined,
                      title: 'Your private Drive',
                      description:
                          'Store files on your own server and access them even when your other devices are offline.',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _Mode extends StatelessWidget {
  const _Mode({
    required this.icon,
    required this.title,
    required this.description,
  });
  final IconData icon;
  final String title, description;
  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 20),
            Text(title, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 12),
            Text(description, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            const Text(
              'This capability is not available in this development build.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    ),
  );
}
