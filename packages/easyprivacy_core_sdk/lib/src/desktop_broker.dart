import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'broker_transport.dart';

const _payloadLimit = 16 * 1024;
const _requestLimit = 16;

String desktopBrokerDirectory() {
  final base = Platform.isWindows
      ? Platform.environment['APPDATA']
      : Platform.environment['XDG_RUNTIME_DIR'];
  if (base != null && base.isNotEmpty) return '$base/EasyPrivacy/Core';
  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) {
    throw const BrokerException(
      'core_unavailable',
      'No user runtime directory is available.',
    );
  }
  return '$home/.local/share/EasyPrivacy/Core';
}

/// Desktop authority is the OS user, unlike Android's per-package signature gate.
/// This token authorizes local capability calls, never remote owner operations.
class DesktopBrokerClient {
  DesktopBrokerClient({required this.capability, this.directory});
  final String capability;
  final String? directory;
  Future<Map<String, dynamic>> call(
    String method,
    Map<String, Object?> arguments,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final registry = File(
        '${directory ?? desktopBrokerDirectory()}/broker.json',
      );
      if (!await registry.exists()) {
        throw const BrokerException(
          'core_unavailable',
          'Open EasyPrivacy Core on this device first.',
        );
      }
      if (await registry.length() > 2048) throw const FormatException();
      final text = await registry.readAsString();
      final config = jsonDecode(text) as Map;
      final endpoint = Uri.parse(config['endpoint'] as String);
      final token = config['token'] as String;
      if (endpoint.scheme != 'http' ||
          endpoint.host != '127.0.0.1' ||
          endpoint.port < 1 ||
          token.length < 32 ||
          token.length > 128) {
        throw const FormatException();
      }
      return await (() async {
        final body = utf8.encode(
          jsonEncode({
            'protocol': 1,
            'capability': capability,
            'method': method,
            'arguments': arguments,
          }),
        );
        if (body.length > _payloadLimit) {
          throw const BrokerException(
            'invalid_request',
            'Core request is too large.',
          );
        }
        final request = await client.postUrl(endpoint.replace(path: '/v1/rpc'));
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        request.headers.contentType = ContentType.json;
        request.contentLength = body.length;
        request.add(body);
        final response = await request.close();
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > _payloadLimit) {
            throw const FormatException();
          }
          bytes.addAll(chunk);
        }
        final result = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        if (response.statusCode != 200) {
          throw BrokerException(
            result['code'] as String? ?? 'core_error',
            result['error'] as String? ?? 'Core rejected the operation.',
          );
        }
        return result;
      })().timeout(const Duration(seconds: 20));
    } on BrokerException {
      rethrow;
    } on SocketException {
      throw const BrokerException(
        'core_unavailable',
        'Core is not running. Open EasyPrivacy Core and try again.',
      );
    } on TimeoutException {
      throw const BrokerException(
        'core_timeout',
        'Core did not respond in time. Try again.',
      );
    } on HttpException {
      throw const BrokerException(
        'core_unavailable',
        'Core closed the connection. Reopen Core and try again.',
      );
    } on FormatException {
      throw const BrokerException(
        'core_unavailable',
        'Core connection information is invalid. Reopen Core.',
      );
    } finally {
      client.close(force: true);
    }
  }
}

typedef BrokerHandler =
    Future<Map<String, dynamic>> Function(
      String capability,
      String method,
      Map<String, dynamic> arguments,
    );

