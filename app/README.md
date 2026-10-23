# EasyPrivacy V1.0.0 desktop / Android interface

## Platform icons

Android launcher icons and the Windows executable and Linux desktop icons use
`../assets/EasyPrivacy_White.png` (the black mark on a white background).
Android also has adaptive and themed launcher icons. Windows title bars use
`EasyPrivacy_Transparant_White.png` in dark mode and the matching black mark in
light mode. Linux loads its window icon from the bundle's `data/easyprivacy.png`;
the Debian package installs the same image into the desktop icon theme.

Platform exports are checked in, so normal builds need no image tooling.
After changing the source artwork, run `python -m pip install Pillow` and
`python tool/generate-icons.py` from this directory to regenerate them.
The script also recreates the transparent white variant by setting RGB to white
and copying the black source's alpha channel exactly, without image synthesis.

## Overview

This release uses the first iteration's Flutter platform scaffolding,
green-and-white theme, and logo. It implements short-code pairing, a separate
Ed25519 identity for each device, remembered-device reconnecting, code creation,
device listing/revocation, authenticated status and periodic reachability checks.
Core status is distinct from a VPN connection.

V1.0.0 is the first completed MVP, accepted by the owner on October 18, 2026.
The app release is `1.0.0+7`: version `1.0.0`, Android build counter `7`.
See [release notes and upgrades](../docs/releases/1.0.0.md) for release files and
compatibility. Existing pairings and keys remain usable after the update.

## VPS and Home VPN exits

Install the `1.0.0` core package, then run `sudo easyprivacy-node vpn-setup` on the
VPS and allow its UDP port (default 51821) in the provider firewall. In the app,
select the VPS under **Internet exit** and choose **Connect VPN**. A recent
WireGuard handshake is required before displaying **VPN connected**. IPv4
traffic and DNS use the exit; IPv6 is blocked through this first exit.

Windows embeds the official tunnel service and WireGuardNT driver in
`easyprivacy-vpn.exe`. The first connection requests administrator approval to
install EasyPrivacy's private local service. Android embeds the official tunnel
library and uses Android's VPN permission and foreground notification. A separate
WireGuard application is not needed. The Windows/Android app controls the tunnel,
provisions the enrolled device and keeps its separate traffic key in protected
storage. Device revocation removes the server peer and rejects future provisioning.

The VPN can continue with the UI closed or while core management is temporarily
unreachable. An explicit device-authorization rejection stops it. The app retains
a disconnect control even before core login, so a lost management connection
does not trap the device behind a stale tunnel. **Disconnect VPN** restores normal
networking. Boot-time automatic client connection remains future work.

### VPN notifications and Windows tray

Android shows an ongoing VPN notification with status and **Disconnect** while
the tunnel is active. Allow notifications when Android asks on the first VPN
connection; if they are blocked, use **Open notification settings** in the app.
Tap the notification to open the existing EasyPrivacy screen. The service keeps
status updated even when that screen is closed. A tunnel without a recent
handshake shows **Waiting for VPN server**, rather than claiming it is connected.

Windows shows EasyPrivacy in the system tray while the VPN is active. Click the
icon to restore the app; right-click for status, **Open EasyPrivacy**, and
**Connect VPN** or **Disconnect VPN**. Closing the window while the tray is shown
keeps the app available there. **Quit EasyPrivacy** removes the tray and exits
the app; an existing VPN tunnel continues independently. Reopening EasyPrivacy
restores its status and controls. If connected-only mode removes the last tray
icon after disconnecting, a hidden window is restored so the app stays accessible.

Enable **Always show VPN status** in the app to keep the notification or tray
available when disconnected. This per-device setting is saved and is off by
default. Android's **Connect** button opens the app, restores its saved pairing
and last used exit, and connects when that exit is ready. Core and exit selection
stay in the app. Neither mode starts a disconnected VPN automatically at boot.
Ubuntu's home service management interface is unchanged.

Platform verification steps are in [VPN indicator checks](../docs/vpn-indicator-checks.md).

