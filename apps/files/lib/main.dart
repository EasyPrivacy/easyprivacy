import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Syncthing',
    ], await rootBundle.loadString('assets/sync-engine-licenses.txt'));
  });
  runApp(const EasyPrivacyFilesApp());
}
