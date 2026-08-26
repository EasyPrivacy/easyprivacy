class AgentStatus {
  const AgentStatus({
    required this.agentVersion,
    required this.hostname,
    required this.operatingSystem,
    required this.architecture,
    required this.uptimeSeconds,
    required this.memory,
    required this.storage,
    required this.services,
    required this.backups,
  });

  factory AgentStatus.fromJson(Map<String, Object?> json) {
    return AgentStatus(
      agentVersion: _requiredString(json, 'agentVersion'),
      hostname: _requiredString(json, 'hostname'),
      operatingSystem: _requiredString(json, 'operatingSystem'),
      architecture: _requiredString(json, 'architecture'),
      uptimeSeconds: _requiredInt(json, 'uptimeSeconds'),
      memory: Capacity.fromJson(_requiredMap(json, 'memory')),
      storage: Capacity.fromJson(_requiredMap(json, 'storage')),
      services: _requiredList(json, 'services')
          .map((item) => ManagedService.fromJson(_asMap(item, 'services item')))
          .toList(growable: false),
      backups: _requiredList(json, 'backups')
          .map((item) => BackupLocation.fromJson(_asMap(item, 'backups item')))
          .toList(growable: false),
    );
  }

  final String agentVersion;
  final String hostname;
  final String operatingSystem;
  final String architecture;
  final int uptimeSeconds;
  final Capacity memory;
  final Capacity storage;
  final List<ManagedService> services;
  final List<BackupLocation> backups;

  int get healthyServiceCount =>
      services.where((service) => service.health == HealthState.healthy).length;

  String get uptimeLabel {
    final days = uptimeSeconds ~/ Duration.secondsPerDay;
    final hours =
        (uptimeSeconds % Duration.secondsPerDay) ~/ Duration.secondsPerHour;
    if (days > 0) {
      return '${days}d ${hours}h';
    }
    final minutes =
        (uptimeSeconds % Duration.secondsPerHour) ~/ Duration.secondsPerMinute;
    return '${hours}h ${minutes}m';
  }
}

class Capacity {
  const Capacity({required this.totalBytes, required this.availableBytes});

  factory Capacity.fromJson(Map<String, Object?> json) {
    return Capacity(
      totalBytes: _requiredInt(json, 'totalBytes'),
      availableBytes: _requiredInt(json, 'availableBytes'),
    );
  }

  final int totalBytes;
  final int availableBytes;

  int get usedBytes => totalBytes - availableBytes;

  double get usedFraction => totalBytes == 0 ? 0 : usedBytes / totalBytes;

  String get availableLabel => formatBytes(availableBytes);
  String get totalLabel => formatBytes(totalBytes);
}

class ManagedService {
  const ManagedService({
    required this.id,
    required this.name,
    required this.health,
  });

  factory ManagedService.fromJson(Map<String, Object?> json) {
    return ManagedService(
      id: _requiredString(json, 'id'),
      name: _requiredString(json, 'name'),
      health: HealthState.fromWireValue(_requiredString(json, 'health')),
    );
  }

  final String id;
  final String name;
  final HealthState health;
}

class BackupLocation {
  const BackupLocation({
    required this.id,
    required this.name,
    required this.health,
  });

  factory BackupLocation.fromJson(Map<String, Object?> json) {
    return BackupLocation(
      id: _requiredString(json, 'id'),
      name: _requiredString(json, 'name'),
      health: HealthState.fromWireValue(_requiredString(json, 'health')),
    );
  }

  final String id;
  final String name;
  final HealthState health;
}

enum HealthState {
  healthy,
  degraded,
  unavailable,
  unknown;

  factory HealthState.fromWireValue(String value) {
    return switch (value) {
      'healthy' => HealthState.healthy,
      'degraded' => HealthState.degraded,
      'unavailable' => HealthState.unavailable,
      _ => HealthState.unknown,
    };
  }

  String get label => switch (this) {
    HealthState.healthy => 'Healthy',
    HealthState.degraded => 'Needs attention',
    HealthState.unavailable => 'Unavailable',
    HealthState.unknown => 'Unknown',
  };
}

String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  final digits = value >= 100 || unit == 0 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

Map<String, Object?> _requiredMap(Map<String, Object?> json, String key) {
  return _asMap(json[key], key);
}

Map<String, Object?> _asMap(Object? value, String label) {
  if (value is! Map) {
    throw FormatException('$label must be an object');
  }
  return value.map((key, item) => MapEntry(key.toString(), item));
}

List<Object?> _requiredList(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! List) {
    throw FormatException('$key must be a list');
  }
  return value.cast<Object?>();
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('$key must be a non-empty string');
  }
  return value;
}

int _requiredInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! num || value < 0) {
    throw FormatException('$key must be a non-negative number');
  }
  return value.toInt();
}

const demoAgentStatus = AgentStatus(
  agentVersion: '0.1.0-demo',
  hostname: 'easyprivacy-home',
  operatingSystem: 'linux',
  architecture: 'amd64',
  uptimeSeconds: 528180,
  memory: Capacity(totalBytes: 17179869184, availableBytes: 9663676416),
  storage: Capacity(totalBytes: 2199023255552, availableBytes: 1539316278886),
  services: [
    ManagedService(
      id: 'private-network',
      name: 'Private Network',
      health: HealthState.healthy,
    ),
    ManagedService(
      id: 'private-dns',
      name: 'Private DNS',
      health: HealthState.healthy,
    ),
    ManagedService(
      id: 'private-drive',
      name: 'Private Drive',
      health: HealthState.healthy,
    ),
    ManagedService(
      id: 'passwords',
      name: 'Passwords',
      health: HealthState.healthy,
    ),
    ManagedService(id: 'photos', name: 'Photos', health: HealthState.healthy),
    ManagedService(id: 'media', name: 'Media', health: HealthState.healthy),
  ],
  backups: [
    BackupLocation(
      id: 'local',
      name: 'Local backup',
      health: HealthState.healthy,
    ),
    BackupLocation(
      id: 'brother',
      name: "Brother's house",
      health: HealthState.healthy,
    ),
    BackupLocation(
      id: 'parents',
      name: "Parents' house",
      health: HealthState.healthy,
    ),
  ],
);
