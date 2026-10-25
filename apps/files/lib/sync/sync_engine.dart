import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as paths;
import 'package:xml/xml.dart';
import 'engine_process_owner.dart';
import 'sync_paths.dart';
import '../transfer/secure_channel.dart';

const syncEngineVersion = 'v2.1.7';
bool validSyncDevice(String value) =>
    RegExp(r'^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$').hasMatch(value);
bool validSyncFolder(String value) =>
    RegExp(r'^ep-[0-9a-f]{32}$').hasMatch(value);

/// Owns only the bundled engine and its app-private configuration. The engine
/// listens/dials loopback; peer bytes enter Core through Files' bridge.
class SyncEngine {
  SyncEngine({required this.root, this.executable});
  final Directory root;
  final String? executable;
  Process? _process;
  EngineProcessOwner? _owner;
  String? _key, deviceId;
  int? apiPort, syncPort;
  Future<void> _updates = Future.value();
  final List<String> diagnostics = [];
  final Map<String, Directory> _locations = {};
  void registerLocation(String id, Directory directory) {
    if (!validSyncFolder(id) || !directory.isAbsolute) {
      throw const TransferFailure('Invalid synced folder location.');
    }
    _locations[id] = directory;
  }

  bool get running => _process != null && deviceId != null;
  Directory get home => Directory(paths.join(root.path, 'engine'));
  Directory folder(String id) {
    if (!validSyncFolder(id)) {
      throw const TransferFailure('Invalid synced folder.');
    }
    return _locations[id] ?? Directory(paths.join(root.path, 'folders', id));
  }

  Map<String, String> get _environment {
    final values = Map<String, String>.from(Platform.environment);
    values.removeWhere(
      (k, _) =>
          k.startsWith('ST') ||
          {
            'all_proxy',
            'http_proxy',
            'https_proxy',
            'no_proxy',
          }.contains(k.toLowerCase()),
    );
    return {
      ...values,
      'STNODEFAULTFOLDER': '1',
      'STNOUPGRADE': '1',
      'STNORESTART': '1',
      'STNOBROWSER': '1',
      // Files owns the engine directly, without an extra monitor process.
      'STMONITORED': 'yes',
      'ALL_PROXY_NO_FALLBACK': '1',
    };
  }

  Future<String> _path() async {
    final value =
        executable ??
        Platform.environment['EASYPRIVACY_SYNC_ENGINE'] ??
        (Platform.isAndroid
            ? await const MethodChannel(
                'org.easyprivacy/files_storage',
              ).invokeMethod<String>('syncEnginePath')
            : paths.join(
                File(Platform.resolvedExecutable).parent.path,
                'easyprivacy-sync${Platform.isWindows ? '.exe' : ''}',
              ));
    if (value == null || !await File(value).exists()) {
      throw const TransferFailure(
        'This Files build does not contain the Sync engine.',
      );
    }
    return value;
  }

