# Deferred Linux Desktop Review

## Status

**Deferred on:** August 25, 2026  
**Reason:** No Linux desktop test device is currently available.  
**Scope:** EasyPrivacy management app on Linux desktop.  
**Does not defer:** Linux server-agent development or Windows and Android app testing.

This is an intentional test deferral, not a known product failure. Reopen this review when a physical Linux computer or a Linux virtual machine with a graphical desktop is available.

## Why this review remains necessary

The Flutter project includes a Linux desktop target, but generating the platform files on Windows does not prove that the app compiles or behaves correctly on Linux. The later review must validate:

- the native Linux compiler and GTK integration;
- asset loading and application startup;
- responsive layouts and window resizing;
- navigation, text entry, and scrolling;
- real connectivity from the Linux app to an EasyPrivacy agent;
- Linux-specific packaging and launch behavior.

## Device readiness

Resume testing when the device has:

- a supported 64-bit Linux distribution with a graphical desktop;
- internet access for initial Flutter dependency retrieval;
- Git;
- Flutter 3.44.3 or later on the stable channel;
- the Linux desktop build dependencies reported by `flutter doctor -v`;
- enough access to install missing development packages;
- optional SSH access to a disposable Linux server for the real connection test.

The desktop test device and the EasyPrivacy server may be the same Linux machine, but they do not need to be.

## Resume procedure

From the repository root on the Linux device:

```bash
cd easyprivacy/app
flutter --version
flutter config --enable-linux-desktop
flutter doctor -v
flutter pub get
flutter test
flutter build linux --debug
./build/linux/x64/debug/bundle/easyprivacy
```

If the device uses ARM Linux, locate the generated bundle under the architecture-specific directory rather than assuming `linux/x64`.

Do not continue to interface testing if `flutter doctor -v`, `flutter test`, or the Linux build fails. Record the failure first, including the full command and relevant diagnostic output with credentials removed.

## Review checklist

### LDR-01 — Toolchain

- [ ] `flutter --version` reports Flutter 3.44.3 or later.
- [ ] `flutter doctor -v` recognizes the Linux desktop toolchain.
- [ ] `flutter pub get` succeeds.
- [ ] All Flutter tests pass.
- [ ] `flutter build linux --debug` succeeds without source changes.

### LDR-02 — Launch and identity

- [ ] The generated `easyprivacy` executable launches.
- [ ] The window title is **EasyPrivacy**.
- [ ] The EasyPrivacy logo loads correctly.
- [ ] No terminal error, crash, blank window, or missing asset appears.

### LDR-03 — Responsive interface

- [ ] The wide layout displays the welcome panel during onboarding.
- [ ] The narrow layout hides the welcome panel and keeps the form usable.
- [ ] Window resizing causes no clipped controls, overflow markings, or inaccessible content.
- [ ] System font and window-decoration differences do not break the layout.

### LDR-04 — Onboarding and demo

- [ ] Required-field validation works.
- [ ] Remote plain-HTTP server addresses are rejected.
- [ ] Localhost HTTP remains available for SSH-tunnel development.
- [ ] The credential show/hide control works.
- [ ] The demo dashboard opens and shows the expected sample status.

### LDR-05 — Navigation

- [ ] Every sidebar destination can be selected.
- [ ] Overview returns to the dashboard.
- [ ] Placeholder pages clearly identify unfinished areas.
- [ ] Disconnect returns to onboarding.

### LDR-06 — Real agent connection

Follow **NET-01 through NET-04** in [manual-testing.md](manual-testing.md).

- [ ] The Linux desktop app connects through an SSH tunnel.
- [ ] Real hostname, architecture, uptime, memory, and storage values appear.
- [ ] A wrong credential is rejected.
- [ ] Closing the tunnel produces a refresh warning without replacing real data with demo data.

## Completion criteria

Linux desktop validation is complete when:

1. LDR-01 through LDR-06 pass on at least one Linux desktop environment.
2. Any failures have been fixed or recorded as explicit accepted limitations.
3. The tested distribution, desktop environment, architecture, Flutter version, and commit are recorded below.
4. The Linux section of [manual-testing.md](manual-testing.md) is updated from **Deferred** to **Completed**, including the test date.

Testing a second distribution or desktop environment is recommended before a public release but is not required to close the first validation milestone.

## Results record

```text
Review date:
Tester:
EasyPrivacy commit:
Linux distribution and version:
Desktop environment:
CPU architecture:
Flutter version:

LDR-01 Toolchain:            Not run
LDR-02 Launch and identity:  Not run
LDR-03 Responsive interface: Not run
LDR-04 Onboarding and demo:  Not run
LDR-05 Navigation:           Not run
LDR-06 Agent connection:     Not run

Issues discovered:
Evidence or screenshots:
Final result: Deferred
```

Never include device credentials, development tokens, SSH private keys, passwords, IP addresses that should remain private, or recovery material in the results record.
