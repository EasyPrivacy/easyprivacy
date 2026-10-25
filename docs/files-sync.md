# Files Sync: live folders

Files 1.0.0+5 uses chosen Windows directories, a managed Android Documents tree,
multiple receiving devices and optional selective sync/background operation.
Core 1.0.0+10 and the existing 1.0.1~reorg1 node package remain sufficient.

## Using Sync

1. Pair devices to the same Core, grant Files access, and enable the private
   connection. An Internet VPN is optional. Enable folder Sync in Files.
2. On Windows, **Choose folder to sync** attaches an existing directory and every
   descendant. Choose an online device to invite and approve propagation of
   changes and deletions. The source always keeps and shares its complete contents.
3. A receiving Windows device chooses its own existing local directory when it
   accepts. Existing contents there are also shared. Folder locations cannot
   overlap another configured Sync folder or Files' private configuration.
4. Android asks once for a persistent grant to Documents (or its existing
   EasyPrivacy Files directory), using the system folder picker. Files creates
   `Documents/EasyPrivacy Files/<folder name>`; unrelated existing directories
   are not adopted implicitly. Name collisions get a distinct suffix.
5. Recipients choose **Sync everything** or **Selective sync** on acceptance or
   afterward. Selective sync lists the global directory index without fetching
   unselected file content. Browse and check files/subfolders to keep them locally.
   Rules apply to descendants, with explicit child choices taking precedence.
   Deselecting removes this device's synced file copies after verifying the source
   has their latest indexed versions. Unsynced/changed copies are preserved.
6. Browse files to add files within the current subdirectory, create folders,
   open/edit via an application chooser, move/rename within the shared tree, or
   delete files/directories. Changes made directly in a synced location are also
   detected automatically. In selective mode an unselected local item must be
   selected before its changes participate in synchronization.
7. The source can **Add device** to share the same folder with additional paired
   devices. Changes pass through the source replica, so it must remain available
   for receivers to exchange updates. Core carries private streams and stores no
   offline file copy.
8. Files asks whether to run in the background. Windows keeps a tray icon when
   its window closes; the tray provides Open and Quit. Android keeps the same
   Files engine alive in a connected-device foreground service and shows an
   ongoing notification. This setting can be changed in Sync. Force-stop or OS
   shutdown still stops the application; boot auto-start is not implemented.
9. Pause stops synchronization. Resume reconciles changes. Stop sharing retains
   files. Forgetting an externally chosen Windows folder or an Android Documents
   folder removes its app entry while retaining its files.

The initial limits remain eight configured folders and three active peer devices.
Previous app-private folders remain usable. On Android, **Place in Documents**
connects an existing folder to the public Documents location after the owner grants
access. Android public files survive uninstall; its private engine/index, retained
versions and journal do not.

Android's document URIs cannot be used as ordinary filesystem paths by the pinned
engine. A journaled adapter therefore maintains a private working copy as well as
its public Documents copy for selected files. Allow storage for both copies and
retained versions. Hashes and bounded streaming copies detect conflicting edits;
both versions are retained. Lost grants or a missing root report an unavailable
location instead of being treated as empty folders. Interrupted public document
replacements retain a recovery record before any rename.

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

Build 6 fixes false location-change errors caused by aliases in the app-support
path. Private file management uses the resolved root without rewriting saved
engine locations or requiring new folder invitations. All 34 Files tests pass,
including a directory-alias regression for restored selective grants, browsing,
edits, restart and confined local-copy removal. Two opt-in physical tests remain
skipped. In manual Windows/Android testing, the owner confirmed the location
error is resolved, automatic file updates work, selective sync keeps only the
chosen Android copies, and deletions propagate to the other device. Extended
background behavior remains a separate check.

Build 5 passed 33 Files tests with the pinned native engine enabled. The live
folder test uses three isolated replicas and verifies nested directory selection,
literal filenames, global-index visibility without download, guarded eviction
without a remote deletion, automatic external edits/deletes, unavailable source
paths and restart. Document-adapter tests cover two-way changes, conflicts,
permission loss and journal reload using synthetic document storage. Both native
release bundles compile. The build 5 APK was delivered through approved Files
Send with a verified recipient receipt; this delivery does not establish physical
validation of its new Android Documents or background behavior.

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