class DesktopBrokerHost {
  DesktopBrokerHost({
    required this.handler,
    this.directory,
    this.operationTimeout = const Duration(seconds: 20),
  });
  final BrokerHandler handler;
  final String? directory;
  final Duration operationTimeout;
  HttpServer? _server;
  RandomAccessFile? _lock;
  String? _registry, _token;
  int _activeRequests = 0;
  Future<bool> start() async {
    final dir = Directory(directory ?? desktopBrokerDirectory());
    await dir.create(recursive: true);
    final principal =
        '${Platform.environment['USERDOMAIN'] ?? '.'}\\${Platform.environment['USERNAME'] ?? ''}';
    final secured = Platform.isWindows
        ? await Process.run('icacls', [
            dir.path,
            '/inheritance:r',
            '/grant:r',
            '$principal:(OI)(CI)F',
          ])
        : await Process.run('chmod', ['700', dir.path]);
    if (secured.exitCode != 0) {
      throw const BrokerException(
        'storage_error',
        'Could not protect the Core runtime directory.',
      );
    }
    _lock = await File('${dir.path}/broker.lock').open(mode: FileMode.append);
    try {
      await _lock!.lock(FileLock.exclusive);
    } on FileSystemException {
      await _lock!.close();
      _lock = null;
      return false;
    }
    _token = base64UrlEncode(
      List.generate(32, (_) => Random.secure().nextInt(256)),
    );
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final registry = File('${dir.path}/broker.json');
    _registry = registry.path;
    await registry.writeAsString(
      jsonEncode({
        'endpoint': 'http://127.0.0.1:${_server!.port}',
        'token': _token,
      }),
      flush: true,
    );
    _server!.listen(_handle);
    return true;
  }

  Future<void> _handle(HttpRequest request) async {
    var status = 200;
    var admitted = false;
    String response;
    try {
      if (request.headers.value(HttpHeaders.authorizationHeader) !=
          'Bearer $_token') {
        throw const BrokerException(
          'not_authorized',
          'Core connection is not authorized.',
        );
      }
      if (request.method != 'POST' || request.uri.path != '/v1/rpc') {
        throw const BrokerException(
          'invalid_request',
          'Invalid Core operation.',
        );
      }
      if (request.contentLength > _payloadLimit) {
        throw const BrokerException(
          'invalid_request',
          'Core request is too large.',
        );
      }
      if (_activeRequests >= _requestLimit) {
        throw const BrokerException(
          'core_busy',
          'Core is handling too many requests. Try again.',
        );
      }
      _activeRequests++;
      admitted = true;
      final bytes = <int>[];
      await for (final chunk in request.timeout(const Duration(seconds: 5))) {
        if (bytes.length + chunk.length > _payloadLimit) {
          throw const BrokerException(
            'invalid_request',
            'Core request is too large.',
          );
        }
        bytes.addAll(chunk);
      }
      final body = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (body['protocol'] != 1) {
        throw const BrokerException(
          'version_mismatch',
          'Update this application and Core together.',
        );
      }
      final pending = handler(
        body['capability'] as String,
        body['method'] as String,
        Map<String, dynamic>.from(body['arguments'] as Map),
      );
      // A timeout cannot cancel a remote operation. Keep its slot reserved
      // until it actually settles so retries cannot create unbounded work.
      admitted = false;
      unawaited(
        pending.then<void>(
          (_) => _activeRequests--,
          onError: (Object _, StackTrace _) => _activeRequests--,
        ),
      );
      final result = await pending.timeout(operationTimeout);
      response = jsonEncode(result);
      if (utf8.encode(response).length > _payloadLimit) {
        throw const BrokerException(
          'invalid_response',
          'Core response is too large.',
        );
      }
    } on BrokerException catch (e) {
      status = switch (e.code) {
        'not_authorized' => 403,
        'core_busy' => 429,
        'invalid_request' => 400,
        'invalid_response' => 502,
        _ => 409,
      };
      response = jsonEncode({'code': e.code, 'error': e.message});
    } on TimeoutException {
      status = 504;
      response = jsonEncode({
        'code': 'core_timeout',
        'error': 'Core did not respond in time. Try again.',
      });
    } catch (_) {
      status = 400;
      response = jsonEncode({
        'code': 'invalid_request',
        'error': 'Core could not complete this operation.',
      });
    } finally {
      if (admitted) _activeRequests--;
    }
    if (utf8.encode(response).length > _payloadLimit) {
      status = 502;
      response = jsonEncode({
        'code': 'invalid_response',
        'error': 'Core response is too large.',
      });
    }
    try {
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      request.response.write(response);
      await request.response.close();
    } catch (_) {
      /* Caller may close while Core completes a bounded operation. */
    }
  }

  Future<void> close() async {
    await _server?.close(force: true);
    if (_registry != null && _lock != null) {
      final file = File(_registry!);
      if (await file.exists()) await file.delete();
    }
    await _lock?.close();
    _lock = null;
  }
}
