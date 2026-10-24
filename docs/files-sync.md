# Files Sync: first implementation

Files 1.0.0+3 adds two-device folder Sync on Windows x64 and Android ARM64.
Files 1.0.0+4 adds streamed native Android source selection and rejects incomplete
imports before replacing a local file.
It uses Core 1.0.0+10 and the existing 1.0.1~reorg1 node package. No further
node update or public service port is needed.

## Using Sync

1. Pair both devices to the same Core, grant Files access and start the private
   connection. Open Files on both devices. An Internet VPN is optional.
2. Enable folder Sync on both devices. Create shared folder, choose an online
   device and acknowledge that changes **and deletions** propagate.
3. The recipient must explicitly accept. Each device creates its own local
   folder inside Files. The sender cannot choose the recipient's filesystem path.
4. Browse files to import at the folder root, replace an existing file after
   confirmation, save a copy outside Files, or delete a file after confirmation.
   Browsing, export and deletion support subdirectories.
5. Pause stops that folder's synchronization. Changes made while paused or while
   Sync is off reconcile when it resumes. Keep Files open on both devices.
6. Stop sharing removes the synchronization grant and retains a browsable local
   copy. Delete local copy is a separate action available afterward; the other
   device keeps its folder. An explicit invitation with the same folder/device
   identity can reconnect a retained copy.

At most eight folder copies (including archived copies), three active peers,
and one peer per folder are supported. Arbitrary existing folders, Android
document-provider trees, background hosting, multi-peer sharing, and a version
restore UI are future work. Android document-tree URIs cannot be passed directly
to a filesystem engine. Uninstalling Files removes its private folders.

## Engine and privacy boundary