  Future<int> _port() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    await server.close();
    return port;
  }

  Future<void> _protect() async {
    await home.create(recursive: true);
    final result = Platform.isWindows
        ? await Process.run('icacls', [
            root.path,
            '/inheritance:r',
            '/grant:r',
            '${Platform.environment['USERDOMAIN'] ?? '.'}\\${Platform.environment['USERNAME']}:(OI)(CI)F',
          ])
        : await Process.run('chmod', ['700', root.path, home.path]);
    if (result.exitCode != 0) {
      throw const TransferFailure('Could not protect Sync configuration.');
    }
  }

  void _xmlValue(XmlElement parent, String name, String value) {
    parent.children.removeWhere((n) => n is XmlElement && n.name.local == name);
    parent.children.add(XmlElement(XmlName(name), [], [XmlText(value)]));
  }

  void _guardFolder(String id, String path) {
    if (!validSyncFolder(id) ||
        paths.normalize(paths.absolute(path)) !=
            paths.normalize(paths.absolute(folder(id).path))) {
      throw const TransferFailure(
        'Sync configuration contains an unmanaged folder.',
      );
    }
  }

  void _hardenXml(XmlDocument document) {
    final config = document.rootElement;
    final gui = config.getElement('gui')!,
        options = config.getElement('options')!;
    gui.setAttribute('enabled', 'true');
    gui.setAttribute('tls', 'false');
    _xmlValue(gui, 'address', '127.0.0.1:$apiPort');
    _xmlValue(gui, 'apikey', _key!);
    _xmlValue(gui, 'insecureAdminAccess', 'false');
    _xmlValue(gui, 'insecureSkipHostcheck', 'false');
    _xmlValue(options, 'listenAddress', 'tcp://127.0.0.1:$syncPort');
    for (final name in [
      'globalAnnounceEnabled',
      'localAnnounceEnabled',
      'relaysEnabled',
      'natEnabled',
      'startBrowser',
      'crashReportingEnabled',
      'announceLANAddresses',
    ]) {
      _xmlValue(options, name, 'false');
    }
    for (final name in [
      'globalAnnounceServer',
      'stunServer',
      'releasesURL',
      'urURL',
      'crashReportingURL',
    ]) {
      _xmlValue(options, name, '');
    }
    _xmlValue(options, 'stunKeepaliveStartS', '0');
    _xmlValue(options, 'autoUpgradeIntervalH', '0');
    _xmlValue(options, 'urAccepted', '-1');
    _xmlValue(options, 'reconnectionIntervalS', '5');
    _xmlValue(options, 'minHomeDiskFree', '134217728');
    options.getElement('minHomeDiskFree')!.setAttribute('unit', 'B');
    for (final f in config.findElements('folder')) {
      _guardFolder(f.getAttribute('id')!, f.getAttribute('path')!);
      _xmlValue(f, 'paused', 'true');
    }
    for (final d in config.findElements('device')) {
      for (final address in d.findElements('address')) {
        if (!RegExp(
          r'^tcp://127\.0\.0\.1:[1-9][0-9]{0,4}$',
        ).hasMatch(address.innerText)) {
          // Generated self-device records have "dynamic"; never leave it active.
          address.children.clear();
          address.children.add(XmlText('tcp://127.0.0.1:1'));
        }
      }
      d.setAttribute('introducer', 'false');
      d.setAttribute('autoAcceptFolders', 'false');
      _xmlValue(d, 'paused', 'true');
    }
  }

  Future<void> start() async {
    if (running) return;
    final path = await _path();
    await _protect();
    final configFile = File(paths.join(home.path, 'config.xml'));
    if (!await configFile.exists()) {
      final generate = await Process.start(
        path,
        ['--home', home.path, 'generate', '--no-port-probing'],
        environment: _environment,
        includeParentEnvironment: false,
      );
      unawaited(generate.stdout.drain<void>());
      unawaited(generate.stderr.drain<void>());
      final code = await generate.exitCode.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          generate.kill();
          return -1;
        },
      );
      if (code != 0) {
        throw const TransferFailure('Could not initialize the Sync engine.');
      }
    }
    apiPort = await _port();
    syncPort = await _port();
    _key = randomTransferNonce();
    final document = XmlDocument.parse(await configFile.readAsString());
    _hardenXml(document);
    await configFile.writeAsString(
      document.toXmlString(pretty: true),
      flush: true,
    );
    final process = await Process.start(
      path,
      [
        '--home',
        home.path,
        'serve',
        '--no-browser',
        '--no-restart',
        '--no-upgrade',
      ],
      environment: _environment,
      includeParentEnvironment: false,
    );
    try {
      _owner = EngineProcessOwner(process.pid);
    } catch (_) {
      process.kill();
      rethrow;
    }
    _process = process;
    void log(String line) {
      if (diagnostics.length >= 20) diagnostics.removeAt(0);
      diagnostics.add(line.length > 512 ? line.substring(0, 512) : line);
    }

    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(log);
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(log);
    unawaited(
      process.exitCode.then((_) {
        if (identical(_process, process)) {
          _owner?.close();
          _owner = null;
          _process = null;
          deviceId = null;
        }
      }),
    );
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (DateTime.now().isBefore(deadline) && _process != null) {
        try {
          final status = await call('GET', 'system/status');
          final id = (status as Map)['myID'];
          if (id is String && validSyncDevice(id)) {
            deviceId = id;
            break;
          }
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      if (!running) {
        throw const TransferFailure(
          'Sync did not start. Restart it from the Sync tab.',
        );
      }
      final version = await call('GET', 'system/version') as Map;
      if (version['version'] != syncEngineVersion) {
        throw const TransferFailure(
          'Update Files and its Sync engine together.',
        );
      }
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  Future<dynamic> call(
    String method,
    String resource, {
    Object? body,
    Map<String, String>? query,
  }) async {
    if (_process == null || apiPort == null) {
      throw const TransferFailure('Enable Sync first.');
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      return await (() async {
        final request = await client.openUrl(
          method,
          Uri(
            scheme: 'http',
            host: '127.0.0.1',
            port: apiPort,
            path: '/rest/$resource',
            queryParameters: query,
          ),
        );
        request.followRedirects = false;
        request.headers.set('X-API-Key', _key!);
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(body));
        }
        final response = await request.close();
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 1024 * 1024) {
            throw const TransferFailure('Sync returned too much metadata.');
          }
          bytes.addAll(chunk);
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw TransferFailure(
            'Sync request failed (${response.statusCode}).',
          );
        }
        return bytes.isEmpty ? null : jsonDecode(utf8.decode(bytes));
      })().timeout(const Duration(seconds: 15));
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _mutate(void Function(Map<String, dynamic>) update) {
    final pending = _updates.then((_) async {
      final config = Map<String, dynamic>.from(
        await call('GET', 'config') as Map,
      );
      update(config);
      // Settings are reapplied for every mutation; never expose a raw config UI.
      final options = config['options'] as Map;
      options.addAll(<String, dynamic>{
        'listenAddresses': ['tcp://127.0.0.1:$syncPort'],
        'globalAnnounceEnabled': false,
        'localAnnounceEnabled': false,
        'relaysEnabled': false,
        'natEnabled': false,
        'startBrowser': false,
        'crashReportingEnabled': false,
        'urAccepted': -1,
        'autoUpgradeIntervalH': 0,
        'stunServers': <String>[],
        'stunKeepaliveStartS': 0,
        'minHomeDiskFree': {'value': 134217728, 'unit': 'B'},
      });
      for (final f in config['folders'] as List) {
        _guardFolder(f['id'] as String, f['path'] as String);
      }
      for (final d in config['devices'] as List) {
        d['introducer'] = false;
        d['autoAcceptFolders'] = false;
        if ((d['addresses'] as List).any(
          (a) => !RegExp(
            r'^tcp://127\.0\.0\.1:[1-9][0-9]{0,4}$',
          ).hasMatch(a as String),
        )) {
          throw const TransferFailure(
            'Sync tried to use a connection outside the Core bridge.',
          );
        }
      }
      await call('PUT', 'config', body: config);
    });
    _updates = pending.then<void>((_) {}, onError: (Object _) {});
    return pending;
  }

  Future<void> configurePeer(String id, String label, int bridgePort) {
    if (!validSyncDevice(id) ||
        id == deviceId ||
        bridgePort < 1 ||
        bridgePort > 65535) {
      throw const TransferFailure('Invalid Sync peer.');
    }
    return _mutate((config) {
      final devices = config['devices'] as List;
      final existing = devices.where((d) => d['deviceID'] == id);
      final entry = existing.isEmpty
          ? Map<String, dynamic>.from(
              (config['defaults'] as Map)['device'] as Map,
            )
          : existing.single as Map;
      entry.addAll(<String, dynamic>{
        'deviceID': id,
        'name': label,
        'addresses': ['tcp://127.0.0.1:$bridgePort'],
        'paused': false,
        'introducer': false,
        'autoAcceptFolders': false,
        'numConnections': 1,
      });
      if (existing.isEmpty) devices.add(entry);
    });
  }

  Future<void> configureFolder(
    String id,
    String label,
    String peer, {
    bool paused = false,
    Iterable<String>? peers,
    SyncSelection? selection,
  }) async {
    final directory = folder(id);
    if (_locations.containsKey(id)) {
      await syncLocalPath(directory, '');
    } else {
      await directory.create(recursive: true);
    }
    final members = {...?peers, peer};
    if (members.any((id) => !validSyncDevice(id))) {
      throw const TransferFailure('Invalid Sync peer.');
    }
    // New selective replicas must be paused until their ignore policy is saved.
    await _mutate((config) {
      final folders = config['folders'] as List;
      final existing = folders.where((f) => f['id'] == id);
      final entry = existing.isEmpty
          ? Map<String, dynamic>.from(
              (config['defaults'] as Map)['folder'] as Map,
            )
          : existing.single as Map;
      entry.addAll(<String, dynamic>{
        'id': id,
        'label': label,
        'path': directory.path,
        'type': 'sendreceive',
        'filesystemType': 'basic',
        'devices': [
          {'deviceID': deviceId},
          for (final member in members) {'deviceID': member},
        ],
        'paused': selection == null ? paused : true,
        'ignorePerms': true,
        'rescanIntervalS': 30,
        'fsWatcherEnabled': true,
        'fsWatcherDelayS': 1,
        'minDiskFree': {'value': 268435456, 'unit': 'B'},
        'versioning': {
          'type': 'simple',
          'params': {'keep': '5'},
          'cleanupIntervalS': 3600,
        },
      });
      if (existing.isEmpty) folders.add(entry);
    });
    if (selection != null) {
      await setSelection(id, selection);
      if (!paused) {
        await _mutate((config) {
          for (final f in config['folders'] as List) {
            if (f['id'] == id) f['paused'] = false;
          }
        });
      }
    }
  }

  Future<void> setSelection(String id, SyncSelection selection) async {
    await call(
      'POST',
      'db/ignores',
      query: {'folder': id},
      body: {'ignore': selection.ignorePatterns},
    );
  }

  Future<List<Map<String, dynamic>>> browse(String id, String relative) async {
    syncRelative(relative, allowRoot: true);
    final result = await call(
      'GET',
      'db/browse',
      query: {'folder': id, 'prefix': relative, 'levels': '0'},
    );
    if (result is! List) {
      throw const TransferFailure('Invalid Sync directory index.');
    }
    return result.map((v) => Map<String, dynamic>.from(v as Map)).toList();
  }

  Future<Map<String, dynamic>> status(String id) async =>
      Map<String, dynamic>.from(
        await call('GET', 'db/status', query: {'folder': id}) as Map,
      );
  Future<void> scan(String id) async {
    await call('POST', 'db/scan', query: {'folder': id});
  }

  Future<void> removeFolder(String id) => _mutate(
    (config) => (config['folders'] as List).removeWhere((f) => f['id'] == id),
  );
  Future<void> reconcile(Set<String> folderIds, Set<String> peers) =>
      _mutate((config) {
        (config['folders'] as List).removeWhere(
          (f) => !folderIds.contains(f['id']),
        );
        (config['devices'] as List).removeWhere(
          (d) => d['deviceID'] != deviceId && !peers.contains(d['deviceID']),
        );
      });
  Future<void> stop() async {
    final process = _process;
    if (process == null) return;
    try {
      await call('POST', 'system/shutdown');
    } catch (_) {
      process.kill();
    }
    await process.exitCode.timeout(
      const Duration(seconds: 8),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    if (identical(_process, process)) {
      _owner?.close();
      _owner = null;
      _process = null;
    }
    deviceId = null;
    _key = null;
  }
}
