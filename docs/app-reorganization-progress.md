# App reorganization: implementation status

Branch: codex/reorg-app. Updated October 24, 2026.
The app split and private-service networking foundation are implemented.
This is a development migration. Foreground Files Send works on Android and
Windows; folder Sync now has real-engine and physical phone/laptop checks.
Drive and extended device validation remain pending. The owner installed the node update; the physical checks below
cover the private path, Internet VPN coexistence and actual file transfers.

## Implemented

- Three Flutter projects: apps/core, apps/vpn and apps/files, with shared
  protocol, Core SDK, UI and optional VPN feature packages in one Pub workspace.
- Core retains its Android ID and Windows storage product metadata. Companion
  apps have distinct identities and cannot import Core's private enrollment,
  pairing, owner session or vault implementation.
- Core owns management and private connectivity; VPN owns its own Internet
  traffic key and system tunnel. Files implements Send and two-device folder
  Sync; Drive remains a clearly marked placeholder. See [Files Sync](files-sync.md)
  for the bundled Syncthing engine, private bridge, approval and platform limits.
- Scoped broker control: Android verifies caller UID, publisher and package;
  desktop uses a protected per-user endpoint (a local-user trust boundary).
  Controls have a 16 KiB UTF-8 budget, 16 pending operations and 20-second
  deadlines. Timed-out dispatched operations retain their slots until settled.
- Explicit VPN/Files grants. Revoking Files closes its streams, invalidates
  tickets/pending work and removes its receiver. A background check supplements
  the immediate UI notification.
- Production Core-to-native integration: a private child process hosts
  WireGuard/gVisor without an OS TUN or default route. Keys travel over its
  anonymous control pipe, rather than process arguments. Core starts/stops and
  verifies the connection using a nonce probe.
- The SDK exposes full-duplex private streams through pinned TLS 1.3 loopback
  sockets. File bytes bypass Binder/JSON control messages. Tickets are single
  use, capability scoped, bounded and short lived. Receiver lease IDs guard
  against stale address reuse.
- Android foreground hosting and APK-owned native executable packaging. The
  optional EasyPrivacy VPN excludes Core's UID to keep its encrypted private
  outer connection independent of that full tunnel. Previous VPN connection
  controls are collapsed for migration.
- Additive node v2 membership/discovery/receiver APIs. Private-service keys and
  addresses are separate from Internet/Home peers; parent revocation removes
  every purpose and receiver grant.
- Explicit receiver firewall policy: private peers reach only the overlay probe
  and active Files receivers. Other private forwarding and core-local access
  are dropped. Receivers expire after 120 seconds and are renewed by Core.
- Independent network-setup mode has no Internet NAT/uplink/DNS. Existing
  Internet deployments retain schema-1 settings and behavior. vpn-setup can
  later enable an Internet exit while preserving network identity.
- peers.pre-private.json snapshots legacy peer state before the first
  purpose-aware write. Update/rollback steps are in
  [the node upgrade guide](private-network-upgrade.md).

## Verified for this slice

- All 53 Flutter tests, formatting, analysis and dependency/identity boundaries.
- The Dart SDK against two actual Windows native helper processes: 3 MiB
  WireGuard transfer, SHA-256 integrity, full-duplex receipt, certificate-pin
  rejection, ticket replay denial, receiver closure and capability revocation.
- Node and native-runtime Go race tests and vet.
- Three isolated real-kernel network suites: Internet NAT/DNS/IPv6/revocation;
  routed Home exit/outage/restart; private-only receiver transfer, probe,
  port/peer isolation, lease expiry/removal/revocation and firewall cleanup.
- Disposable Ubuntu 24.04.4 amd64 package tests: baseline 1.0.0 upgrade,
  unprivileged TLS/admin operation, systemd unit validation, helper capability
  positive/negative controls, UFW behavior, and state preservation through
  upgrade/remove/reinstall/purge. Core identity, enrollment database, VPN key,
  endpoint, subnet, legacy peers and private permissions were retained.
