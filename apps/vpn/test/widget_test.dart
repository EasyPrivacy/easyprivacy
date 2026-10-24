import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easyprivacy_core_sdk/easyprivacy_core_sdk.dart';
import 'package:easyprivacy_vpn/app.dart';

class UnavailableBroker implements BrokerTransport {
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, Object?> arguments = const {},
  ]) async => {
    'protocol': 1,
    'has_session': false,
    'message': 'Open Core first.',
  };
  @override
  void close() {}
}

void main() {
  testWidgets('VPN retains controls when Core is unavailable', (tester) async {
    final core = BrokerCoreConnection(
      transport: UnavailableBroker(),
      autoStart: false,
    );
    addTearDown(core.dispose);
    await tester.pumpWidget(EasyPrivacyVpnApp(connection: core));
    await tester.pumpAndSettle();
    expect(find.text('EasyPrivacy VPN'), findsOneWidget);
    expect(find.text('Connect VPN'), findsOneWidget);
    expect(find.text('Check Core'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