The Home exit uses the same device tunnel to the VPS and a second encrypted leg
to an outbound Linux service node. The VPS remains trusted with forwarding. The
home VM needs no public IP or incoming router port forwarding. Explicit management
host routes support server access when local and home LAN ranges overlap. See
the [home service-node guide](../docs/home-service-node.md) for setup and limits.

Build the Windows helper first with `bash tool/build-vpn-windows.sh` from WSL
(Go 1.27+, Python and curl). Then use `tool/build-windows.ps1` as below. Android
builds resolve the pinned WireGuard Maven dependency. Dependency notices are in
the app's Licenses screen. See `../docs/vpn-milestone.md` for completed tests and
the implementation's validation results and owner acceptance.

Install the `1.0.0` core package and run `sudo easyprivacy-node pair` in the
trusted VPS terminal. Enter the core address, a device name and the eight-digit
code in the app. After **Core verified**, enter the core account username and
password to authorize the new device over pinned TLS. Verification alone does
not enroll a device or save its key. The code expires after five minutes,
accepts at most five exchange starts, and enrolls one device. Each successful
verification permits at most five account-password attempts before expiry.
SPAKE2 mutual confirmation authenticates the core identity before credentials
are sent. No public domain certificate is needed. An authorized connected device can use **Add device** without another
password or PIN; the optional short PIN remains future work.

```bash
flutter pub get
flutter analyze
flutter test
./tool/build-pairing.ps1
flutter build windows --release
./tool/build-android.ps1
```

On Windows, this deeply nested worktree can exceed the C++ compiler's path limit.
Run `./tool/build-windows.ps1` in PowerShell to build in a temporary short path
and create `build/easyprivacy-windows-1.0.0-x64.zip` with its checksum. It uses cached plugin directory
junctions without requiring a system-wide Developer Mode setting. Run
`flutter pub get` first to populate package metadata. The PAKE helper needs Rust
with the Windows MSVC toolchain, the Android NDK, and Rust targets
`aarch64-linux-android`, `armv7-linux-androideabi`, `x86_64-linux-android`.
It generates the DLL and Android JNI libraries included in app builds. End users
need no Rust or native development tools; they extract the
complete ZIP and run `easyprivacy.exe` from that folder.

`tool/build-android.ps1` creates `build/easyprivacy-android-1.0.0.apk` and a
matching checksum after building the standard Flutter release APK. Both archive
helpers read the project `VERSION` file for their release filenames.

For an Ubuntu desktop, `tool/build-linux.sh` builds the optional
`easyprivacy-desktop_1.0.0_amd64.deb` using a native Linux Flutter SDK and the
shared Linux pairing library. It depends on the matching node package and provides
pairing, setup, status and start/stop controls for the same home service used by
`easyprivacy-node service-setup`. A normal desktop session and secret-service
keyring store the GUI's enrolled identity; the package supplies those dependencies.
Closing the GUI leaves the service running. An ordinary Linux full-tunnel VPN
client remains outside the V1.0.0 scope.

Set up the Ubuntu package first using `../core/README.md`. After pairing the app
refuses a different server certificate, plaintext HTTP, redirects and expired
certificates. A failed refresh shows the core as unreachable with the last
successful check. Lost/expired sessions reconnect using the device key when
authorized. The core address, authenticated certificate fingerprint and device
private seed are saved with `flutter_secure_storage`; passwords, pairing codes
and session tokens are not persisted. Disconnect retains pairing; **Forget this
core** deletes the local credential. Revocation ends the selected device's
existing sessions and prevents its future key-based authentication.

Updated enrollment requires the matching app/core protocol version; an older
core asks for an upgrade, and older apps fail confirmation instead of bypassing
the account requirement. Previously enrolled device keys remain compatible.

Existing saved fingerprint profiles load the legacy sign-in screen. Choose
**Use a pairing code** to migrate after upgrading the core. Legacy login remains
available under **Use existing fingerprint login**, but its sessions cannot
create pairing codes. Pairing never silently replaces an existing trusted pin.

RustCrypto SPAKE2 0.4.0 and this integration have not been independently audited.
The app's **Licenses** page includes notices for the pinned native dependencies.

The current APK uses the development signing key for local MVP testing.
