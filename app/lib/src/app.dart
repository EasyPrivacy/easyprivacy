import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'screens/connect_server_screen.dart';
import 'screens/dashboard_screen.dart';
import 'theme.dart';

class EasyPrivacyApp extends StatefulWidget {
  const EasyPrivacyApp({super.key});

  @override
  State<EasyPrivacyApp> createState() => _EasyPrivacyAppState();
}

class _EasyPrivacyAppState extends State<EasyPrivacyApp> {
  late final AppController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AppController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EasyPrivacy',
      debugShowCheckedModeBanner: false,
      theme: buildEasyPrivacyTheme(),
      home: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          if (_controller.isConnected) {
            return DashboardScreen(controller: _controller);
          }
          return ConnectServerScreen(controller: _controller);
        },
      ),
    );
  }
}