- Development Debian packages 1.0.1~reorg1 for amd64 and arm64. The arm64 package
  was cross-built and inspected; its installation was not run on ARM hardware.
- Core 1.0.0+9 and VPN 1.0.0+2 ARM64 release APK builds, with Core's pairing and
  private-runtime artifacts included. The phone was disconnected for these
  builds; their subsequent install is recorded below.
  Package IDs, version codes and publisher signatures were verified. The APK's
  runtime matches the NDK-stripped staged binary.
- Native runtime binaries built for Android ARM64, Windows x64 and Linux x64.

Earlier foundation checks also built Windows VPN/Files bundles and a Linux Core
bundle/desktop Debian package. Those earlier bundles predate this private-data
slice. The current Windows Core bundle and its pairing DLL were subsequently
built and exercised as recorded below.

## Remaining gates and follow-on work

- Complete outages, longer background operation and additional VPN providers/
  settings remain further private-path checks. Wi-Fi/mobile handovers and
  Proton VPN coexistence passed the additional test below. The owner deferred
  extended screen-lock testing to ongoing personal use; it is not marked passed.
- Full Android caller-denial coverage, device packet-level routing/leak checks,
  production signing/key rotation and migration release testing.
- Extended folder-Sync validation, Drive and hosted service installation. Send needs
  further OS-kill/background, large-file, physical interruption and production
  release validation. Its new application encryption protocol also needs
  independent security review before a production release.
- Automatic client startup at boot and complete crash/OS-kill recovery remain
  future work. A stopped private runtime can be restarted from Core.

## Physical Sync and streamed Android selection, October 24, 2026

- Updated the attached Pixel 10 to Files 1.0.0+3 and passed the real Core path:
  folder approval, 4 MiB laptop-to-phone with native export/SHA-256, phone
  replacement with laptop SHA-256, deletion, paused-folder isolation and resume.
- Passed Windows engine stop/start, phone force-stop/relaunch without another
  invitation, and a verified 4 MiB Send while Sync remained connected.
- Stop sharing preserved the phone's local folder. Its exported copy matched
  SHA-256 after the restart checks; explicit Delete local copy then removed it.
- Found that file_selector_android's selection path allocated a file-sized byte
  array and could return an empty file when its document provider reported an
  unknown size. Replaced Android selection with a 64 KiB native worker-thread
  copy to private cache, returning path/name only. Both modes now read the actual
  cached file length. Incomplete Sync imports cannot replace existing files.
- Built and installed Files 1.0.0+4 with the same development publisher. A
  deliberately `_size=NULL` document delivered all 4 MiB through phone-to-laptop
  Send and through Sync replacement, with the expected hashes. Both use the
  normal Android system picker. The Windows counterpart is an opt-in production
  provider harness, rather than its native file picker.
- All 24 ordinary Files tests and analysis passed, including picker cancellation,
  actual staged size, bounded reads, and failed-import preservation. Other app
  sources are unchanged from the preceding workspace checks. Both Android and
  Windows release artifacts were refreshed.
- Removed generated public test folders, received copies and Sync links; restored
  the phone's original keep-awake setting. Selected-source cache copies follow
  the new eight-copy/24-hour-on-selection policy. Core's private connection and
  enrollment were retained. Extended screen-lock testing remains deferred.

See [Files Sync](files-sync.md) for the opt-in physical test procedure.

## First folder Sync implementation, October 24, 2026

- Bundled pinned Syncthing v2.1.7 for Windows x64 and Android ARM64. The engine
  has loopback-only networking and no discovery, public relay, NAT/STUN,
  telemetry or self-update path. Its original TLS bytes pass through Files'
  authenticated Core streams; the installed node APIs are sufficient.
- Added explicit folder invitations and pinned engine identities, private
  per-core storage, import/replace, browsing/export, confirmed file deletion,
  pause/resume, and stop-sharing with a separately deletable retained copy.
  Persisted engine grants start paused until reconciled with Files' manifest.
