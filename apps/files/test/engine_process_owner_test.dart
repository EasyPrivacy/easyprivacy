import 'dart:io';
import 'package:easyprivacy_files/sync/engine_process_owner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'closing the Files job terminates its own engine child',
    () async {
      final child = await Process.start('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        'Start-Sleep -Seconds 120',
      ]);
      EngineProcessOwner? owner;
      try {
        owner = EngineProcessOwner(child.pid);
        owner.close();
        await child.exitCode.timeout(const Duration(seconds: 5));
      } finally {
        owner?.close();
        child.kill();
        await child.stdout.drain<void>();
        await child.stderr.drain<void>();
      }
    },
    skip: !Platform.isWindows,
  );
}
