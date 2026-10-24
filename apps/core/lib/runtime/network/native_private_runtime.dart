import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:easyprivacy_core_sdk/easyprivacy_core_sdk.dart';

class NativePrivateRuntime {
  NativePrivateRuntime({this.executablePath});
  final String? executablePath;
  Process? _process;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  int _next = 0;
  StreamSubscription<String>? _output;
  bool get active => _process != null;
  Future<Map<String, dynamic>> start(Map<String, Object?> config) async {
    if (_process != null) {
      throw StateError('Private connection is already running.');
    }
    final path =
        executablePath ??
        Platform.environment['EASYPRIVACY_CORE_RUNTIME'] ??
        (Platform.isAndroid
            ? await const MethodChannel(
                'org.easyprivacy/core_host',
              ).invokeMethod<String>('nativeRuntimePath')
            : '${File(Platform.resolvedExecutable).parent.path}/easyprivacy-core-runtime${Platform.isWindows ? '.exe' : ''}');
    if (path == null || !await File(path).exists()) {
      throw const BrokerException(
        'runtime_missing',
        'This Core build does not contain the private connection runtime.',
      );
    }
    final process = await Process.start(path, [], runInShell: false);
    _process = process;
    _output = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            try {
              if (line.length > 16384) throw const FormatException();
              final value = jsonDecode(line) as Map<String, dynamic>;
              final pending = _pending.remove(value['id']);
              if (value['error'] != null) {
                pending?.completeError(
                  const BrokerException(
                    'private_operation_failed',
                    'The private connection could not complete the operation.',
                  ),
                );
              } else {
                pending?.complete(
                  Map<String, dynamic>.from(value['result'] as Map),
                );
              }
            } catch (_) {
              _fail();
              process.kill();
            }
          },
          onError: (Object _) => _fail(),
          onDone: _fail,
        );
    unawaited(process.stderr.drain<void>());
    unawaited(
      process.exitCode.then((_) {
        if (identical(_process, process)) {
          _process = null;
          _fail();
        }
      }),
    );
    try {
      final result = await call('start', config);
      if (result['protocol'] != 1) {
        throw const BrokerException(
          'version_mismatch',
          'Update Core and its private runtime together.',
        );
      }
      return result;
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  void _fail() {
    final pending = _pending.values.toList();
    _pending.clear();
    for (final request in pending) {
      request.completeError(
        const BrokerException(
          'private_unavailable',
          'The private connection stopped. Start it again in Core.',
        ),
      );
    }
  }

  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, Object?> arguments = const {},
  ]) async {
    final process = _process;
    if (process == null) {
      throw const BrokerException(
        'private_unavailable',
        'Start the private connection in Core first.',
      );
    }
    if (_pending.length >= 16) {
      throw const BrokerException(
        'core_busy',
        'The private connection is busy.',
      );
    }
    final id = ++_next;
    final complete = Completer<Map<String, dynamic>>();
    _pending[id] = complete;
    final result = complete.future.timeout(const Duration(seconds: 15));
    // Attach a listener before flushing: the process can exit while the pipe
    // write is pending. The awaited result below still reports that error.
    unawaited(result.then<void>((_) {}, onError: (Object _) {}));
    try {
      process.stdin.writeln(
        jsonEncode({'id': id, 'method': method, 'arguments': arguments}),
      );
      await process.stdin.flush();
      return await result;
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> stop() async {
    final process = _process;
    _process = null;
    _fail();
    if (process != null) {
      try {
        await process.stdin.close();
        await process.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {
        process.kill();
      }
    }
    await _output?.cancel();
    _output = null;
  }
}
