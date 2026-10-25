import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../providers/folder_sync_provider.dart';
import '../sync/sync_paths.dart';
import '../transfer/file_selection.dart';
import '../transfer/file_store.dart';
import 'send_screen.dart' show fileSize;

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
  List<SyncEntry> entries = [];
  bool busy = false, _refreshing = false;
  String? error;
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _timer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!busy) unawaited(_refresh());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    final requested = relative;
    try {
      final loaded = await widget.provider.entries(widget.folder, requested);
      if (mounted && requested == relative) {
        setState(() {
          entries = loaded;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
      if (widget.provider.enabled) await widget.provider.refresh();
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> _confirm(String title, String message, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;
  Future<String?> _name(
    String title, {
    String initial = '',
    String label = 'Name',
  }) async {
    var value = initial;
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextFormField(
          initialValue: initial,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
          onChanged: (v) => value = v,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, value),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _add() async {
    final source = await pickTransferSource();
    if (source == null) return;
    final name = safeTransferName(source.name);
    final exists = entries.any((e) => e.name == name);
    if (exists &&
        (!mounted ||
            !await _confirm(
              'Replace $name?',
              'This replacement will sync to the other devices.',
              'Replace',
            ))) {
      return;
    }
    await widget.provider.importFile(
      widget.folder,
      source,
      relative: relative,
      replace: exists,
    );
  }

  Future<void> _mkdir() async {
    final name = await _name('New folder');
    if (name == null || name.isEmpty) return;
    if (name.contains('/') || name.contains('\\')) {
      throw const FileSystemException('Choose a folder name without a path.');
    }
    await widget.provider.createDirectory(
      widget.folder,
      [if (relative.isNotEmpty) relative, name].join('/'),
    );
  }

  Future<void> _action(SyncEntry entry, String action) async {
    switch (action) {
      case 'open':
        await widget.provider.open(widget.folder, entry.path);
      case 'edit':
        await widget.provider.open(widget.folder, entry.path, edit: true);
      case 'move':
        final destination = await _name(
          'Move or rename ${entry.name}',
          initial: entry.path,
          label: 'New path within this synced folder',
        );
        if (destination != null) {
          await widget.provider.move(widget.folder, entry.path, destination);
        }
      case 'delete':
        if (await _confirm(
          'Delete ${entry.name}?',
          'This deletes the item${entry.directory ? ' and its contents' : ''} from the synced folder on all connected devices.',
          'Delete',
        )) {
          await widget.provider.deleteEntry(widget.folder, entry.path);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final folder = widget.folder;
    final canChange = folder.linked && folder.enginePeer != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(folder.label),
        actions: [
          IconButton(
            tooltip: 'Refresh folder',
            onPressed: busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SelectableText(
                '${widget.provider.location(folder)}${relative.isEmpty ? '' : '/$relative'}',
              ),
            ),
          ),
          if (relative.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.arrow_upward),
              title: const Text('Parent folder'),
              onTap: busy
                  ? null
                  : () {
                      final parts = relative.split('/')..removeLast();
                      relative = parts.join('/');
                      unawaited(_refresh());
                    },
            ),
          if (folder.selection.selective)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'All available names are listed. Check files or folders to keep them here. Unchecking removes this device’s synced copy; the source keeps its original.',
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: busy || !canChange
                      ? null
                      : () => unawaited(_run(_add)),
                  icon: const Icon(Icons.add),
                  label: const Text('Add file'),
                ),
                OutlinedButton.icon(
                  onPressed: busy || !canChange
                      ? null
                      : () => unawaited(_run(_mkdir)),
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text('New folder'),
                ),
              ],
            ),
          ),
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: entries.isEmpty
                ? const Center(child: Text('No files in this folder yet.'))
                : ListView.builder(
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      final selected = folder.selection.includes(entry.path);
                      final partial =
                          entry.directory &&
                          folder.selection.rules.entries.any(
                            (r) =>
                                r.value != selected &&
                                r.key.startsWith('${entry.path}/'),
                          );
                      return ListTile(
                        leading: Icon(
                          entry.directory
                              ? Icons.folder_outlined
                              : entry.local
                              ? Icons.insert_drive_file_outlined
                              : Icons.cloud_download_outlined,
                        ),
                        title: Text(entry.name),
                        subtitle: Text(
                          entry.directory
                              ? (entry.local ? 'Folder' : 'Available to sync')
                              : '${entry.size < 0 ? 'In Documents' : fileSize(entry.size)} · ${entry.local
                                    ? 'On this device'
                                    : selected
                                    ? 'Waiting to download'
                                    : 'Available to sync'}',
                        ),
                        onTap: busy
                            ? null
                            : () {
                                if (entry.directory) {
                                  relative = entry.path;
                                  unawaited(_refresh());
                                } else {
                                  unawaited(
                                    _run(
                                      () => widget.provider.open(
                                        folder,
                                        entry.path,
                                      ),
                                    ),
                                  );
                                }
                              },
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (folder.selection.selective)
                              Checkbox(
                                tristate: true,
                                value: partial ? null : selected,
                                onChanged:
                                    busy ||
                                        !widget.provider.enabled ||
                                        folder.paused
                                    ? null
                                    : (_) => unawaited(
                                        _run(
                                          () => widget.provider.select(
                                            folder,
                                            entry.path,
                                            partial || !selected,
                                          ),
                                        ),
                                      ),
                              ),
                            PopupMenuButton<String>(
                              enabled: !busy && entry.local,
                              tooltip: 'File actions',
                              onSelected: (action) =>
                                  unawaited(_run(() => _action(entry, action))),
                              itemBuilder: (_) => [
                                if (!entry.directory)
                                  const PopupMenuItem(
                                    value: 'open',
                                    child: Text('Open with…'),
                                  ),
                                if (!entry.directory)
                                  const PopupMenuItem(
                                    value: 'edit',
                                    child: Text('Edit with…'),
                                  ),
                                if (canChange)
                                  const PopupMenuItem(
                                    value: 'move',
                                    child: Text('Move / rename'),
                                  ),
                                if (canChange)
                                  const PopupMenuItem(
                                    value: 'delete',
                                    child: Text('Delete'),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
