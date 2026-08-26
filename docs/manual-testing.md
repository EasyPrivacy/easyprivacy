# EasyPrivacy 0.1 Manual Test Plan

This plan verifies the initial Windows, Android, and Linux management app plus the Linux server agent. It is written for development builds and does not certify the software for production use.

## Validation status

| Test area | Status | Last update |
|---|---|---|
| Windows management app | Completed; no failures reported | User-tested August 26, 2026 |
| Android management app | Completed; no failures reported | User-tested August 26, 2026 |
| Linux desktop management app | Deferred | Waiting for a Linux desktop test device |
| Linux server agent | Completed; no failures reported | User-tested August 26, 2026 |
| Real app-to-agent SSH-tunnel path | Not separately confirmed | Retain NET-01 through NET-04 for a future run |

“No failures reported” records the result communicated after manual testing; it does not imply that every device, distribution, or edge case has been certified.

## Current test-build limitations

- The server agent supports Linux only.
- Automatic SSH installation is not implemented yet; the agent is installed manually.
- Version 0.1 uses one shared development agent token, not independently revocable device credentials.
- The app keeps the token in memory only. Closing the app forgets the connection and token.
- The agent listens on localhost unless TLS is configured.
- Service installation, backups, updates, and security management are visible as future areas but are not functional yet.
- The Windows executable must remain beside its generated DLL and `data` files. Do not copy the `.exe` by itself.

## Record results

For each test, record one of:

- **Pass** — observed result matches the expected result.
- **Fail** — result differs; record what happened and attach a screenshot if useful.
- **Blocked** — the platform or prerequisite is unavailable; record the blocker.

Also record:

```text
Date: 
Tester:
App commit:
Windows version:
Android device and version:
Linux desktop distribution:
Linux server distribution:
Server architecture:
```

## 1. Windows desktop smoke test

**Current status: Completed by the user on August 26, 2026; no failures were reported.** Retain WIN-01 through WIN-05 as regression tests for later builds.

### Prerequisite

EasyPrivacy supports Flutter 3.44.3 or later in the current 0.1 development line. Confirm which Flutter installation your terminal is using:

```powershell
Get-Command flutter
flutter --version
```

Build the app from the repository:

```powershell
cd app
flutter pub get
flutter build windows --debug
```

Run:

```text
app\build\windows\x64\runner\Debug\easyprivacy.exe
```

### WIN-01 — Launch and onboarding

1. Launch `easyprivacy.exe` from its `Debug` directory.
2. Confirm the window title is **EasyPrivacy**.
3. Confirm the page displays **Connect your Linux server**.
4. Confirm the server-name, agent-address, and development-agent-token fields are visible.
5. Confirm **Connect server** and **Explore the demo dashboard** are visible.

Expected: the app opens without a console window, crash, blank page, clipped controls, or horizontal scrolling.

### WIN-02 — Resize behavior

1. Resize the window to approximately 1280 × 720.
2. Increase it to a wide desktop size.
3. Reduce it to the smallest practical width.

Expected: the welcome panel appears on wide layouts and disappears on narrow layouts. The connection form remains usable without overlapping controls.

### WIN-03 — Form validation

1. Clear the server name and press **Connect server**.
2. Restore the name, clear the URL, and retry.
3. Enter `http://192.0.2.10:7443` and any token.

Expected: empty required fields show validation. A non-local HTTP address is rejected because remote servers require HTTPS.

### WIN-04 — Demo dashboard

1. Press **Explore the demo dashboard**.
2. Confirm the heading reads **Your private cloud**.
3. Confirm the green pill says **Demo system is protected**.
4. Confirm the summary shows six healthy services, protected backups, free storage, and an agent version.
5. Confirm the Services, Infrastructure, and Backup locations panels are visible.

Expected: the dashboard resembles the interface concept, with no overflow stripes, clipped text, or blank cards.

### WIN-05 — Navigation

1. Select each sidebar destination: Overview, Services, Network, Storage, Backups, Security, and Settings.
2. Return to Overview.
3. Press **Disconnect server**.

Expected: Overview shows the dashboard. Other destinations show an honest next-slice placeholder. Disconnect returns to onboarding.

## 2. Android smoke test

**Current status: Completed by the user on August 26, 2026; no failures were reported.** Retain AND-01 through AND-04 as regression tests for later builds.

### Prerequisite

Build and install the debug APK:

```powershell
cd app
flutter pub get
flutter build apk --debug
adb install -r build\app\outputs\flutter-apk\app-debug.apk
```

You may instead copy `app-debug.apk` to the device and install it manually. Android may ask for permission to install development APKs from that source.

### AND-01 — Launch

1. Open EasyPrivacy from the Android launcher.
2. Confirm the onboarding form fits in portrait orientation.
3. Scroll from the top through the security note.

Expected: every control is reachable and the keyboard does not permanently cover the active field or buttons.

### AND-02 — Input behavior

1. Tap the agent-address field and enter a URL.
2. Tap the token field.
3. Use the eye button to show and hide the token.
4. Confirm the token field normally obscures its value.

Expected: text entry, focus order, keyboard resizing, and token visibility all behave correctly.

### AND-03 — Mobile demo dashboard

1. Open the demo dashboard.
2. Scroll to the bottom of Overview.
3. Open the navigation drawer and visit each destination.
4. Rotate the device between portrait and landscape.

Expected: cards stack on narrow screens, the navigation drawer works, and rotation causes no crash, overflow, or inaccessible content.

### AND-04 — Resume