The bundled, unmodified [Syncthing v2.1.7](https://github.com/syncthing/syncthing/releases/tag/v2.1.7)
handles indexing, block transfers and conflicts. Its simple versioner retains
up to five older versions of files replaced/deleted by the **remote** peer.
Local deletions do not automatically retain a local version. Conflict copies
remain visible as files. Sync is not an independent backup. Copies/versions use
device storage; pulling stops below the 256 MiB folder free-space floor.

Before launch, Files disables global/local discovery, public relays, NAT/STUN,
usage/crash reporting, browser startup and automatic upgrades. The engine listens
and dials only loopback TCP. App-owned bridges carry its original TLS/BEP bytes
through authenticated, encrypted Core Files streams. No separate remote
Internet/LAN path is configured. Core owns enrollment, private WireGuard
connectivity and receiver/firewall leases; no payload is stored on the node.

The existing Files channel authenticates a paired Core device before exchanging
Syncthing identities. Accepted engine identities are pinned; changes fail closed.
Engine certificates/keys and its authenticated loopback REST endpoint belong to
Files, independently of Core enrollment keys. Per-core hashed storage separates
engine state and folders from Send's expiring received copies. Persisted engine
folders/devices start paused; Files reconciles its grant manifest before resuming
authorized folders.

On Windows a noninherited job handle ties the engine's lifetime to Files, even
if Files crashes or is force-closed. Only the engine child is assigned, so Core's
independent broker continues running. Normal Sync shutdown first asks the engine
to flush and stop, before closing its job handle.

Send and Sync share one Core receiver and dispatch connections by their encrypted
first message. Turning off Receive files declines new Send offers while an
enabled Sync receiver stays available. Turning off Sync closes its bridges and
owned engine without disabling Send. Core revocation closes private streams.
Neither capability provides offline forwarding through the Core node.

## Building and notices

[upstream.json](../native/sync-engine/upstream.json) pins source/archive hashes.
Generated binaries and downloaded sources stay out of Git. The tested Android
build uses Go 1.27.3 (upstream requires at least 1.26.2), vendored dependencies,
CGO disabled and PIE mode. Its upstream Android dependency requires the documented
Go linker compatibility flag `-checklinkname=0`. The executable is packaged as an
extracted APK-owned library rather than downloaded executable code.

```powershell
./tool/build-sync-engine.ps1
./tool/build-windows.ps1 -App files
./tool/build-android.ps1 -App files -TargetPlatform android-arm64
```

```bash
# WSL/Linux; Go on PATH or EASYPRIVACY_GO set:
./tool/build-sync-engine.sh android-arm64
```

The shell builder also supports Linux x64 and Windows x64 engine artifacts;
these do not establish a completed Linux Files app. Other Android ABIs require
corresponding engine build targets and Gradle ABI configuration. Files packaging
defaults to ARM64 and checks that its embedded engine is byte-identical to the
native artifact. The Windows helper verifies the official
release archive. Dependency notices and the Go runtime license are bundled under
About / View licenses. The exact unmodified MPL-2.0 source is available at the
pinned URL; `collect-licenses.py` regenerates notices from source and the selected
Go runtime. Preserve notices and source availability when redistributing apps.

## Verification

Ordinary tests cover explicit approval, identity changes, atomic grant loading,
pause/stop preserving files, restart without restoring removed grants, confined
deletion and narrow phone UI. A socket-backed test holds an encrypted Sync
channel open while an approved Send completes, including independent switches.

```powershell
$env:EASYPRIVACY_SYNC_ENGINE = (Resolve-Path apps/files/native/windows/easyprivacy-sync.exe).Path
Push-Location apps/files
flutter test test/sync_engine_integration_test.dart test/sync_bridge_integration_test.dart
Pop-Location
```

The opt-in tests launch real engines with isolated synthetic data. They passed
two-way create/edit, deletion propagation, retained versions, offline conflicts,
and loopback-only settings. Background reliability remains a separate check.

Physical Pixel 10 / Windows checks on October 24, 2026 also passed:

- Approved folder invitation and 4 MiB laptop-to-phone synchronization, exported
  through Android's system save UI and independently checked with SHA-256.
- Phone import/replacement reaching the laptop with the expected SHA-256, and
  phone deletion propagating back to the laptop.
- Paused-folder isolation, resume, Windows engine stop/start preserving identity,
  and phone force-stop/relaunch reconnecting without another invitation.
- A separately approved 4 MiB Send and verified receipt while Sync stayed active.
- Stop sharing retaining a browsable/exportable copy with matching SHA-256, then
  explicit deletion of the local test copy. Generated public test files/links
  were removed and the phone's temporary keep-awake setting restored.
- Final Files 1.0.0+4: an Android document with `_size=NULL` selected through both
  Send and Sync import. Both delivered all 4 MiB with the expected hash. The
  previous Android picker implementation could return an empty byte array for
  this case and allocated the entire selected file in memory. The replacement
  streams a private cache copy before returning only its path/name to Flutter.

The laptop counterpart uses production providers and its real Core broker inside
an opt-in test harness; the phone uses the normal release app and system pickers.
This does not establish physical Windows picker behavior or long background use.

To repeat with one phone receiver, set `EP_PHYSICAL_SYNC_TEST=1`,
`EP_SYNC_TEST_CONTROL` to an existing absolute test directory, and
`EASYPRIVACY_SYNC_ENGINE` to the built engine. Run
`flutter test test/physical_sync_test.dart` in apps/files. Its `state.json` names
the generated test folder, payload and replacement source. Approve the invitation,
export/check the first file, import the replacement under the same filename,
then delete it on the phone. The harness verifies the hashes/deletion and pauses
with a new local copy. After checking that it is absent on the phone, create
`resume.flag` in the control directory. After `laptop-restarted`, force-stop and
reopen the phone app, check Synced, then create `phone-restarted.flag`. Enable
Receive files, create `send.flag`, and approve the test Send. After cleanup create
`finish.flag`. A shorter `EP_SYNC_PICKER_ONLY=1` run ends after the phone replacement
hash passes. Register ADB-staged fixtures with Android's Downloads provider so
they appear in the system picker; a bare shell copy may remain unindexed.

Drive remains unavailable. Its next slice requires server installation and
authenticated private service discovery before a Files Drive client can use it.
