import 'package:easyprivacy/src/models/agent_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses status returned by the Linux agent', () {
    final status = AgentStatus.fromJson({
      'agentVersion': '0.1.0',
      'hostname': 'home-node',
      'operatingSystem': 'linux',
      'architecture': 'amd64',
      'uptimeSeconds': 90061,
      'memory': {'totalBytes': 1024, 'availableBytes': 512},
      'storage': {'totalBytes': 2048, 'availableBytes': 1536},
      'services': [
        {'id': 'private-dns', 'name': 'Private DNS', 'health': 'healthy'},
      ],
      'backups': <Object?>[],
    });

    expect(status.hostname, 'home-node');
    expect(status.healthyServiceCount, 1);
    expect(status.uptimeLabel, '1d 1h');
    expect(status.storage.usedBytes, 512);
  });

  test('rejects malformed capacity data', () {
    expect(
      () => Capacity.fromJson({'totalBytes': -1, 'availableBytes': 0}),
      throwsFormatException,
    );
  });

  test('formats binary byte sizes for the dashboard', () {
    expect(formatBytes(1539316278886), '1.4 TB');
    expect(formatBytes(512), '512 B');
  });
}
