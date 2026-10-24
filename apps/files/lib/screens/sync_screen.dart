import 'dart:async';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as paths;
import '../providers/device_transfer_provider.dart';
import '../providers/folder_sync_provider.dart';
import '../transfer/file_store.dart';
import '../transfer/file_selection.dart';
import 'send_screen.dart';

class SyncScreen extends StatelessWidget {
  const SyncScreen({super.key, required this.provider});
  final FolderSyncProvider provider;
  Future<void> _create(BuildContext context) async {
    var label = '';
    SendDevice? peer;
    var agreed = false;
    final peers = provider.transfers.devices.where((d) => d.online).toList();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Create shared folder'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
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
                  'Enable Sync on the other device first. Each device keeps a local copy inside Files.',
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: agreed,
                  onChanged: (v) => setState(() => agreed = v!),
                  title: const Text(
                    'Sync changes and deletions between these devices.',
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
    if (accepted == true) unawaited(provider.create(label, peer!));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: provider,
    builder: (context, _) => ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Keep folders in sync',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        const Text(
          'Each device keeps a copy. Changes and deletions sync while Files is open. Remote replacements and deletions keep up to five older versions. Sync is not a separate backup.',
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('Enable folder Sync'),
          value: provider.enabled,
          subtitle: const Text('Connect through your private Core connection.'),
          onChanged: provider.busy ? null : provider.setEnabled,
        ),
        if (provider.error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              provider.error!,
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
              : () => _create(context),
          icon: const Icon(Icons.create_new_folder_outlined),
          label: const Text('Create shared folder'),
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
                    'Accepting creates a local folder inside Files. Changes and deletions in this folder sync between these two devices.',
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton(
                        onPressed: () => provider.decide(true),
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
        ...provider.folders.map(
          (folder) => Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    folder.label,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text('With ${folder.peer.name}'),
                  Text(
                    provider.enabled
                        ? folder.state
                        : folder.linked
                        ? 'Sync is off'
                        : 'Local copy · link removed',
                  ),
                  Text('${folder.files} files · ${fileSize(folder.bytes)}'),
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
                              : () async {
                                  final remove = await showDialog<bool>(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      title: const Text(
                                        'Delete the local copy?',
                                      ),
                                      content: const Text(
                                        'This removes this device’s retained folder and older versions. The other device keeps its own copy.',
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(context, false),
                                          child: const Text('Cancel'),
                                        ),
                                        FilledButton(
                                          onPressed: () =>
                                              Navigator.pop(context, true),
                                          child: const Text(
                                            'Delete local copy',
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (remove == true) {
                                    await provider.deleteLocalCopy(folder);
                                  }
                                },
                          child: const Text('Delete local copy'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class SyncFolderBrowser extends StatefulWidget {
  const SyncFolderBrowser({
    super.key,
    required this.provider,
    required this.folder,
  });
  final FolderSyncProvider provider;
  final SyncFolder folder;
  @override
  State<SyncFolderBrowser> createState() => _SyncFolderBrowserState();
}

class _SyncFolderBrowserState extends State<SyncFolderBrowser> {
  String relative = '';
  List<FileSystemEntity> entries = [];
  bool busy = false;
  String? error;
  Directory get base => widget.provider.directory(widget.folder);
  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    try {
      final target = Directory(paths.join(base.path, relative));
      if (!paths.equals(target.absolute.path, base.absolute.path) &&
          !paths.isWithin(base.absolute.path, target.absolute.path)) {
        throw const FileSystemException('Invalid folder.');
      }
      if (await FileSystemEntity.type(target.path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const FileSystemException('Linked folders cannot be opened.');
      }
      if (await target.exists()) {
        final canonical = await target.resolveSymbolicLinks(),
            canonicalBase = await base.resolveSymbolicLinks();
        if (!paths.equals(canonical, canonicalBase) &&
            !paths.isWithin(canonicalBase, canonical)) {
          throw const FileSystemException('Linked folders cannot be opened.');
        }
      }
      final loaded = <FileSystemEntity>[];
      if (await target.exists()) {
        await for (final entry in target.list(followLinks: false)) {
          final name = paths.basename(entry.path);
          if ((entry is File || entry is Directory) &&
              !name.startsWith('.st') &&
              !name.startsWith('.syncthing')) {
            loaded.add(entry);
          }
          if (loaded.length >= 1000) break;
        }
      }
      loaded.sort(
        (a, b) => a is Directory && b is! Directory
            ? -1
            : b is Directory && a is! Directory
            ? 1
            : paths.basename(a.path).compareTo(paths.basename(b.path)),
      );
      if (mounted) {
        setState(() {
          entries = loaded;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> _import() async {
    setState(() => busy = true);
    try {
      final source = await pickTransferSource();
      if (source == null) return;
      final destination = File(
        paths.join(base.path, safeTransferName(source.name)),
      );
      var replace = false;
      if (await destination.exists()) {
        if (!mounted) return;
        replace =
            await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Replace this file in the synced folder?'),
                content: const Text(
                  'The change will also sync to the other device.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Replace'),
                  ),
                ],
              ),
            ) ??
            false;
        if (!replace) return;
      }
      await widget.provider.importFile(widget.folder, source, replace: replace);
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _save(File file) async {
    setState(() => busy = true);
    try {
      final canonical = await file.resolveSymbolicLinks(),
          canonicalBase = await base.resolveSymbolicLinks();
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          !paths.isWithin(canonicalBase, canonical)) {
        throw const FileSystemException('Linked files cannot be exported.');
      }
      if (Platform.isAndroid) {
        await const MethodChannel(
          'org.easyprivacy/files_storage',
        ).invokeMethod<bool>('saveReceived', {
          'path': file.path,
          'name': paths.basename(file.path),
        });
      } else {
        final location = await getSaveLocation(
          suggestedName: paths.basename(file.path),
        );
        if (location != null) {
          final destination = File(location.path);
          if (await destination.exists()) {
            throw const FileSystemException(
              'Choose a new filename to keep both copies.',
            );
          }
          await file.copy(destination.path);
        }
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _delete(File file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${paths.basename(file.path)}?'),
        content: const Text(
          'This deletion will also sync to the other device when the link is active.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete file'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => busy = true);
    try {
      await widget.provider.deleteFile(widget.folder, file);
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.folder.label),
      actions: [
        IconButton(
          tooltip: 'Refresh folder',
          onPressed: _refresh,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: Column(
      children: [
        if (relative.isNotEmpty)
          ListTile(
            leading: const Icon(Icons.arrow_upward),
            title: const Text('Parent folder'),
            onTap: () {
              relative = paths.dirname(relative) == '.'
                  ? ''
                  : paths.dirname(relative);
              unawaited(_refresh());
            },
          ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            onPressed:
                busy ||
                    !widget.folder.linked ||
                    widget.folder.enginePeer == null
                ? null
                : _import,
            icon: const Icon(Icons.add),
            label: const Text('Add file to folder root'),
          ),
        ),
        if (busy) const LinearProgressIndicator(),
        if (error != null)
          Padding(padding: const EdgeInsets.all(12), child: Text(error!)),
        Expanded(
          child: ListView(
            children: entries
                .map(
                  (entry) => ListTile(
                    leading: Icon(
                      entry is Directory
                          ? Icons.folder_outlined
                          : Icons.insert_drive_file_outlined,
                    ),
                    title: Text(paths.basename(entry.path)),
                    onTap: entry is Directory
                        ? () {
                            relative = paths.relative(
                              entry.path,
                              from: base.path,
                            );
                            unawaited(_refresh());
                          }
                        : null,
                    trailing: entry is File
                        ? PopupMenuButton<String>(
                            enabled: !busy,
                            tooltip: 'File actions',
                            onSelected: (action) => unawaited(
                              action == 'save' ? _save(entry) : _delete(entry),
                            ),
                            itemBuilder: (_) => [
                              const PopupMenuItem(
                                value: 'save',
                                child: Text('Save a copy'),
                              ),
                              if (widget.folder.linked &&
                                  widget.folder.enginePeer != null)
                                const PopupMenuItem(
                                  value: 'delete',
                                  child: Text('Delete file'),
                                ),
                            ],
                          )
                        : const Icon(Icons.chevron_right),
                  ),
                )
                .toList(),
          ),
        ),
      ],
    ),
  );
}