- Send and Sync share the receiver without keeping Send acceptance enabled.
  A socket-backed regression passed an approved Send while Sync remained open.
- Two actual engines passed two-way edits, deletion propagation with retained
  versions, and independent offline changes creating a conflict copy through
  encrypted bridges. Restart preserves identity and loopback-only settings.
- All 77 ordinary Flutter tests across apps/SDK passed, plus the two opt-in
  real-engine tests. Formatting, analysis and app dependency boundaries passed.
  A Windows kernel job test verified that closing the owned handle terminates
  the engine child; normal shutdown still requests a graceful database flush.
- Foreground use and app-owned folders are the initial scope. Arbitrary Android
  document trees, background hosting, multi-peer folders and version restore
  remain future work. Drive is still unavailable.
- Android release and Windows release packages were built with engine and
  third-party notices. The Android publisher matches existing Core/VPN builds.
  The phone was absent from ADB during these builds; the new APK has not been
  installed or physically verified. Existing Send device results below refer
  to the preceding Files build.

See [Files Sync](files-sync.md) for architecture, reproducible builds and checks.

## First Files Send implementation, October 24, 2026

- Added paired-device discovery, explicit receiving controls, native file
  selection, authenticated sender identity, recipient approval, progress,
  cancellation, verified completion receipts and explicit Save a copy.
- File bytes and metadata use fresh authenticated X25519/HKDF/AES-GCM sessions
  above the existing Core streams. No Files seed or Core enrollment key crosses
  the broker. The node stores receiver metadata rather than file payloads.
- Receiver storage is private, uses fixed internal names, retains at most eight
  files and supports explicit retry/resume. Re-selecting the same file after a
  sender restart also resumes a matching partial. Copies older than 24 hours
  are cleaned on opening Files or accepting another file. Sync/Drive are unchanged.
- Added scoped Core handshake delegation and paginated device discovery, with
  grant/peer/signing tests and companion liveness expiry for abandoned receivers.
  The installed VPS 1.0.1~reorg1 APIs suffice; no additional node update was needed.
- Built Windows Core/Files release ZIPs and ARM64 Core 1.0.0+10 / Files 1.0.0+2
  APKs. The APK publishers match the existing Core/VPN installation. Updated the
  connected phone in place and retained enrollment and Files access.
- All 70 ordinary Flutter tests, formatting, analysis and import boundaries
  passed. Real-socket tests cover empty/one-byte/8 MiB transfers, rejection,
  interruption/resume, local and authenticated remote cancellation, corruption,
  altered sources, unsafe metadata, delegation binding and retention.
- Physical laptop-to-Pixel transfer: the normal Files app displayed the sender
  and 8 MiB offer; accepted through its UI. Both endpoints verified completion.
  Used Android's system save dialog to save to local Downloads; the saved copy's
  SHA-256 matched the generated fixture.
- Physical Pixel-to-laptop transfer: selected that generated file using Android's
  normal file picker, sent through Core, and verified the full 8 MiB and receipt
  on the laptop. The phone displayed recipient verification. The laptop used the
  production provider in an opt-in test harness rather than its native picker.
- The isolated packaged Windows Core broker startup/authentication test also
  passed. Other Internet VPNs were not enabled for these Send tests.

See [Files Send](files-send.md) for behavior, wire format and remaining limits.

## Updated Android install, October 24, 2026

- Updated the connected Pixel 10 in place to Core 1.0.0+9 and VPN 1.0.0+2
  using the verified release APKs. Both Android installations succeeded and
  their package version codes were confirmed. Both apps launched.
- Core retained its enrollment, reconnected automatically and retained the
  existing VPN capability grant. The new private connection controls and the
  collapsed legacy VPN migration panel were visible.
- At installation, the owner confirmed the node update had not yet been applied. Against
  the older node, Start private connection displayed the expected upgrade
  guidance, returned to stopped state and cleared the service's started/
  foreground state. The management connection remained connected.
- This initial check verified installation and the older-node failure path.