1. Put EasyPrivacy in the background.
2. Open another app.
3. Return to EasyPrivacy.

Expected: the visible screen remains intact. Remember that fully closing the process intentionally forgets the version 0.1 connection.

## 3. Linux desktop smoke test

**Current status: Deferred until a Linux test device is available.** This is an accepted test gap, not a failed test. Resume from [deferred-linux-desktop-review.md](deferred-linux-desktop-review.md) when suitable hardware or a Linux virtual machine is available.

### Prerequisites

On a supported Linux development machine, install Flutter's Linux desktop prerequisites, then run:

```bash
cd app
flutter pub get
flutter doctor -v
flutter test
flutter build linux --debug
./build/linux/x64/debug/bundle/easyprivacy
```

On ARM Linux, the output architecture directory may differ.

### LNX-01 — Build and launch

1. Confirm `flutter doctor -v` recognizes the Linux toolchain.
2. Confirm all Flutter tests pass.
3. Build and launch the Linux desktop app.
4. Repeat WIN-01 through WIN-05.

Expected: Linux behavior and layout match Windows, subject to native font and window-decoration differences.

## 4. Linux agent test

**Current status: Completed by the user on August 26, 2026; no failures were reported.** Retain AGT-01 through AGT-04 as regression and security tests for later agent builds.

Use a disposable Linux VM or test server before using personal infrastructure.

### Prerequisites

- 64-bit Linux with systemd;
- Go 1.26 or later for a source build;
- SSH access from the computer running the EasyPrivacy app;
- `curl` for direct API tests.

Build on the Linux server or another Linux machine of the same architecture:

```bash
cd agent
go test ./...
go vet ./...
mkdir -p dist
go build -trimpath -buildvcs=false -o dist/easyprivacy-agent ./cmd/easyprivacy-agent
```

### AGT-01 — Initialize without installing

```bash
test_dir=$(mktemp -d)
./dist/easyprivacy-agent init --state-dir "$test_dir"
```

Expected: initialization prints a long development token and creates `$test_dir/agent.token` with owner-only permissions.

Check permissions:

```bash
stat -c '%a %U %G %n' "$test_dir" "$test_dir/agent.token"
```

Expected: the directory and token are mode `700` and `600` respectively.

### AGT-02 — Prevent accidental public HTTP

```bash
./dist/easyprivacy-agent serve \
  --state-dir "$test_dir" \
  --listen 0.0.0.0:7443
```

Expected: the agent refusgo es to start because a non-loopback HTTP listener is not allowed without TLS.

### AGT-03 — Local API authentication

Start the agent in one terminal:

```bash
./dist/easyprivacy-agent serve --state-dir "$test_dir"
```

In another terminal:

```bash
curl --fail http://127.0.0.1:7443/healthz
curl -i http://127.0.0.1:7443/v1/status
token=$(tr -d '\r\n' < "$test_dir/agent.token")
curl --fail \
  -H "Authorization: Bearer $token" \
  http://127.0.0.1:7443/v1/status
```

Expected:

- `/healthz` returns only `{"status":"ok"}`;
- the unauthenticated status request returns HTTP 401;
- the authenticated request returns the real hostname, Linux architecture, uptime, memory, and storage;
- `services` and `backups` are empty arrays in the current version.

Stop the foreground agent with Ctrl+C.

### AGT-04 — System installation

From the `agent` directory:

```bash
sudo sh ./scripts/install.sh ./dist/easyprivacy-agent
sudo systemctl status easyprivacy-agent.service
sudo journalctl -u easyprivacy-agent.service --since today
```

Expected: the installer prints the development token on first initialization, enables the service, and the service runs as the unprivileged `easyprivacy` account. The journal must not contain the token.

Do not rerun initialization merely to retrieve a lost token. This development build intentionally does not expose it through logs.

## 5. Real app-to-agent test through SSH

**Current status: Not separately confirmed.** The Linux agent was tested, but this record does not assume that the complete app-to-agent tunnel workflow was included.

This path tests real data without exposing the unfinished agent API publicly.

### NET-01 — Create the tunnel

On the Windows or Linux computer running the EasyPrivacy app:

```bash
ssh -N -L 7443:127.0.0.1:7443 your-user@your-linux-server
```

Leave the SSH session open. If local port 7443 is already used, choose another local port, such as `17443:127.0.0.1:7443`.

### NET-02 — Connect the app

1. Open EasyPrivacy.
2. Enter a recognizable server name.
3. Enter `http://127.0.0.1:7443`, or the alternate local port chosen above.
4. Enter the development token printed during agent initialization.
5. Press **Connect server**.

Expected: the real dashboard opens and displays the Linux server's hostname, operating system, architecture, uptime, free memory, total storage, and free storage. Services and backups should honestly report that they are not configured.

### NET-03 — Wrong token

1. Disconnect.
2. Reconnect with an altered token.

Expected: the app reports that the server rejected the token and does not open the dashboard.

### NET-04 — Lost connection

1. Connect successfully again.
2. Close the SSH tunnel.
3. Press refresh in EasyPrivacy.

Expected: the existing dashboard remains visible, but a refresh warning says the server could not be refreshed. The app must not replace real data with demo data.

## 6. Report a result

For a failure, include:

```text
Test ID:
Platform and version:
Expected result:
Actual result:
Reproduction steps:
Screenshot or log excerpt:
Did restarting reproduce it?:
```

Never include the development agent token, SSH private keys, passwords, or recovery material in screenshots or bug reports.
