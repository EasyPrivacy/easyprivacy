# Physical phone/laptop transport check

This opt-in test uses the owner's existing updated core node. It transfers
synthetic data through the real Core brokers and private runtimes. It does not
choose files, persist file payloads, or implement Files Send. Enable Files access
and start the private connection in Core on both Windows and Android first.

From `packages/easyprivacy_core_sdk` on Windows:

```powershell
$env:EP_PHYSICAL_STREAM_TEST = '1'
flutter test --no-pub test/physical_private_stream_test.dart --reporter expanded
```

The test prints `EP_TEST_RECEIVER_ID=<id>`. This is public rendezvous metadata,
not a device credential. It waits up to eight minutes for the phone. In another
terminal, from `apps/files`, substitute that ID and the attached ADB device ID:

```powershell
flutter test integration_test/private_stream_test.dart -d DEVICE_ID --dart-define=EP_TEST_RECEIVER_ID=RECEIVER_ID --reporter expanded
```

The Android test installs a temporary test build of Files. Both tests must pass:
8 MiB goes each way, with SHA-256 integrity and peer receipts. Payload reads and
writes use 64 KiB chunks. Windows teardown removes its receiver even on failure.
Close the test before restarting Core. Remove `EP_PHYSICAL_STREAM_TEST` from the
terminal environment afterward; ordinary workspace checks skip the physical test.

Restore the normal Files APK afterward, preserving app data:

```powershell
# From the repository root; the physical test above has finished.
tool/build-android.ps1 -App files -TargetPlatform android-arm64
adb -s DEVICE_ID install -r apps/files/build/app/outputs/flutter-apk/app-release.apk
```

The test and normal APK must have the same publisher signature as Core so Android
can authorize the Files broker client. These development artifacts use the same
debug publisher as the test Core/VPN builds. Production signing is a separate
release requirement.

For Windows packaging, build the native DLL with
`tool/build-pairing.ps1 -TargetPlatform windows-x64`, then run
`tool/build-windows.ps1 -App core`. With other Core brokers stopped,
`tool/smoke-windows-core.ps1` checks the packaged headless broker in a temporary
registry directory. It does not start a remote connection or change enrollment.
