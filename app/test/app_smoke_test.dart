import 'package:easyprivacy/src/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('opens the demo dashboard from onboarding', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const EasyPrivacyApp());

    expect(find.text('Connect your Linux server'), findsOneWidget);
    await tester.tap(find.byKey(const Key('demo-button')));
    await tester.pumpAndSettle();

    expect(find.text('Your private cloud'), findsOneWidget);
    expect(find.text('6 healthy'), findsOneWidget);
    expect(find.text('Demo system is protected'), findsOneWidget);
  });
}