## Updated-node Android smoke test, October 24, 2026

- After the owner applied the VPS update, Core reported 1.0.1~reorg1 and
  remained connected using the retained enrollment.
- Verified private connection checks on the phone and two stop/start cycles,
  including one while EasyPrivacy VPN was active. Startup completed its
  end-to-end 32-byte WireGuard nonce check after each reconnect.
- Observed the APK-packaged native child process running under Core and the
  connected-device foreground service active. Stop removed the child process
  and cleared the service's started/foreground state; restart created one new
  runtime. The private connection also persisted through short backgrounding
  and app switching.
- EasyPrivacy VPN connected with a successful handshake and nonzero receive/
  send counters. Core management and its private connection remained available
  alongside it. Repeated the private check with both enabled.
- Disconnected the temporary Internet VPN test and checked the private path
  again. Restored the initial state: private connection enabled, Internet VPN
  disconnected, Core screen visible.
- This was a quick functional test, not a packet-level Internet/DNS/IPv6 leak
  test, a physical Files receiver transfer, a long screen-lock/recovery test,
  or a third-party VPN coexistence test.

## Network switching and Proton VPN, October 24, 2026

- Began with Wi-Fi disabled, mobile data enabled, private connection enabled
  and both Internet VPNs disconnected. Always-on VPN was unset and lockdown
  disabled; these settings were retained.
- Enabled saved Wi-Fi and confirmed it became the validated physical default
  network. Disabled data on the active subscription to check Wi-Fi alone, then
  restored mobile data and disabled Wi-Fi. Core management stayed connected;
  private connection checks completed without displayed errors on both paths.
- Connected the existing Proton VPN 5.20.98.0 free profile. Proton showed
  Protected, its WireGuard foreground service was active, and Android exposed
  a connected VPN network. Repeated Core's private connection check over mobile
  data, then Wi-Fi alone, then mobile data again while Proton remained active.
  Core remained connected and the checks completed without displayed errors.
- Core's native runtime retained the same PID throughout these handovers and
  Proton connect/disconnect. No manual private-connection restart was used.
- Disconnected Proton and verified the private connection again. Restored
  mobile data enabled, Wi-Fi disabled, Internet VPNs disconnected and Core's
  private connection enabled. Core's screen was left visible.
- VPN by Google was left unconfigured and was not enabled or used. The owner
  explicitly excluded it from testing due to privacy concerns.
- These are functional handover/coexistence checks for this device and Proton
  profile. They do not establish packet-level leak behavior or compatibility
  with every provider, protocol, split-tunnel or lockdown setting.

## Windows Core and physical Files transport, October 24, 2026

- Built the Windows x64 pairing DLL from the unchanged Rust sources using the
  MSVC toolchain. The pairing builder can now select Windows without requiring
  the Android NDK or Android Rust targets.
- Corrected Windows startup so the Core UI and its broker use separate instance
  mutexes. The broker keeps its Flutter/plugin host hidden and creates no VPN
  tray. A duplicate broker exits without interrupting the original.
- Built the Windows Core release bundle with the pairing DLL and private runtime.
  Its isolated packaged-broker smoke test passed authenticated RPC, missing-token
  rejection and duplicate-launch handling without reading owner enrollment.
- The real Windows Core retained its existing enrollment, connected to the
  owner's updated VPS and started its private connection. Its nonce probe passed.
  The owner enabled Files access in Windows Core; the phone also had Files access.
- An opt-in Files integration test on the attached Pixel 10 sent 8 MiB to a
  receiver opened through the Windows SDK, then received 8 MiB back. Both ends
  passed SHA-256 checks and peer receipts. Data used bounded 64 KiB chunks;
  the fixture did not read or write personal files. The receiver was removed
  when the test completed. Neither device needed an Internet VPN for this test.
- Replaced the phone's temporary test build with the normal ARM64 Files release
  APK after checking its publisher against Core/VPN. Its Send/Sync/Drive shell
  launched, then the phone returned to Core. Private connectivity remains on;
  EasyPrivacy VPN and Proton are disconnected. The rebuilt Windows Core also
  retained enrollment and Files access and passed its private probe after restart.
