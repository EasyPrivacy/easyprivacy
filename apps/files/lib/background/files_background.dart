import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as paths;
import 'package:path_provider/path_provider.dart';
import '../providers/folder_sync_provider.dart';

class FilesBackground extends ChangeNotifier {
  FilesBackground(this.sync) {
    sync.addListener(_update);
    unawaited(initialize());
  }
  final FolderSyncProvider sync;
  static const channel = MethodChannel('org.easyprivacy/files_presence');
  bool? choice;
  bool initialized = false;
  String? error;
  File? _file;
  bool? _lastActive;
  bool _disposed = false;
  Future<void> _pending = Future.value();
  Future<void> initialize() async {
    try {
      _file = File(
        paths.join(
          (await getApplicationSupportDirectory()).path,
          'background.json',
        ),
      );
      if (await _file!.exists()) {
        if (await _file!.length() > 4096) {
          throw const FormatException('Invalid background preference.');
        }
        final saved = jsonDecode(await _file!.readAsString()) as Map;
        choice = saved['enabled'] as bool?;
      }
      channel.setMethodCallHandler((call) async {
        if (call.method != 'hostClosing') throw MissingPluginException();
        await sync.shutdown();
        await sync.transfers.setReceiving(false);
      });
      initialized = true;
      _update();
    } catch (e) {
      error = e.toString();
      initialized = true;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> setEnabled(bool enabled) async {
    try {
      if (enabled && Platform.isAndroid) {
        final allowed = await const MethodChannel(
          'org.easyprivacy/files_permission',
        ).invokeMethod<bool>('notifications');
        if (allowed != true) {
          throw PlatformException(
            code: 'notification_required',
            message: 'Allow Files notifications to run in the background.',
          );
        }
      }
      final previous = choice;
      choice = enabled;
      _lastActive = null;
      try {
        await _apply();
      } catch (_) {
        choice = previous;
        rethrow;
      }
      await _file!.parent.create(recursive: true);
      final temp = File('${_file!.path}.tmp');
      await temp.writeAsString(jsonEncode({'enabled': choice}), flush: true);
      await temp.rename(_file!.path);
      error = null;
    } catch (e) {
      error = e is PlatformException ? e.message : e.toString();
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _apply() async {
    final active = choice == true && sync.enabled;
    if (active == _lastActive) return;
    await channel.invokeMethod<void>('update', {'active': active});
    _lastActive = active;
  }

  void _update() {
    if (!initialized || _disposed) return;
    _pending = _pending.then((_) => _apply()).catchError((Object e) {
      error = e is PlatformException ? e.message : e.toString();
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    sync.removeListener(_update);
    channel.setMethodCallHandler(null);
    super.dispose();
  }
}
