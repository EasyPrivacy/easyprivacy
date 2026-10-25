import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:easyprivacy_protocol/easyprivacy_protocol.dart';
import 'package:path/path.dart' as paths;
import '../drive/drive_client.dart';
import '../transfer/file_selection.dart';
import '../transfer/secure_channel.dart';
import 'send_screen.dart' show fileSize;

class DriveScreen extends StatefulWidget {
  const DriveScreen({super.key, this.client});
  final DriveClient? client;
  @override
  State<DriveScreen> createState() => _DriveScreenState();
}

class _DriveScreenState extends State<DriveScreen> {
  late final client = widget.client ?? DriveClient();
  List<DriveNode> nodes = [];
  List<DriveVolume> volumes = [];
  List<DriveEntry> entries = [];
  String? nodeId, volumeId, error;
  String folder = '', cursor = '';
  bool loading = false, busy = false;
  int transferred = 0, total = 0;
  Timer? timer;
  DriveNode? get node => nodes.where((n) => n.id == nodeId).firstOrNull;
  DriveVolume? get volume => volumes.where((v) => v.id == volumeId).firstOrNull;
  @override
  void initState() {
    super.initState();
    unawaited(refresh());
    timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!busy) unawaited(refresh());
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    if (widget.client == null) client.close();
    super.dispose();
  }

  Future<void> refresh({bool more = false}) async {
    if (loading) return;
    loading = true;
    if (mounted) setState(() => error = null);
    try {
      if (!more) {
        nodes = await client.nodes();
        if (!nodes.any((n) => n.id == nodeId)) {
          nodeId = nodes.firstOrNull?.id;
          volumeId = null;
          folder = '';
        }
        volumes = node == null ? [] : await client.volumes(node!);
        if (!volumes.any((v) => v.id == volumeId)) {
          volumeId = volumes.firstOrNull?.id;
          folder = '';
        }
      }
      if (node != null && volume != null) {
        final page = await client.list(
          node!,
          volumeId!,
          folder,
          cursor: more ? cursor : '',
        );
        entries = more ? [...entries, ...page.$1] : page.$1;
        cursor = page.$2;
      } else {
        entries = [];
        cursor = '';
      }
    } catch (e) {
      error = e.toString();
    } finally {
      loading = false;
      if (mounted) setState(() {});
    }
  }

  String child(String name) => [if (folder.isNotEmpty) folder, name].join('/');
  Future<void> run(Future<void> Function() action) async {
    if (busy || loading) return;
    setState(() {
      busy = true;
      error = null;
      transferred = 0;
      total = 0;
    });
    try {
      await action();
      await refresh();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void progress(int done, int bytes) {
    if (mounted) {
      setState(() {
        transferred = done;
        total = bytes;
      });
    }
  }

  Future<String?> nameDialog(
    String title, {
    String initial = '',
    String label = 'Name',
  }) async {
    var name = initial;
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextFormField(
          initialValue: initial,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
          onChanged: (s) => name = s,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, name),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<bool> confirm(String title, String detail, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(detail),
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
  Future<void> upload() async {
    final source = await pickTransferSource();
    if (source == null) return;
    if (!validDrivePath(source.name) || source.name.contains('/')) {
      throw const TransferFailure('Choose a file with a supported name.');
    }
    await client.upload(
      node!,
      volumeId!,
      child(source.name),
      source,
      progress: progress,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Uploaded. Your original file is unchanged.'),
        ),
      );
    }
  }

  Future<void> mkdir() async {
    final name = await nameDialog('New cloud folder');
    if (name == null) return;
    if (!validDrivePath(name) || name.contains('/')) {
      throw const TransferFailure('Choose a folder name without a path.');
    }
    await client.change(
      node!,
      DriveCommand(op: 'mkdir', volume: volumeId!, path: child(name)),
    );
  }

  Future<void> save(DriveDownload download) async {
    if (Platform.isAndroid) {
      final result = await const MethodChannel('org.easyprivacy/files_storage')
          .invokeMethod<bool>('saveReceived', {
            'path': download.file.path,
            'name': download.name,
          });
      if (result != true) return;
    } else {
      final chosen = await getSaveLocation(suggestedName: download.name);
      if (chosen == null || !mounted) return;
      final destination = File(chosen.path);
      if (await destination.exists() &&
          (!mounted ||
              !await confirm(
                'Replace local file?',
                'Replace the file at the location you selected?',
                'Replace',
              ))) {
        return;
      }
      final temporary = File(
        paths.join(
          destination.parent.path,
          '.easyprivacy-drive-${randomTransferNonce()}.part',
        ),
      );
      try {
        await download.file.copy(temporary.path);
        await temporary.rename(destination.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved an independent local copy.')),
      );
    }
  }

  Future<void> getFile(DriveEntry entry, {bool preview = false}) async {
    final download = await client.download(
      node!,
      volumeId!,
      child(entry.name),
      limit: preview ? 16 * 1024 * 1024 : maxDriveFileBytes,
      progress: progress,
    );
    try {
      if (!mounted) return;
      if (preview) {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                _DrivePreview(download: download, save: () => save(download)),
          ),
        );
      } else {
        await save(download);
      }
    } finally {
      await download.discard();
    }
  }

  Future<void> action(DriveEntry entry, String value) async {
    if (value == 'download') {
      await getFile(entry);
      return;
    }
    if (value == 'preview') {
      await getFile(entry, preview: true);
      return;
    }
    if (value == 'move') {
      final target = await nameDialog(
        'Move or rename ${entry.name}',
        initial: child(entry.name),
        label: 'New path in this storage location',
      );
      if (target != null) {
        await client.change(
          node!,
          DriveCommand(
            op: 'move',
            volume: volumeId!,
            path: child(entry.name),
            target: target,
          ),
        );
      }
    }
    if (value == 'delete' &&
        mounted &&
        await confirm(
          'Delete ${entry.name} from Drive?',
          'This removes the cloud ${entry.directory ? 'folder and its contents' : 'file'} for all devices. Independent local copies remain.',
          'Delete from Drive',
        )) {
      await client.change(
        node!,
        DriveCommand(op: 'delete', volume: volumeId!, path: child(entry.name)),
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              'Your private Drive',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          IconButton(
            tooltip: 'Refresh Drive',
            onPressed: busy || loading ? null : () => unawaited(refresh()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      const Text(
        'Store files on your server. Uploads keep your originals; previews and downloads retrieve only the files you choose.',
      ),
      const SizedBox(height: 16),
      if (nodes.isEmpty && !loading)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Text(
            'No Drive node is available. Pair and configure a storage node, enable Files access in Core, then refresh.',
          ),
        ),
      if (nodes.isNotEmpty)
        DropdownButtonFormField<String>(
          initialValue: nodeId,
          key: ValueKey('node-$nodeId'),
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Drive node'),
          items: [
            for (final n in nodes)
              DropdownMenuItem(
                value: n.id,
                child: Text(n.name, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: busy || loading
              ? null
              : (id) {
                  setState(() {
                    nodeId = id;
                    volumeId = null;
                    folder = '';
                    entries = [];
                  });
                  unawaited(refresh());
                },
        ),
      if (volumes.isNotEmpty) ...[
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: volumeId,
          key: ValueKey('volume-$volumeId'),
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Storage location'),
          items: [
            for (final v in volumes)
              DropdownMenuItem(
                value: v.id,
                child: Text(v.name, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: busy || loading
              ? null
              : (id) {
                  setState(() {
                    volumeId = id;
                    folder = '';
                    entries = [];
                  });
                  unawaited(refresh());
                },
        ),
        const SizedBox(height: 8),
        if (volume != null)
          Text(
            '${fileSize(volume!.used)} used of ${fileSize(volume!.quota)}${volume!.reserved > 0 ? ' · ${fileSize(volume!.reserved)} uploading' : ''}${!volume!.available ? ' · Storage needs attention' : ''}',
          ),
        const SizedBox(height: 12),
        SelectableText(folder.isEmpty ? '/' : '/$folder'),
        if (folder.isNotEmpty)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.arrow_upward),
            title: const Text('Parent folder'),
            onTap: busy || loading
                ? null
                : () {
                    setState(() {
                      final parts = folder.split('/')..removeLast();
                      folder = parts.join('/');
                      entries = [];
                    });
                    unawaited(refresh());
                  },
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: busy || loading ? null : () => unawaited(run(upload)),
              icon: const Icon(Icons.upload),
              label: const Text('Upload file'),
            ),
            OutlinedButton.icon(
              onPressed: busy || loading ? null : () => unawaited(run(mkdir)),
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('New folder'),
            ),
          ],
        ),
      ],
      if (busy || loading) ...[
        const SizedBox(height: 12),
        LinearProgressIndicator(value: total > 0 ? transferred / total : null),
      ],
      if (busy)
        TextButton(
          onPressed: () => unawaited(client.cancel()),
          child: Text(
            total > 0
                ? 'Cancel transfer · ${fileSize(transferred)} / ${fileSize(total)}'
                : 'Cancel operation',
          ),
        ),
      if (error != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      if (entries.isEmpty && volume != null && !loading && error == null)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Text('No cloud files in this folder yet.'),
        ),
      for (final entry in entries)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            entry.directory
                ? Icons.folder_outlined
                : Icons.insert_drive_file_outlined,
          ),
          title: Text(entry.name),
          subtitle: Text(
            entry.directory ? 'Cloud folder' : fileSize(entry.size),
          ),
          onTap: busy || loading
              ? null
              : () {
                  if (entry.directory) {
                    setState(() {
                      folder = child(entry.name);
                      entries = [];
                    });
                    unawaited(refresh());
                  } else {
                    unawaited(run(() => getFile(entry, preview: true)));
                  }
                },
          trailing: PopupMenuButton<String>(
            enabled: !busy && !loading,
            tooltip: 'Cloud file actions',
            onSelected: (value) => unawaited(run(() => action(entry, value))),
            itemBuilder: (_) => [
              if (!entry.directory)
                const PopupMenuItem(value: 'preview', child: Text('Preview')),
              if (!entry.directory)
                const PopupMenuItem(
                  value: 'download',
                  child: Text('Download a copy'),
                ),
              const PopupMenuItem(value: 'move', child: Text('Move / rename')),
              const PopupMenuItem(
                value: 'delete',
                child: Text('Delete from Drive'),
              ),
            ],
          ),
        ),
      if (cursor.isNotEmpty)
        TextButton(
          onPressed: busy || loading
              ? null
              : () => unawaited(refresh(more: true)),
          child: const Text('Load more'),
        ),
    ],
  );
}

class _DrivePreview extends StatefulWidget {
  const _DrivePreview({required this.download, required this.save});
  final DriveDownload download;
  final Future<void> Function() save;
  @override
  State<_DrivePreview> createState() => _DrivePreviewState();
}

class _DrivePreviewState extends State<_DrivePreview> {
  bool saving = false;
  String? error;
  late final extension = paths.extension(widget.download.name).toLowerCase();
  late final text =
      {
        '',
        '.txt',
        '.md',
        '.json',
        '.csv',
        '.log',
        '.yaml',
        '.yml',
        '.xml',
        '.html',
        '.css',
        '.dart',
        '.go',
      }.contains(extension) &&
      widget.download.size <= 1024 * 1024;
  late final contents = text
      ? widget.download.file.readAsBytes().then(
          (b) => utf8.decode(b, allowMalformed: true),
        )
      : null;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.download.name)),
    body: Column(
      children: [
        Expanded(
          child:
              {
                '.png',
                '.jpg',
                '.jpeg',
                '.webp',
                '.gif',
                '.bmp',
              }.contains(extension)
              ? InteractiveViewer(
                  child: Center(
                    child: Image.file(
                      widget.download.file,
                      cacheWidth: 1600,
                      errorBuilder: (_, _, _) =>
                          const Text('This image could not be displayed.'),
                    ),
                  ),
                )
              : text
              ? FutureBuilder<String>(
                  future: contents,
                  builder: (context, result) => result.hasError
                      ? const Center(
                          child: Text('The file could not be previewed.'),
                        )
                      : result.hasData
                      ? SingleChildScrollView(
                          padding: const EdgeInsets.all(20),
                          child: SelectableText(result.data!),
                        )
                      : const Center(child: CircularProgressIndicator()),
                )
              : const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Preview is not available for this file type. Save a copy to open it with another application.',
                    ),
                  ),
                ),
        ),
        if (error != null)
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: saving
                ? null
                : () async {
                    setState(() => saving = true);
                    try {
                      await widget.save();
                    } catch (e) {
                      if (mounted) setState(() => error = e.toString());
                    } finally {
                      if (mounted) setState(() => saving = false);
                    }
                  },
            icon: const Icon(Icons.download),
            label: const Text('Save a copy'),
          ),
        ),
      ],
    ),
  );
}
