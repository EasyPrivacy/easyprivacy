# VPN indicator checks

These checks cover Windows and Android client indicators. Ubuntu client support
is deferred; its home service controls are unchanged.

## Automated checks

Run `flutter analyze` and `flutter test` from `app/`. The indicator tests cover
connected-only visibility, visibility during a management disconnection, quick
actions, restoring the last exit after a cold notification launch, permission
denial, setting persistence failures and the settings control before sign-in.
Compile the Windows runner and Android app to validate their native integration.

Local verification on October 22, 2026: static analysis passed, all 39 Flutter
tests passed, and both Android and the Windows native runner compiled. A complete
Windows release ZIP was subsequently built using a temporary short build path.
Its unchanged native pairing DLL and VPN helper were restored from the verified
`logo-fixes-22b43d2` archive after confirming matching native sources. The Android
arm64 release APK includes the pairing library from the installed 1.0.0 app and
was installed on the connected Pixel 10 after verifying the signing certificate
matched. Existing app data was retained. Both test builds and checksums are in
the workspace's `artifacts/vpn-notifications/` directory. The device checks below
remain for the owner to perform against a live VPN.

The notification implementation was committed separately as `08aa899` before
the icon follow-up. That follow-up restores the Android launcher/adaptive icons
and Windows application/title-bar assets from `logo-fixes` (`22b43d2`), explicitly
sets the large Windows taskbar icon, and supplies an EasyPrivacy alpha mask plus
a large app logo for Android notifications. The notification masks are exported
by `app/tool/export-notification-icons.py`; platform resources were checked for
non-empty alpha and the expected resolutions before compiling the test builds.
Both icon-corrected release builds passed. The Windows executable contains all
three icon groups at nine resolutions each, and the Android APK contains the
launcher, adaptive foreground and notification resources. The matching-signature
Android update was installed and opened on Pixel 10 after USB reconnected.
These follow-up builds are in `artifacts/vpn-notifications/icons-fixed/`.
The owner verified the Android and Windows icon fixes on October 22, 2026.

## Android device checks

1. Install the complete app build, pair a device and leave **Always show VPN
   status** off. No notification should appear while disconnected.
2. Connect and allow notification and VPN permissions. Check the notification
   drawer for VPN status and **Disconnect**. Tap its body: it should restore the
   existing screen, retaining the selected exit.
3. Background the app. Check that a recent handshake shows **VPN connected**;
   an unreachable server shows **Waiting for VPN server**. Disconnect from the
   notification without opening the app. The notification should disappear.
4. Enable **Always show VPN status**. Disconnect and verify the notification
   remains with **Connect**. Close the screen, tap Connect, and confirm the last
   selected exit is used after pairing is restored. Repeat with the app process
   reclaimed by Android, while the disconnected notification remains.
5. Deny notification permission on a clean installation. The VPN must remain
   usable; the app should explain that notifications are blocked and provide
   **Open notification settings**. Grant permission there and return to the app.
6. Revoke VPN permission or disconnect in Android settings. Check the indicator
   and app return to disconnected state. Turning **Always show VPN status** off
   while connected must keep the required service notification until disconnect.
7. Verify core selection and exit configuration remain in the app, and no app
   passwords or tunnel keys appear in notification text.

Android retains control over notification permission, channel visibility and
dismissal behavior. A force-stop suppresses app notifications until it is opened
again; this feature does not bypass system notification settings.

## Windows desktop checks

1. With the setting off, connect and check the tray icon's tooltip and menu
   status. Verify Connect/Disconnect is disabled while an action is in progress.
2. Close the window, click the tray icon and confirm the same window returns.
   Right-click and exercise Disconnect. With the setting off, the tray should
   disappear and a hidden window should return.
3. Enable **Always show VPN status**. Confirm the disconnected icon remains,
   Connect uses the selected exit, and the saved setting survives restarting.
4. Launch EasyPrivacy again while its first window is hidden. It should restore
   the existing instance, without creating another tunnel controller.
5. Restart Windows Explorer while the app is running. The tray icon should be
   added again. Deny VPN service setup approval and verify the error appears in
   the app without showing a connected status.
6. Quit from the tray while connected. Confirm the VPN continues, then reopen
   EasyPrivacy and disconnect using its restored controls.
