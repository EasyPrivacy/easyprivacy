// Explicit operator command, excluded from the normal app test directories.
// Uses the same authenticated, recipient-approved Send implementation as Files.
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as paths;
import 'package:easyprivacy_files/providers/device_transfer_provider.dart';
import 'package:easyprivacy_files/transfer/file_store.dart';
import 'package:easyprivacy_files/transfer/send_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'deliver an explicitly selected APK through approved Send',
    () async {
      final root = await Directory.systemTemp.createTemp('ep-apk-delivery-');
      final provider = DeviceTransferProvider(
        autoStart: false,
        storeFactory: () async =>
            TransferFileStore(Directory('${root.path}/received')),
      );
      addTearDown(() async {
        await provider.setReceiving(false);
        provider.dispose();
        if (root.absolute.parent.path != Directory.systemTemp.absolute.path ||
            !paths.basename(root.path).startsWith('ep-apk-delivery-')) {
          throw StateError('Unexpected delivery staging path');
        }
        await root.delete(recursive: true);
      });
      final value = Platform.environment['EP_FILES_APK'];
      if (value == null ||
          !paths.isAbsolute(value) ||
          !value.toLowerCase().endsWith('.apk')) {
        throw StateError(
          'Set EP_FILES_APK to the built APK explicitly authorized for delivery.',
        );
      }
      final file = File(await File(value).resolveSymbolicLinks());
      final size = await file.length();
      final checksum = await sha256.bind(file.openRead()).first;
      await provider.initialize();
      final connectionDeadline = DateTime.now().add(const Duration(minutes: 1));
      while (!provider.connected &&
          DateTime.now().isBefore(connectionDeadline)) {
        await Future<void>.delayed(const Duration(seconds: 3));
        await provider.refresh();
      }
      expect(provider.connected, isTrue, reason: provider.error);
      final recipient = Platform.environment['EP_FILES_RECIPIENT'];
      final deadline = DateTime.now().add(const Duration(minutes: 10));
      SendDevice? peer;
      while (DateTime.now().isBefore(deadline)) {
        final peers = (await provider.pairedDevices())
            .where((d) => d.online && (recipient == null || d.id == recipient))
            .toList();
        if (peers.length > 1) {
          throw StateError(
            'More than one recipient is available; specify EP_FILES_RECIPIENT.',
          );
        }
        if (peers.length == 1) {
          peer = peers.single;
          break;
        }
        await Future<void>.delayed(const Duration(seconds: 3));
      }
      expect(
        peer,
        isNotNull,
        reason: 'Open Files and enable Receive files on the intended phone.',
      );
      // ignore: avoid_print
      print(
        'APK_OFFER: ${paths.basename(file.path)}, $size bytes, SHA256 $checksum, recipient ${peer!.name}.',
      );
      TransferPhase? lastPhase;
      var lastStep = -1;
      provider.addListener(() {
        if (provider.jobs.isEmpty) return;
        final job = provider.jobs.first;
        final step = job.size == 0 ? 10 : job.bytes * 10 ~/ job.size;
        if (job.phase == lastPhase && step == lastStep) return;
        lastPhase = job.phase;
        lastStep = step;
        // ignore: avoid_print
        print(
          'APK_PROGRESS: ${job.phase.name}, ${job.bytes}/${job.size} bytes.',
        );
      });
      await provider.send(
        TransferSource(
          name: paths.basename(file.path),
          size: size,
          read: (start, end) => file.openRead(start, end),
        ),
        peer,
      );
      expect(
        provider.jobs.first.phase,
        TransferPhase.complete,
        reason: provider.jobs.first.message,
      );
      // ignore: avoid_print
      print('APK_DELIVERED: recipient verified the complete file.');
    },
    skip: Platform.environment['EP_FILES_DELIVER_APK'] != '1',
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
