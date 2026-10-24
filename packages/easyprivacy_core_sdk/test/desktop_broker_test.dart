import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:easyprivacy_core_sdk/easyprivacy_core_sdk.dart';

void main() {
  test(
    'local broker authenticates the registry token and bounds capability operations',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'easyprivacy-broker-test-',
      );
      var calls = 0;
      final host = DesktopBrokerHost(
        directory: directory.path,
        handler: (capability, method, args) async {
          calls++;
          if (capability != 'vpn' || method != 'getSummary') {
            throw const BrokerException('not_authorized', 'Denied');
          }
          return {'protocol': 1, 'has_session': true};
        },
      );
      addTearDown(() async {
        await host.close();
        await directory.delete(recursive: true);
      });
      expect(await host.start(), isTrue);
      final client = DesktopBrokerClient(
        capability: 'vpn',
        directory: directory.path,
      );
      expect((await client.call('getSummary', {}))['has_session'], isTrue);
      expect(calls, 1);
      await expectLater(
        client.call('signOwnerChallenge', {}),
        throwsA(isA<BrokerException>()),
      );
      final config =
          jsonDecode(await File('${directory.path}/broker.json').readAsString())
              as Map;
      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      final request = await http.postUrl(
        Uri.parse(config['endpoint'] as String).replace(path: '/v1/rpc'),
      );
      request.write('{}');
      final response = await request.close();
      expect(response.statusCode, 403);
      await response.drain<void>();
      expect(calls, 2);
    },
  );
  test('UTF-8 payload limits apply on both sides of the connection', () async {
    final directory = await Directory.systemTemp.createTemp(
      'easyprivacy-broker-limit-test-',
    );
    var calls = 0;
    final host = DesktopBrokerHost(
      directory: directory.path,
      handler: (_, _, _) async {
        calls++;
        return {};
      },
    );
    addTearDown(() async {
      await host.close();
      await directory.delete(recursive: true);
    });
    await host.start();
    final client = DesktopBrokerClient(
      capability: 'vpn',
      directory: directory.path,
    );
    final oversized = '🔒' * 5000;
    await expectLater(
      client.call('getSummary', {'data': oversized}),
      throwsA(
        isA<BrokerException>().having((e) => e.code, 'code', 'invalid_request'),
      ),
    );
    final config =
        jsonDecode(await File('${directory.path}/broker.json').readAsString())
            as Map;
    final http = HttpClient();
    addTearDown(() => http.close(force: true));
    final request = await http.postUrl(
      Uri.parse(config['endpoint'] as String).replace(path: '/v1/rpc'),
    );
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${config['token']}',
    );
    request.headers.contentType = ContentType.json;
    final bytes = utf8.encode(
      jsonEncode({
        'protocol': 1,
        'capability': 'vpn',
        'method': 'getSummary',
        'arguments': {'data': oversized},
      }),
    );
    request.contentLength = bytes.length;
    request.add(bytes);
    final response = await request.close();
    expect(response.statusCode, 400);
    await response.drain<void>();
    expect(calls, 0);
  });
  test(
    'oversized results and remote errors cannot exceed the reply budget',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'easyprivacy-broker-reply-test-',
      );
      final host = DesktopBrokerHost(
        directory: directory.path,
        handler: (_, method, _) async {
          if (method == 'error') {
            throw BrokerException('remote_error', '🔒' * 5000);
          }
          return {'data': '🔒' * 5000};
        },
      );
      addTearDown(() async {
        await host.close();
        await directory.delete(recursive: true);
      });
      await host.start();
      final client = DesktopBrokerClient(
        capability: 'vpn',
        directory: directory.path,
      );
      for (final method in ['result', 'error']) {
        await expectLater(
          client.call(method, {}),
          throwsA(
            isA<BrokerException>().having(
              (e) => e.code,
              'code',
              'invalid_response',
            ),
          ),
        );
      }
    },
  );
  test('timed-out work retains its slot until completion', () async {
    final directory = await Directory.systemTemp.createTemp(
      'easyprivacy-broker-concurrency-test-',
    );
    final blocked = Completer<Map<String, dynamic>>();
    final allStarted = Completer<void>();
    var calls = 0;
    final host = DesktopBrokerHost(
      directory: directory.path,
      operationTimeout: const Duration(milliseconds: 500),
      handler: (_, method, _) {
        if (method != 'hold') return Future.value({'ready': true});
        calls++;
        if (calls == 16) allStarted.complete();
        return blocked.future;
      },
    );
    addTearDown(() async {
      if (!blocked.isCompleted) blocked.complete({});
      await host.close();
      await directory.delete(recursive: true);
    });
    await host.start();
    final client = DesktopBrokerClient(
      capability: 'vpn',
      directory: directory.path,
    );
    final waiting = List.generate(16, (_) async {
      try {
        await client.call('hold', {});
        return 'unexpected_success';
      } on BrokerException catch (e) {
        return e.code;
      }
    });
    await allStarted.future.timeout(const Duration(seconds: 5));
    expect(await Future.wait(waiting), everyElement('core_timeout'));
    await expectLater(
      client.call('getSummary', {}),
      throwsA(
        isA<BrokerException>().having((e) => e.code, 'code', 'core_busy'),
      ),
    );
    blocked.complete({});
    await Future<void>.delayed(Duration.zero);
    expect((await client.call('getSummary', {}))['ready'], isTrue);
    expect(calls, 16);
  });
}
