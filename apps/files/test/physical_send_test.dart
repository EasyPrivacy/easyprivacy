import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:easyprivacy_files/providers/device_transfer_provider.dart';
import 'package:easyprivacy_files/transfer/file_store.dart';
import 'package:easyprivacy_files/transfer/send_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'physical Files Send through the paired Core brokers',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'easyprivacy-send-physical-',
      );
      final provider = DeviceTransferProvider(
        autoStart: false,
        storeFactory: () async =>
            TransferFileStore(Directory('${root.path}/received')),
      );
      final mib =
          int.tryParse(Platform.environment['EP_SEND_MIB'] ?? '8') ?? -1;
      if (mib != 4 && mib != 8) {
        throw StateError('EP_SEND_MIB must be 4 or 8.');
      }
      final size = mib * 1024 * 1024;
      addTearDown(() async {
        await provider.setReceiving(false);
        provider.dispose();
        if (root.absolute.parent.path != Directory.systemTemp.absolute.path ||
            !root.path
                .split(Platform.pathSeparator)
                .last
                .startsWith('easyprivacy-send-physical-')) {
          throw StateError('Unexpected physical-test cleanup path.');
        }
        await root.delete(recursive: true);
      });
      final file = File('${root.path}/fixture.bin');
      final handle = await file.open(mode: FileMode.write);
      final chunk = List.generate(64 * 1024, (i) => i % 251);
      for (var n = 0; n < size ~/ chunk.length; n++) {
        await handle.writeFrom(chunk);
      }
      await handle.close();
      final expected = await sha256.bind(file.openRead()).first;
      await provider.initialize();
      expect(provider.connected, isTrue, reason: provider.error);
      final receive = Platform.environment['EP_SEND_MODE'] == 'receive';
      if (receive) {
        provider.addListener(() {
          for (final job in provider.jobs.where(
            (j) => j.phase == TransferPhase.approval && j.incoming,
          )) {
            if (job.name.startsWith('easyprivacy-send-test-') &&
                job.size == size) {
              provider.accept(job, true);
            }
          }
        });
        await provider.setReceiving(true);
        expect(provider.receiving, isTrue, reason: provider.error);
        // ignore: avoid_print
        print('EP_FILES_RECEIVER_READY');
        final deadline = DateTime.now().add(const Duration(minutes: 8));
        while (!provider.jobs.any((j) => j.phase == TransferPhase.complete) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        final job = provider.jobs
            .where((j) => j.phase == TransferPhase.complete)
            .single;
        expect(
          await sha256.bind(job.record!.completed.openRead()).first,
          expected,
        );
      } else {
        final peers = provider.devices.where((d) => d.online).toList();
        expect(
          peers.length,
          1,
          reason: 'Enable receiving only on the test phone.',
        );
        // ignore: avoid_print
        print('EP_FILES_SENDING_TEST_OFFER');
        await provider.send(
          TransferSource(
            name:
                'easyprivacy-send-test-${DateTime.now().millisecondsSinceEpoch}.bin',
            size: size,
            read: (start, end) => file.openRead(start, end),
          ),
          peers.single,
        );
        final job = provider.jobs.first;
        expect(job.phase, TransferPhase.complete, reason: job.message);
      }
      // ignore: avoid_print
      print(
        'PHYSICAL_FILES_SEND_PASS: ${receive ? 'phone to laptop' : 'laptop to phone'}, $mib MiB, verified receipt.',
      );
    },
    skip:
        !Platform.isWindows ||
        Platform.environment['EP_PHYSICAL_SEND_TEST'] != '1',
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
