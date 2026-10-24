enum FileMode { send, sync, drive }

enum TransportPurpose { privateServices, internetExit, serviceNode }

class ServiceDescriptor {
  const ServiceDescriptor({
    required this.id,
    required this.name,
    required this.ready,
    this.message = '',
  });
  final String id, name, message;
  final bool ready;
  factory ServiceDescriptor.fromJson(Map<String, dynamic> value) {
    if (value['id'] is! String ||
        value['name'] is! String ||
        value['ready'] is! bool) {
      throw const FormatException('Invalid service description.');
    }
    return ServiceDescriptor(
      id: value['id'] as String,
      name: value['name'] as String,
      ready: value['ready'] as bool,
      message: value['message'] as String? ?? '',
    );
  }
}
