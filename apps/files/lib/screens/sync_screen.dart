import 'dart:async';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as paths;
import '../background/files_background.dart';
import '../providers/device_transfer_provider.dart';
import '../providers/folder_sync_provider.dart';
import '../sync/documents_mirror.dart';
import '../sync/sync_paths.dart';
import 'send_screen.dart' show fileSize;
import 'sync_folder_browser.dart';
export 'sync_folder_browser.dart';

class SyncScreen extends StatefulWidget {
  const SyncScreen({
    super.key,
    required this.provider,
    this.background,
    this.chooseDirectory,
  });
  final FolderSyncProvider provider;
  final FilesBackground? background;
  final Future<String?> Function()? chooseDirectory;
  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  FolderSyncProvider get provider => widget.provider;
  bool _asked = false;
  @override
  void initState() {
    super.initState();
    widget.background?.addListener(_maybeAsk);
    provider.addListener(_maybeAsk);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAsk());
  }

  @override
  void dispose() {
    widget.background?.removeListener(_maybeAsk);
    provider.removeListener(_maybeAsk);
    super.dispose();
  }

  void _maybeAsk() {
    if (mounted &&
        !_asked &&
        provider.enabled &&
        widget.background?.initialized == true &&
        widget.background?.choice == null) {
      _asked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_background());
      });
    }
  }

  Future<void> _background() async {
    final background = widget.background;
    if (background == null) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Keep folders synced in the background?'),
        content: Text(
          Platform.isAndroid
              ? 'Files can keep your paired devices in sync when you leave the app. Android shows an ongoing notification. You can turn this off here at any time.'
              : 'Closing the Files window will keep Sync running in the system tray. Open Files again from its tray icon, or choose Quit there to stop it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Only while open'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Run in background'),
          ),
        ],
      ),
    );
    if (accepted != null) await background.setEnabled(accepted);
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      provider.error = e.toString();
      provider.changed();
    }
  }

  Future<void> _create() async {
    String? localPath;
    if (Platform.isAndroid) {
      if (!await AndroidFolderDocuments.chooseRoot()) return;
    } else {
      localPath =
          await (widget.chooseDirectory?.call() ??
              getDirectoryPath(confirmButtonText: 'Sync this folder'));
      if (localPath == null) return;
    }
    if (!mounted) return;
    var label = localPath == null ? '' : paths.basename(localPath);
    SendDevice? peer;
    var agreed = false;
    final peers = provider.transfers.devices.where((d) => d.online).toList();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Share a sync folder'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  localPath ??
                      'A folder will be created under Documents/EasyPrivacy Files.',
                ),
                TextFormField(
                  initialValue: label,
                  decoration: const InputDecoration(labelText: 'Folder name'),
                  maxLength: 80,
                  onChanged: (value) => setState(() => label = value),
                ),
                DropdownButton<SendDevice>(
                  isExpanded: true,
                  value: peer,
                  hint: const Text('Choose an online device'),
                  items: peers
                      .map(
                        (d) => DropdownMenuItem(value: d, child: Text(d.name)),
                      )
                      .toList(),
                  onChanged: (v) => setState(() => peer = v),
                ),
                const Text(
                  'Enable Sync on the other device first. It will choose where to keep its copy.',
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: agreed,
                  onChanged: (v) => setState(() => agreed = v!),
                  title: const Text(
                    'Sync all contents, changes and deletions between these devices.',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: peer == null || !agreed || label.trim().isEmpty
                  ? null
                  : () => Navigator.pop(context, true),
              child: const Text('Invite device'),
            ),
          ],
        ),
      ),
    );
    if (accepted == true) {
      await _run(() => provider.create(label, peer!, localPath: localPath));
    }
  }

  Future<void> _accept() async {
    final invitation = provider.invitation;
    if (invitation == null) return;
    String? location;
    if (Platform.isAndroid) {
      if (!await AndroidFolderDocuments.chooseRoot()) return;
    } else {
      location = await getDirectoryPath(
        confirmButtonText: 'Keep synced files here',
      );
      if (location == null) return;
      location = await provider.validateLocation(location);
    }
    if (!mounted || provider.invitation != invitation) return;
    var selective = false;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text('Add ${invitation.label}?'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  location ?? 'Documents/EasyPrivacy Files/${invitation.label}',
                ),
                const SizedBox(height: 12),
                const Text(
                  'Files in this location, including future edits and deletions, will sync automatically with the source. Existing files in a chosen desktop folder will also be shared.',
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Selective sync'),
                  subtitle: const Text(
                    'List all names; download only what you select.',
                  ),
                  value: selective,
                  onChanged: (v) => setState(() => selective = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Add folder'),
            ),
          ],
        ),
      ),
    );
    if (accepted == true && provider.invitation == invitation) {
      provider.decide(
        true,
        localPath: location,
        selection: SyncSelection(selective: selective),
      );
    }
  }

  Future<void> _invite(SyncFolder folder) async {
    final peers = provider.transfers.devices
        .where((d) => d.online && !folder.members.any((m) => m.peer.id == d.id))
        .toList();
    final peer = await showDialog<SendDevice>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Add another device'),
        children: peers.isEmpty
            ? [
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text(
                    'Open Files and enable Sync on another paired device.',
                  ),
                ),
              ]
            : peers
                  .map(
                    (peer) => SimpleDialogOption(
                      onPressed: () => Navigator.pop(context, peer),
                      child: Text(peer.name),
                    ),
                  )
                  .toList(),
      ),
    );
    if (peer != null) await provider.retry(folder, additionalPeer: peer);
  }

  Future<void> _policy(SyncFolder folder, bool selective) async {
    if (selective && !folder.selection.selective) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Choose which files to keep here'),
          content: Text(
            'Switching ${folder.label} to selective sync removes its downloaded file copies from this device. The source keeps every original. Browse the folder and select the files or subfolders you want to keep here.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Use selective sync'),
            ),
          ],
        ),
      );
      if (accepted != true) return;
    }
    await provider.setSelective(folder, selective);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      provider,
      if (widget.background != null) widget.background!,
    ]),
    builder: (context, _) => ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Keep folders in sync',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        const Text(
          'Choose a source folder and keep its contents up to date on your other devices. Changes made in Files or directly in a synced location update automatically. The source device must be available to pass changes between its copies.',
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('Enable folder Sync'),
          value: provider.enabled,
          subtitle: const Text('Connect through your private Core connection.'),
          onChanged: provider.busy
              ? null
              : (v) => unawaited(_run(() => provider.setEnabled(v))),
        ),
        if (widget.background != null)
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Run in background'),
            value: widget.background!.choice == true,
            subtitle: Text(
              Platform.isAndroid
                  ? 'Keep syncing with an ongoing notification.'
                  : 'Keep syncing in the system tray when this window closes.',
            ),
            onChanged: !widget.background!.initialized
                ? null
                : (v) => unawaited(
                    v ? _background() : widget.background!.setEnabled(false),
                  ),
          ),
        if (provider.error != null || widget.background?.error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              provider.error ?? widget.background!.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (!provider.initialized)
          TextButton(
            onPressed: provider.initialize,
            child: const Text('Check Core'),
          ),
        FilledButton.icon(
          onPressed: !provider.enabled || provider.busy
              ? null
              : () => unawaited(_run(_create)),
          icon: const Icon(Icons.folder_open_outlined),
          label: Text(
            Platform.isAndroid ? 'Create sync folder' : 'Choose folder to sync',
          ),
        ),
        if (provider.busy)
          const Padding(
            padding: EdgeInsets.all(12),
            child: LinearProgressIndicator(),
          ),
        if (provider.invitation != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${provider.invitation!.peer.name} wants to share “${provider.invitation!.label}”.',
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Choose where to keep your local copy and which contents to sync.',
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton(
                        onPressed: () => unawaited(_run(_accept)),
                        child: const Text('Accept folder'),
                      ),
                      TextButton(
                        onPressed: () => provider.decide(false),
                        child: const Text('Decline folder'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        for (final folder in provider.folders)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    folder.label,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    'With ${folder.members.map((m) => m.peer.name).join(', ')}',
                  ),
                  SelectableText(
                    provider.location(folder),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Text(
                    provider.enabled
                        ? folder.state
                        : folder.linked
                        ? 'Sync is off'
                        : 'Local copy · link removed',
                  ),
                  Text('${folder.files} files · ${fileSize(folder.bytes)}'),
                  if (folder.isSource)
                    const Text('Source folder · always sync everything')
                  else if (folder.linked)
                    DropdownButton<bool>(
                      value: folder.selection.selective,
                      items: const [
                        DropdownMenuItem(
                          value: false,
                          child: Text('Sync everything'),
                        ),
                        DropdownMenuItem(
                          value: true,
                          child: Text('Selective sync'),
                        ),
                      ],
                      onChanged:
                          !provider.enabled || folder.paused || provider.busy
                          ? null
                          : (value) =>
                                unawaited(_run(() => _policy(folder, value!))),
                    ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: provider.root == null
                            ? null
                            : () => Navigator.push(
                                context,
                                MaterialPageRoute<void>(
                                  builder: (_) => SyncFolderBrowser(
                                    provider: provider,
                                    folder: folder,
                                  ),
                                ),
                              ),
                        child: const Text('Browse files'),
                      ),
                      if (Platform.isWindows)
                        TextButton(
                          onPressed: () => unawaited(
                            _run(() => provider.openDirectory(folder)),
                          ),
                          child: const Text('Open folder location'),
                        ),
                      if (Platform.isAndroid && !folder.useDocuments)
                        TextButton(
                          onPressed: () => unawaited(
                            _run(() => provider.placeInDocuments(folder)),
                          ),
                          child: const Text('Place in Documents'),
                        ),
                      if (folder.linked && folder.enginePeer == null)
                        TextButton(
                          onPressed: provider.enabled && !provider.busy
                              ? () => provider.retry(folder)
                              : null,
                          child: const Text('Retry invitation'),
                        ),
                      if (folder.linked && folder.enginePeer != null)
                        TextButton(
                          onPressed: provider.enabled && !provider.busy
                              ? () => provider.pause(folder, !folder.paused)
                              : null,
                          child: Text(folder.paused ? 'Resume' : 'Pause'),
                        ),
                      if (folder.isSource &&
                          folder.linked &&
                          folder.additionalPeers.length < 2)
                        TextButton(
                          onPressed: provider.enabled && !provider.busy
                              ? () => unawaited(_run(() => _invite(folder)))
                              : null,
                          child: const Text('Add device'),
                        ),
                      if (folder.linked)
                        TextButton(
                          onPressed: provider.busy
                              ? null
                              : () => provider.remove(folder),
                          child: const Text('Stop sharing'),
                        ),
                      if (!folder.linked)
                        TextButton(
                          onPressed: provider.busy
                              ? null
                              : () => provider.deleteLocalCopy(folder),
                          child: Text(
                            folder.localPath != null || folder.useDocuments
                                ? 'Forget folder (keep files)'
                                : 'Delete local copy',
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 12),
        const Text(
          'Remote replacements and deletions retain up to five previous versions. Sync is not a separate backup.',
        ),
      ],
    ),
  );
}
