# EasyPrivacy V1.0.0: core connection and device pairing

Updated: October 19, 2026 — release 1.0.0.

Branch: `codex/mvp-revamp`

The owner accepted enrollment and the completed MVP on October 18, 2026.
The VPN implementation and its checks are recorded in [VPN milestone](vpn-milestone.md).
See [V1.0.0 release notes](releases/1.0.0.md) for current artifacts and upgrades.

## Implemented experience

1. Install the matching Ubuntu 24.04 package and run
   `sudo easyprivacy-node setup` on a new core.
2. Choose the core name, port, username and password. Setup creates a private
   core identity, starts the service, checks its local TLS response and allows
   the selected TCP port when UFW is already active. Provider firewall rules
   still require configuration in the provider dashboard.
3. Setup displays an eight-digit pairing code. On an existing installation,
   upgrade the package and run `sudo easyprivacy-node pair` instead of setup.
4. Enter the core address, a device name and the code in the app. SPAKE2 mutual
   confirmation authenticates the core fingerprint and this device's fresh
   public key. Show **Core verified**, then require the account username/password
   over pinned TLS before authorizing the device. Code verification alone never
   enrolls it. No public domain certificate or fingerprint typing is required.
5. Only after account authentication, the app saves its private device credential in platform-protected storage,
   then signs a fresh challenge over pinned TLS. Remembered devices reconnect
   without entering the account password.
6. A connected paired device can use **Add device** without an extra password
   or PIN. Codes expire after five minutes, allow five exchange starts and enroll
   one device. A replacement code invalidates earlier pending exchanges.
7. **Paired devices** lists device identities and allows revocation. Revocation
   disables existing sessions, future authentication and codes created by that
   device. Terminal `devices` and `revoke DEVICE_ID` commands provide recovery.

Disconnect retains pairing; **Forget this core** removes the local credential.
Core restarts invalidate sessions and codes, while device authorizations persist.
The optional short PIN for **Add device** remains future work. Legacy pinned
password login remains available for compatibility; those sessions cannot create
codes or manage devices. A saved legacy profile offers **Use a pairing code**.

The app retains the first iteration's theme, logo and native platform scaffolding.
See [the pairing specification](device-pairing.md) for limits and trust boundaries.

## Build artifacts

- `core/dist/easyprivacy-node_1.0.0_amd64.deb`
- `core/dist/easyprivacy-node_1.0.0_arm64.deb`
- Matching `.deb.sha256` files.
- `app/build/easyprivacy-windows-1.0.0-x64.zip`: extract the complete archive and run
  `easyprivacy.exe`; keep its DLLs and data directory together.
- `app/build/easyprivacy-android-1.0.0.apk`: Android release APK, build counter 7.
  The previous MVP build was installed and its enrollment reconnected on Pixel 10.

Generated binaries are excluded from Git. Source build helpers include the
shared native SPAKE2 wrapper in the core, Windows ZIP and Android APK. Dependency
licenses are included in both distributions and the app's Licenses screen.

## Implementation validation before the release designation

| Check | Result |
| --- | --- |
| Go tests with race detector and Go vet | Passed, including pairing, challenge replay, code limits, device persistence, revocation and legacy compatibility |
| Rust native wrapper tests on Linux and Windows | Passed: mutual agreement, context mismatch and consumed handles |
| Flutter analysis | Passed |
| Flutter tests | Passed: 16, including desktop and phone-width two-step enrollment, device management, reconnect, wrong credentials and storage failure |
| Windows Dart/native client to actual Linux Go core | Passed: code verification, account enrollment, wrong code, separate keys, code display without reauthentication, listing and revocation |
| Core restart with saved device seed | Passed: fresh key authentication succeeds; revoked device remains rejected |
| Actual TLS-terminating relay | Passed: substituted core identity fails confirmation; transparent relay cannot obtain a password or enrollment proof; code-only devices cannot authenticate |
| Account enrollment enforcement | Passed: missing proof, incorrect username/password, expired/replaced verification, revoked creator, proof replay and concurrent reuse are rejected |
| Terminal wizard and protected local admin socket | Passed using private disposable state |
| Ubuntu 24.04.4 amd64 installation | Clean installation, prerelease upgrades and reinstallation passed in a disposable chroot |
| Package upgrade | Passed; existing core identity, username and password preserved |
| Installed service under its dedicated unprivileged account | Passed: TLS, local code creation, device listing and durable revocation |
| Package upgrade, removal, reinstallation and purge | Passed; private core state and device records preserved |
| systemd unit and account setup | Passed static unit verification, ownership and enablement checks |
| UFW command | Active/inactive/absent/failure cases unit tested; real Ubuntu UFW dry-run and installed command fixture passed |
| Linux amd64 and arm64 packages | Built successfully; ARM64 is cross-compiled |
| Windows release build and ZIP | Built successfully with native pairing DLL |
| Android debug APK | Built for arm64, ARMv7 and x86-64; installed and launched on Pixel 10 |
| Android native alignment | APK passes 16 KB zip alignment; arm64 native library LOAD segments use 16 KB alignment |

Development used Go 1.27.2, Rust 1.99.1 and Flutter 3.44.3 / Dart 3.12.2.
Package lifecycle checks use Canonical's Ubuntu 24.04.4 Base image, verified
against its signed checksum manifest. The chroot verifies package behavior and
unit definition, rather than a full systemd boot. Tests do not change the
host firewall. The VPS has not been accessed or modified by the agent.

RustCrypto `spake2` 0.4.0 and this integration have not received an independent
security audit. These checks do not constitute one. The owner accepted pairing
against the actual VPS. A real ARM64 Ubuntu
installation remains an additional hardware validation check.

## Owner acceptance and further hardware checks

The owner configured the VPS on Ubuntu 24.04.4 with TCP 7444, corrected its UFW
rule and verified the authenticated Windows connection. The owner subsequently
accepted enrollment, tested the VPN/home access setup and declared the first MVP
complete on October 18, 2026. The agent did not log into or administratively
modify the remote servers.

The release preserves existing identities, accounts, paired devices and VPN state.
An existing installation can install the 1.0.0 package without repeating setup
or pairing. New installations should follow the core and home service-node guides.

Additional hardware checks include an actual ARM64 Ubuntu installation and full
VPS/VM reboot testing. Certificate renewal, password changes and account recovery
remain future work. Core certificates last two years; bearer sessions last one
hour and can be renewed using a currently authorized device key.
