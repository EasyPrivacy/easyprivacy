import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      ['EasyPrivacy native dependencies'],
      await rootBundle.loadString(
        'packages/easyprivacy_vpn_feature/assets/native-licenses.txt',
      ),
    );
  });
  runApp(const EasyPrivacyVpnApp());
}
