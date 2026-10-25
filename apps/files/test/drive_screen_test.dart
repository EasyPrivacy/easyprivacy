import 'package:easyprivacy_files/drive/drive_client.dart';
import 'package:easyprivacy_files/screens/drive_screen.dart';
import 'package:easyprivacy_protocol/easyprivacy_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class CatalogDrive extends DriveClient {
  int downloads = 0;
  final changes = <DriveCommand>[];
  static const id = '11111111111111111111111111111111';
  @override
  Future<List<DriveNode>> nodes() async => [
    const DriveNode('receiver.test', 'node', 'My storage node'),
  ];
  @override
  Future<List<DriveVolume>> volumes(DriveNode node) async => [
    DriveVolume.fromJson({
      'id': id,
      'name': 'Cloud files',
      'quota': 1024,
      'used': 9,
      'reserved': 0,
      'available': true,
    }),
  ];
  @override
  Future<(List<DriveEntry>, String)> list(
    DriveNode node,
    String volume,
    String path, {
    String cursor = '',
  }) async => (
    changes.isEmpty
        ? [
            DriveEntry.fromJson({
              'name': 'notes.md',
              'directory': false,
              'size': 9,
              'modified': '2026-10-24T18:00:00Z',
            }),
          ]
        : <DriveEntry>[],
    '',
  );
  @override
  Future<void> change(DriveNode node, DriveCommand command) async {
    changes.add(command);
  }

  @override
  Future<DriveDownload> download(
    DriveNode node,
    String volume,
    String path, {
    int limit = maxDriveFileBytes,
    void Function(int, int)? progress,
  }) async {
    downloads++;
    throw StateError('Metadata browsing must not download content.');
  }
}

void main() {
  testWidgets(
    'Drive fits on a phone, browses only metadata and confirms cloud deletion',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final client = CatalogDrive();
      addTearDown(client.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DriveScreen(client: client)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('notes.md'), findsOneWidget);
      expect(find.text('Upload file'), findsOneWidget);
      expect(client.downloads, 0);
      await tester.ensureVisible(find.byTooltip('Cloud file actions'));
      await tester.tap(find.byTooltip('Cloud file actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete from Drive'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Delete notes.md from Drive?'), findsOneWidget);
      expect(client.changes, isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(client.changes, isEmpty);
      await tester.tap(find.byTooltip('Cloud file actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete from Drive'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.widgetWithText(FilledButton, 'Delete from Drive'));
      await tester.pumpAndSettle();
      expect(client.changes.single.op, 'delete');
      expect(client.changes.single.path, 'notes.md');
      expect(client.downloads, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
