import 'dart:io';
import 'package:flutter/services.dart';
import 'desktop_broker.dart';

abstract interface class BrokerTransport {
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, Object?> arguments = const {},
  ]);
  void close();
}

class PlatformBrokerTransport implements BrokerTransport {
  PlatformBrokerTransport(this.capability);
  final String capability;
  static const channel = MethodChannel('org.easyprivacy/core_broker');
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, Object?> arguments = const {},
  ]) async {
    if (!Platform.isAndroid) {
      return DesktopBrokerClient(
        capability: capability,
      ).call(method, arguments);
    }
    try {
      final result = await channel.invokeMapMethod<String, dynamic>('call', {
        'method': method,
        'arguments': arguments,
      });
      return result ?? <String, dynamic>{};
    } on PlatformException catch (e) {
      throw BrokerException(
        e.code,
        e.message ?? 'Core could not complete the request.',
      );
    } on MissingPluginException {
      throw const BrokerException(
        'core_unavailable',
        'Install and open EasyPrivacy Core first.',
      );
    }
  }

  @override
  void close() {}
}

class BrokerException implements Exception {
  const BrokerException(this.code, this.message);
  final String code, message;
  @override
  String toString() => message;
}
