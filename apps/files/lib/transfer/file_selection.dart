import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'secure_channel.dart';
import 'send_engine.dart';

/// Android's picker returns only a streamed private cache copy, never payload
/// bytes in a platform message. Its actual filesystem length is authoritative;
/// document providers may omit or misreport their SIZE column.
Future<TransferSource?> pickTransferSource({bool? useAndroid}) async {
  if (useAndroid ?? Platform.isAndroid) {
    final selected = await const MethodChannel(
      'org.easyprivacy/files_storage',
    ).invokeMapMethod<String, dynamic>('pickFile');
    if (selected == null) return null;
    final path = selected['path'], name = selected['name'];
    if (path is! String || name is! String || !File(path).isAbsolute) {
      throw const TransferFailure('The selected file could not be prepared.');
    }
    final file = File(path);
    return TransferSource(
      name: name,
      size: await file.length(),
      read: (start, end) => file.openRead(start, end),
    );
  }
  final file = await openFile();
  if (file == null) return null;
  return TransferSource(
    name: file.name,
    size: await file.length(),
    read: (start, end) => file.openRead(start, end),
  );
}