- The Windows Dart client also passed enrollment against disposable Linux Go
  nodes, reconnect after node restart, durable revocation, and substituted-core
  identity rejection. Removing an unused VPN-feature import from CoreClient
  restored the command-line client's ability to compile without Flutter UI.
- Workspace formatting, analysis, import boundaries and 52 ordinary tests passed.
  The physical stream fixture is opt-in; normal checks skip it. The separate
  native-process test remains opt-in and was already verified above.

This proves the shared transport between actual devices. The normal Files app
still has no file picker, recipient approval, transfer history or Send engine.
See [the physical stream procedure](physical-private-stream.md) to repeat the test.

## First physical Android install, October 23, 2026

- Pixel 10: Core 1.0.0+8 updated the existing application in place. Its enrollment
  survived, and the app reconnected to the owner's existing core node.
- VPN 1.0.0+1 installed separately with the same verified publisher certificate.
  Android granted the signature-protected broker permission, and the companion
  bound to CoreBrokerService. Both app processes launched without fatal errors.
- An ADB shell caller could not start CoreBrokerService: Android rejected it
  for lacking CORE_BROKER. This checks the service entry permission, not every
  per-message caller validation case.
- During the owner's phone testing, the separate VPN service became active and
  showed VPN connected. The owner confirmed enabling VPN access in Core and
  successfully connecting with the new VPN app. Core's management screen
  subsequently remained connected with VPN capability access enabled.
  The owner also reported that Internet access and DNS appeared to work through
  the new VPN. Routing/leak checks were not independently measured in these
  install checks.
- The owner reported that all five manual reconnect checks passed: three
  disconnect/connect cycles, Wi-Fi/mobile transitions, a 30-second complete
  network outage, dismissing/reopening both app screens, and five minutes with
  the screen locked. Recovery timings and packet-level routing/leak measurements
  were not captured; these are owner-observed functional results.
- The ARM64 pairing library was recovered from the phone's installed, signed
  1.0.0+7 APK. Native pairing source is unchanged from 98fcfce; required exports
  and the packaged library's SHA-256 were checked. This is test-artifact reuse,
  not a new Android native source build.
- The packaging command now supports `-TargetPlatform android-arm64` and checks
  that every selected pairing library is present in the finished Core APK.
  Default packaging still requires all three supported Android architectures.
- End-to-end VPN routing, private streams, external-VPN coexistence, and Android
  background/recovery scenarios are not implied by these launch checks.
- At that install, Core's screen still included its inherited VPN controls. That panel
  reports only the legacy Core-hosted tunnel; the separate VPN app's state is
  authoritative for the new capability. The current code collapses that panel
  under Previous VPN connection.

Repeatable commands:

- tool/check-workspace.ps1: formatting, analysis, application import boundaries,
  Core regression tests, app widget tests, and broker tests.
  Set EASYPRIVACY_CORE_RUNTIME to the absolute built helper path to also run
  the native-process/Dart SDK stream integration test (otherwise it is skipped).
- In core/: go test -race ./... and go vet ./... after building the existing Rust
  pairing library with core/scripts/build-pairing.sh.
- In native/core-runtime/: go test -race ./...
- tool/build-android.ps1 -App core|vpn|files (Core requires pairing/runtime libraries).
  Add -TargetPlatform android-arm64 for the current phone test artifacts.
- tool/build-windows.ps1 -App core|vpn|files (Core/VPN require native artifacts).

The automated suites do not modify a real owner deployment. The separately
authorized phone installs above preserve app data and are recorded independently.
Full Android caller-denial, real VPN routing, and foreground/background behavior
still require their device integration checks.

See app-reorganization-plan.md for the full staged design,
../protocols/broker/v1/README.md for the implemented control API, and
../protocols/core/v2/README.md for private-peer semantics and rollback.
