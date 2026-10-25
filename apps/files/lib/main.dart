import 'dart:convert';
import 'dart:io';
import 'package:easyprivacy_core_sdk/easyprivacy_core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'app.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  const diagnosticPrefix = '--diagnose-core=';
  final diagnostic = arguments.where((arg) => arg.startsWith(diagnosticPrefix));
  if (Platform.isWindows && diagnostic.isNotEmpty) {
    final report = <String, Object?>{
      'executable': Platform.resolvedExecutable,
      'appData': Platform.environment['APPDATA'],
      'home': Platform.environment['HOME'],
    };
    var status = 1;
    try {
      final directory = desktopBrokerDirectory();
      report['brokerDirectory'] = directory;
      report['registryExists'] = await File('$directory/broker.json').exists();
      final client = DesktopBrokerClient(capability: 'files');
      final summary = await client.call('getSummary', {});
      report['protocol'] = summary['protocol'];
      report['hasSession'] = summary['has_session'];
      final privateStatus = await client.call('privateStatus', {});
      report['privateActive'] = privateStatus['active'];
      status = 0;
    } on BrokerException catch (error) {
      report['errorCode'] = error.code;
      report['error'] = error.message;
    } catch (error) {
      report['error'] = error.toString();
    }
    await File(
      diagnostic.first.substring(diagnosticPrefix.length),
    ).writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
      flush: true,
    );
    exit(status);
  }
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Syncthing',
    ], await rootBundle.loadString('assets/sync-engine-licenses.txt'));
  });
  runApp(const EasyPrivacyFilesApp());
}
