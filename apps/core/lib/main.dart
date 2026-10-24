import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:easyprivacy_core_sdk/easyprivacy_core_sdk.dart';
import 'package:easyprivacy_protocol/easyprivacy_protocol.dart';
import 'app.dart';
import 'runtime/broker/core_broker_runtime.dart';
export 'app.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isAndroid && args.contains('--core-broker')) {
    final runtime = CoreBrokerRuntime();
    final host = DesktopBrokerHost(handler: runtime.handle);
    if (!await host.start()) exit(0);
    return;
  }
  if (Platform.isWindows || Platform.isLinux) {
    unawaited(
      Process.start(
        Platform.resolvedExecutable,
        ['--core-broker'],
        mode: ProcessStartMode.detached,
      ).then<void>((_) {}).catchError((Object _) {}),
    );
  }
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'EasyPrivacy native dependencies',
    ], await rootBundle.loadString('assets/native-licenses.txt'));
  });
  runApp(const EasyPrivacyApp());
}

@pragma('vm:entry-point')
Future<void> coreBrokerMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  final runtime = CoreBrokerRuntime();
  const channel = MethodChannel('org.easyprivacy/core_host');
  channel.setMethodCallHandler((call) async {
    if (call.method == 'shutdown') {
      await runtime.shutdown();
      return null;
    }
    if (call.method != 'rpc') throw MissingPluginException();
    try {
      final payload = Map<String, dynamic>.from(call.arguments as Map);
      return await runtime.handle(
        payload['capability'] as String,
        payload['method'] as String,
        Map<String, dynamic>.from(payload['arguments'] as Map),
      );
    } on BrokerException catch (e) {
      throw PlatformException(code: e.code, message: e.message);
    } on CoreException catch (e) {
      throw PlatformException(
        code: e.statusCode == 401 ? 'revoked' : 'core_error',
        message: e.message,
      );
    } catch (_) {
      throw PlatformException(
        code: 'core_error',
        message: 'Core could not complete the operation.',
      );
    }
  });
  await channel.invokeMethod<void>('ready');
}
