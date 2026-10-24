import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easyprivacy_files/transfer/file_selection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('org.easyprivacy/files_storage');
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  test(
    'Android uses actual staged bytes regardless of document size metadata',
    () async {
      final root = await Directory.systemTemp.createTemp('ep-selection-test-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/payload');
      await file.writeAsBytes(List.generate(2 * 1024 * 1024, (i) => i % 251));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'pickFile');
            return {'path': file.path, 'name': 'chosen.bin', 'size': 0};
          });
      final source = (await pickTransferSource(useAndroid: true))!;
      expect(source.name, 'chosen.bin');
      expect(source.size, 2 * 1024 * 1024);
      var total = 0;
      await for (final chunk in source.read(0, null)) {
        expect(chunk.length, lessThanOrEqualTo(64 * 1024));
        total += chunk.length;
      }
      expect(total, source.size);
    },
  );
  test('cancelling the Android picker returns no source', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    expect(await pickTransferSource(useAndroid: true), isNull);
  });
}
