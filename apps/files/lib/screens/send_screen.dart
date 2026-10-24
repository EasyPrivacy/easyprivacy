import 'dart:async';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../providers/device_transfer_provider.dart';
import '../transfer/secure_channel.dart';
import '../transfer/file_selection.dart';

String fileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB';
}

class SendScreen extends StatefulWidget {
  const SendScreen({super.key, required this.provider});
  final DeviceTransferProvider provider;
  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen> {
  String? _device;
  bool _picking = false;
  final Set<TransferJob> _saving = {};
  DeviceTransferProvider get transfers => widget.provider;

  Future<void> _pick(SendDevice peer) async {
    setState(() => _picking = true);
    try {
      final source = await pickTransferSource();
      if (source == null || !mounted) return;
      if (!mounted) return;
      unawaited(transfers.send(source, peer));
    } catch (e) {
      if (mounted) _message(e.toString());
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _message(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  Future<void> _save(TransferJob job) async {
    setState(() => _saving.add(job));
    try {
      final file = job.record!.completed;
      if (!await file.exists()) {
        throw const TransferFailure(
          'This received copy has expired. Ask the sender to resend it.',
        );
      }
      if (Platform.isAndroid) {
        final saved = await const MethodChannel('org.easyprivacy/files_storage')
            .invokeMethod<bool>('saveReceived', {
              'path': file.path,
              'name': job.name,
            });
        if (saved != true) return;
      } else {
        final location = await getSaveLocation(suggestedName: job.name);
        if (location == null || !mounted) return;
        final destination = File(location.path);
        if (await destination.exists()) {
          if (!mounted) return;
          final replace = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Replace the existing file?'),
              content: const Text(
                'A file already exists at the location you chose.',
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
          );
          if (replace != true) return;
        }
        final temporary = File(
          '${destination.parent.path}${Platform.pathSeparator}.easyprivacy-${randomTransferNonce()}.part',
        );
        try {
          await file.copy(temporary.path);
          await temporary.rename(destination.path);
        } finally {
          if (await temporary.exists()) await temporary.delete();
        }
      }
      await transfers.saved(job);
      if (mounted) _message('File saved.');
    } catch (e) {
      if (mounted) _message('Could not save the file: $e');
    } finally {
      if (mounted) setState(() => _saving.remove(job));
    }
  }

  String _phase(TransferJob job) => switch (job.phase) {
    TransferPhase.preparing => 'Preparing file…',
    TransferPhase.approval =>
      job.incoming ? 'Accept this file?' : 'Waiting for recipient approval…',
    TransferPhase.transferring =>
      'Transferring · ${fileSize(job.bytes)} / ${fileSize(job.size)}',
    TransferPhase.complete => job.saved ? 'Saved' : 'Verified',
    TransferPhase.interrupted => 'Interrupted',
    TransferPhase.cancelled => 'Cancelled',
    TransferPhase.declined => 'Declined',
  };
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: transfers,
    builder: (context, _) {
      final selected = transfers.devices.where(
        (d) => d.id == _device && d.online,
      );
      return ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Send to a device',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          const Text(
            'Send a file to an online paired device. The recipient approves every transfer.',
          ),
          const SizedBox(height: 12),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Receive files'),
            subtitle: const Text('Keep Files open while sending or receiving.'),
            value: transfers.receiving,
            onChanged: (value) => unawaited(transfers.setReceiving(value)),
          ),
          if (transfers.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                transfers.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Row(
            children: [
              Expanded(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: selected.isEmpty ? null : _device,
                  hint: const Text('Choose a receiving device'),
                  items: transfers.devices
                      .map(
                        (d) => DropdownMenuItem(
                          value: d.id,
                          enabled: d.online,
                          child: Text(
                            d.online
                                ? d.name
                                : '${d.name} · Open Files to receive',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: transfers.busy
                      ? null
                      : (id) => setState(() => _device = id),
                ),
              ),
              IconButton(
                tooltip: 'Refresh devices',
                onPressed: transfers.refreshing ? null : transfers.refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          if (transfers.devices.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Paired devices appear here. Enable receiving in Files on the other device.',
              ),
            ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: selected.isEmpty || transfers.busy || _picking
                ? null
                : () => _pick(selected.single),
            icon: const Icon(Icons.attach_file),
            label: const Text('Choose file and send'),
          ),
          const SizedBox(height: 20),
          const Text(
            'Save received files to keep them. Files clears received and partial copies older than 24 hours when it opens. Retry a failed send to resume. If a cancellation cannot reach the other device, its partial copy expires with the other retained files.',
          ),
          const SizedBox(height: 16),
          ...transfers.jobs.map(
            (job) => Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      job.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      '${job.incoming ? 'From' : 'To'} ${job.peer.name} · ${fileSize(job.size)}',
                    ),
                    const SizedBox(height: 10),
                    Text(_phase(job)),
                    if (job.phase == TransferPhase.transferring)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: LinearProgressIndicator(
                          value: job.size == 0 ? 1 : job.bytes / job.size,
                        ),
                      ),
                    if (job.message != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(job.message!),
                      ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (job.incoming &&
                            job.phase == TransferPhase.approval) ...[
                          FilledButton(
                            onPressed: () => transfers.accept(job, true),
                            child: const Text('Accept file'),
                          ),
                          TextButton(
                            onPressed: () => transfers.accept(job, false),
                            child: const Text('Decline'),
                          ),
                        ] else if (job.active)
                          TextButton(
                            onPressed: () => transfers.cancel(job),
                            child: const Text('Cancel transfer'),
                          ),
                        if (job.incoming &&
                            job.phase == TransferPhase.complete &&
                            job.record != null)
                          FilledButton.icon(
                            onPressed: _saving.contains(job)
                                ? null
                                : () => _save(job),
                            icon: const Icon(Icons.save_alt),
                            label: const Text('Save a copy'),
                          ),
                        if (!job.incoming &&
                            job.source != null &&
                            {
                              TransferPhase.interrupted,
                              TransferPhase.cancelled,
                            }.contains(job.phase))
                          OutlinedButton(
                            onPressed: transfers.busy
                                ? null
                                : () => transfers.send(job.source!, job.peer),
                            child: const Text('Retry'),
                          ),
                        if (!job.active)
                          TextButton(
                            onPressed: _saving.contains(job)
                                ? null
                                : () => transfers.remove(job),
                            child: Text(
                              job.record == null ? 'Dismiss' : 'Remove copy',
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}
