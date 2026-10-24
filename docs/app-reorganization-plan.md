# EasyPrivacy: Core, VPN, and Files implementation plan

Status: implementation started. See [current progress](app-reorganization-progress.md).

Baseline: branch codex/reorg-app, commit 4dba5c5, based on dev.
Prepared: October 23, 2026.

This plan records the agreed product direction and proposes the repository
organization, source-file ownership, migration, and implementation sequence.
This document preserves the original file-ownership proposal; some paths are now
implemented. The optional shared VPN module is named easyprivacy_vpn_feature.
Engine choices and platform hosting
details remain subject to the specific prototype gates identified here.

## 1. Agreed direction and scope

Create three independently installable applications:

1. EasyPrivacy Core: enrollment, management, and shared private connectivity.
2. EasyPrivacy VPN: optional full-device Internet VPN capability.
3. EasyPrivacy Files: device transfers, folder synchronization, and private Drive.

Core owns an embedded private-service tunnel and an authenticated local connection
broker. Capability applications explicitly use that broker through a shared SDK;
installing Core does not automatically redirect their normal network sockets.
VPN additionally owns the operating system's full-tunnel VPN interface.

Preserve the existing principles: user-owned infrastructure and credentials,
no required EasyPrivacy cloud account, replaceable open-source service engines,
and independently usable/exportable service data. Initially, a deployment still
represents one owner with multiple independently revocable devices. Household
roles and federation are outside this implementation.

All remote capability traffic initially passes through the owner's core node.
For Send, "direct" means selecting a recipient without a shared folder or
persistent server copy. It does not initially mean a network path bypassing the
core. General Internet routing remains independently optional.

Keep all three applications and the Linux node software in this repository.
Separate application projects and releases do not require separate repositories.
Do not build an arbitrary executable-plugin marketplace in this round.

## 2. The applications

### EasyPrivacy Core

Purpose: the owner's management application and the local foundation required
by the other EasyPrivacy applications.

User-facing responsibilities:

- Pair this device with a core, verify its identity, and reconnect using the
  existing device enrollment rather than repeatedly requesting a password.
- Manage paired devices and revocation; preserve terminal recovery.
- Show core, node, private-connectivity, and individual service health separately.
- Add/configure supported service nodes and install supported service capabilities
  onto the selected node. The first catalog contains supported recipes and client
  installation links, not a custom mobile app-store installer.
- Manage local capability grants, service configuration, and connection settings.
- Preserve the current Linux home-service setup/start/stop controls.

Runtime responsibilities:

- Own the enrollment identity, pinned core identity, secure profile, and
  management sessions.
- Own a private-service WireGuard identity, separate from Internet VPN traffic
  keys, and the embedded userspace transport.
- Expose authorized connection, discovery, provisioning, and status operations
  to capability apps through the local broker.
- Support receiver registration so another device can initiate an authorized
  file transfer through this device's outbound connection.
- Keep runtime lifetime independent of the visible Flutter screen. Closing a
  screen must not implicitly sign out or terminate active capability operations.

Suggested navigation: Overview, Services, Devices, Nodes, Settings.

Platforms: preserve Android, Windows, and the existing Linux management surface.
Android and Windows are the first broker integration targets. Linux receives a
per-user broker adapter before Files is declared supported there.

### EasyPrivacy VPN

Purpose: an optional Internet-routing application that depends on Core for
enrollment and authorized provisioning.

- List/select the existing VPS and Home exits.
- Connect/disconnect the system VPN and show handshake, connection state,
  traffic statistics, notification/tray controls, and errors.
- Own its WireGuard traffic private keys and VPN preferences in its own vault.
- Request a purpose-specific VPN profile through Core using only its public
  traffic key; never receive Core's enrollment seed or owner management token.
- Preserve local Disconnect even if Core or the remote management API is
  unavailable.
- Preserve the existing behavior distinguishing transient management outages
  from explicit authorization rejection.
- Disconnect only its Internet VPN peer; leave Core's private-service connection
  and unrelated services intact.

Suggested navigation: Connection, Internet Exit, Settings.

Platforms: preserve the existing Android and Windows full-tunnel implementations.
Ordinary Linux full-tunnel client support remains a separate milestone; the
current Linux home-service GUI is not such a client.

On Android, activating this system VPN replaces another active system VPN in
the same user/profile. Core's embedded connection does not occupy that slot.
Coexistence with an external VPN still depends on that provider permitting Core's
network traffic; it is a tested compatibility goal, not a universal guarantee.

### EasyPrivacy Files

Purpose: one file-management experience with three independently enabled modes.

| Mode | Behavior | Storage and availability |
| --- | --- | --- |
| Send | Select files, choose a paired device, approve receipt, track progress, cancel/resume as supported. | Source and recipient retain files. Core forwards streams without a persistent payload copy. Both endpoints must be online. Offline delivery is deferred. |
| Sync | Select a folder, participating devices, sync direction, and conflict/versioning policy. | Selected replicas retain data; no central storage server is required. An optional always-on node can be another replica. |
| Drive | Browse, upload, download, organize, and optionally cache files from a chosen storage node. | The storage server holds the authoritative copy. Other client devices can be offline. Home hardware or a user-owned VPS can host it. |

Use the shared SDK to discover authorized services and open private connections.
Files owns file/folder permissions, transfer and sync jobs, caches, local
preferences, and backend-specific client credentials when required. It does not
own device enrollment or another WireGuard engine.

Suggested navigation: Send, Sync, Drive, Activity, Settings. Show installation
and setup guidance when a mode is unavailable; do not imply all modes or server
engines are installed merely because Files is installed.

Target Android, Windows, and Linux. Prove Android-to-Windows Send first, then
declare other platform/mode combinations supported as their checks pass.

## 3. Proposed repository layout

Keep the existing Go server directory named core/ for the first migration.
Use "Core app" for apps/core/ and "core node" for the remote server to avoid
confusing these two projects.

~~~text
/
  apps/
    core/
      lib/
        main.dart
        app.dart
        features/{enrollment,devices,nodes,services,settings}/
        runtime/{identity,session,storage,broker,api}/
      android/                 # Core host + broker; no final system VPN service
      windows/                 # Core host + per-user broker integration
      linux/                   # Existing management UI + per-user broker
      test/
      pubspec.yaml
      README.md
    vpn/
      lib/
        main.dart
        app.dart
        features/{connection,exits,settings}/
        runtime/{keys,presence}/
      android/                 # System VpnService and its notifications
      windows/                 # VPN runner and tray
      test/
      pubspec.yaml
      README.md
    files/
      lib/
        main.dart
        app.dart
        features/{send,sync,drive,activity,settings}/
        platform/
        providers/
      android/
      windows/
      linux/
      test/
      pubspec.yaml
      README.md
  packages/
    easyprivacy_protocol/
      lib/src/{core,devices,services,transport,vpn,files,errors}/
      test/
      pubspec.yaml
    easyprivacy_core_sdk/
      lib/src/{broker_client,capability_client,stream_handle}.dart
      android/                 # Client bindings, not the broker host
      windows/
      linux/
      test/
      pubspec.yaml
    easyprivacy_ui/
      lib/src/theme.dart
      lib/src/widgets/
      assets/
      test/
      pubspec.yaml
  protocols/
    broker/v1/                 # Versioned local messages, Android AIDL, fixtures
    core/v2/                   # Additive remote capability/profile schemas
  native/
    pairing/                   # Existing Rust implementation retained
    windows-vpn/               # Existing privileged VPN helper retained
    core-runtime/              # New embedded transport; Go candidate to prove
  core/                        # Existing Go node module, CLI, tests, packaging
  services/
    catalog/                   # Capability metadata, node/runtime requirements
    recipes/                   # Selected pinned engine installation definitions
  tool/                        # Workspace checks, builds, staging, native builds
  integration_tests/           # Multi-app, migration, transport, and engine checks
  assets/                      # Existing canonical brand artwork
  docs/
  pubspec.yaml                 # Dart workspace definition
  pubspec.lock                 # One committed workspace dependency resolution
  analysis_options.yaml
  VERSION
~~~

Use a Dart Pub workspace with explicit application/package members and
resolution: workspace in each member. Retain separate app pubspecs and app
versions while resolving shared Dart dependencies once. Migrate dependency
constraints from the existing lockfile before replacing it with the root
workspace lockfile; do not introduce dependency upgrades during the file move.
The existing SDK constraint must be checked with the installed toolchain.
[Pub workspaces](https://dart.dev/tools/pub/workspaces)

## 4. Shared code versus shared runtime state

Shared source is reused through packages. Applications must not import another
application's lib/ directory, read another app's secure storage, or share an
Android UID to exchange credentials.

| Location | Consumers | Contents and boundary |
| --- | --- | --- |
| packages/easyprivacy_protocol/ | All three apps, SDK, contract tests | Public DTOs, validation, service IDs, status/error types, version negotiation, purpose-specific transport profiles. No enrollment secrets or vault access. |
| packages/easyprivacy_core_sdk/ | All three apps' frontends; VPN and Files as external broker clients | Broker interface, service discovery, authorized connection handles, provisioning requests, events, reconnect/cancellation. Core can use an in-process host adapter. No owner session token or private-key export API. |
| packages/easyprivacy_ui/ | All three apps | Theme, common status/progress/error widgets, logo asset, shared license-display components. No feature controller or network policy. |
| protocols/ | SDK, broker hosts, node implementation, tests | Canonical message definitions and fixtures. Dart and Go implementations are checked against these contracts; Go files cannot be imported by Dart. |
| assets/ and tool/ | All relevant build targets | Brand sources, repeatable icon generation, common build/check/staging logic. Generated icons and packaged notices remain application-specific outputs. |
| native/pairing/ | Core app and core node only | Existing PAKE implementation, version pins, tests, notices. Being a shared native source does not mean shipping it in VPN and Files. |
| apps/core/lib/runtime/ | Core only | Enrollment signing, pairing, private profile storage, owner API client, session management, capability authorization. |
| native/core-runtime/ | Core's platform hosts only | Embedded tunnel engine and streaming primitives. It is not linked into every capability app. |
| native/windows-vpn/ | Windows VPN only | Driver/helper implementation and its security tests. |

Core may invoke authorized remote operations for capability apps or deliver
scoped backend credentials where necessary. Sharing a type definition never
authorizes an operation. Keep app grants distinct from device enrollment:
revoking one capability grant need not revoke the whole device.

## 5. Current Dart source migration

Paths in the first column are the existing files at the baseline commit.
Destination groups below identify ownership; this is not a request to copy the
same implementation into multiple applications.

| Existing file | Proposed destination/action |
| --- | --- |
| app/lib/main.dart | Split into apps/core/lib/main.dart and app.dart, enrollment screens/controllers under features/enrollment/, management screens under features/devices/ and features/services/. Extract VPN composition into apps/vpn/lib/app.dart. New Files gets its own entrypoint. |
| app/lib/core_client.dart | Extract CoreAddress, CoreStatus, PairingCode, PairedDevice, validation, and public errors into easyprivacy_protocol. Move pinned HTTPS and enrollment/device API implementations into apps/core/lib/runtime/api/. Split VPN endpoint calls into a Core-owned VPN provisioning adapter. SDK clients do not receive the owner token. |
| app/lib/core_controller.dart | Move session implementation into apps/core/lib/runtime/session/core_session.dart; adapt Core UI to a controller under apps/core/lib/features/. Replace its VPN convenience methods with broker capability operations. VPNController must not import this controller. |
| app/lib/profile_store.dart | Move CoreProfile and private storage to apps/core/lib/runtime/storage/. Split a nonsecret CoreSummary DTO into easyprivacy_protocol. Preserve the existing secure-storage key during migration. |
| app/lib/device_identity.dart | Move to apps/core/lib/runtime/identity/device_identity.dart. Its signing seed and signing methods remain Core-owned. |
| app/lib/pairing_client.dart | Move to apps/core/lib/runtime/identity/pairing_client.dart; update imports to shared public models without changing PAKE, pinning, or confirmation behavior. |
| app/lib/native_pake.dart | Move to apps/core/lib/runtime/identity/native_pake.dart; retain linkage to native/pairing/. |
| app/lib/device_dialogs.dart | Move/split into apps/core/lib/features/devices/. General dialog styling can use easyprivacy_ui; management actions stay Core-only. |
| app/lib/service_node.dart | Split ServiceNodeStatus into shared public models, LinuxServiceNodeClient into apps/core/lib/features/nodes/linux_service_node_client.dart, and ServiceNodePanel into that feature's UI. Preserve the root-authorized CLI boundary. |
| app/lib/vpn_controller.dart | Move controller to apps/vpn/lib/features/connection/vpn_controller.dart; replace CoreController dependency with SDK status/provisioning interfaces. Extract SecureVPNKeyStore into apps/vpn/lib/runtime/keys/. |
| app/lib/vpn_backend.dart | Move to apps/vpn/lib/features/connection/vpn_backend.dart; preserve platform helper validation and local disconnect. This remains the system VPN backend, not the new private broker. |
| app/lib/vpn_panel.dart | Move/refactor into apps/vpn/lib/features/connection/connection_screen.dart and supporting widgets. Core can display a non-controlling capability summary and launch VPN. |
| app/lib/vpn_presence.dart | Move into apps/vpn/lib/runtime/presence/ and settings UI; notification/tray preferences remain VPN-owned. |
| app/lib/vpn_types.dart | Split public VPNExit, validated full-tunnel VPNProfile, and TunnelStatus DTOs into easyprivacy_protocol. Keep VPNKey/private-key creation in apps/vpn/lib/runtime/keys/. Replace VPNNodeClient's owner-token interface with Core-owned remote API plus SDK-facing provisioning interface. |
| app/lib/src/theme.dart | Move to packages/easyprivacy_ui/lib/src/theme.dart with a stable public export. |
| app/assets/easyprivacy-mark.png | Move the common runtime asset into packages/easyprivacy_ui/assets/; update package-qualified asset references. Keep original artwork in assets/. |
| app/assets/native-licenses.txt | Replace the monolithic bundle with per-app generated notices covering only bundled dependencies, exposed through the common license UI. |
| app/pubspec.yaml and app/pubspec.lock | Replace the single app definition with the root workspace plus three app and three shared-package definitions. Move dependency resolution to root as described above. |
| app/analysis_options.yaml | Use as the basis of root analysis_options.yaml; each member includes the common rules and only necessary local exceptions. |

Important behavioral changes within this extraction:

- Current main.dart creates VPNController and VPNPresenceController and couples
  Forget to VPN disconnect/key deletion. Replace this with a broker-coordinated
  lifecycle operation covering all grants and transport purposes.
- Current CoreController.dispose() can sign out. Put session lifetime in the
  Core-owned runtime so destroying a screen does not sign out active clients.
- Existing VPNProfile validation requires full default routes. Keep that strict
  validation for Internet VPN profiles and introduce a separate private-service
  profile; do not make the old validator accept arbitrary routes indiscriminately.

## 6. Android, Windows, and Linux source ownership

### Android

Preserve org.easyprivacy.easyprivacy as the Core application's Android ID during
the transition. Proposed new IDs: org.easyprivacy.vpn and org.easyprivacy.files.
These names are implementation defaults, not a reason to move existing user
credentials to a different Android sandbox.

| Existing path | Planned action |
| --- | --- |
| app/android/settings.gradle.kts, build.gradle.kts, gradle.properties, gradle/wrapper/gradle-wrapper.properties | Relocate with Core and create independent VPN/Files application scaffolds. Keep toolchain versions aligned initially; package shared client bindings through easyprivacy_core_sdk. |
| app/android/app/build.gradle.kts | Core retains its application identity and pairing/native integration. Move the system WireGuard tunnel dependency to VPN. Add distinct app labels, IDs, signing configuration, and plugin dependencies for each app. |
| app/android/app/src/main/AndroidManifest.xml | Core removes final system VPN declarations and adds the authenticated broker host. VPN receives VpnService, VPN foreground-service, and VPN notification declarations. Files receives only the storage, share, notification, and background-work components it actually needs. |
| app/android/app/src/main/kotlin/org/easyprivacy/easyprivacy/MainActivity.kt | Keep a minimal Core Flutter host. Extract its VPN method-channel, permission, and presence handlers into VPN's host/plugin. Add Core's broker lifecycle bridge separately. |
| Same directory: VpnRuntime.kt, VpnForegroundService.kt, VpnNotifications.kt | Move to apps/vpn/android/app/src/main/kotlin/org/easyprivacy/vpn/; update package names, intents, notification targets, and channel ownership. |
| app/android/app/src/main/res/drawable-*/ic_vpn_status.png | Move to VPN's resource tree. |
| app/android/app/src/main/res/mipmap-*/, drawable-*/ic_launcher_foreground.png, values*/styles.xml, drawable*/launch_background.xml | Core retains its own resources. Generate distinct VPN and Files launcher assets from shared brand sources; each app keeps its own manifest/resource identity. |
| app/android/app/src/debug/AndroidManifest.xml and src/profile/AndroidManifest.xml | Relocate Core versions and create app-specific development manifests; do not propagate VPN services or broad storage permissions to every app. |

New Android host/client sources:

- apps/core/android/app/src/main/kotlin/org/easyprivacy/easyprivacy/broker/CoreBrokerService.kt
- apps/core/android/app/src/main/kotlin/org/easyprivacy/easyprivacy/broker/CallerAuthorizer.kt
- packages/easyprivacy_core_sdk/android/src/main/kotlin/org/easyprivacy/sdk/CoreBrokerClient.kt
- protocols/broker/v1/android/ containing the shared AIDL contract, including
  IConnectionBroker.aidl and stream-handle definitions
- Files-owned document-picker, share-sheet, transfer notification, and job
  adapters under apps/files/android/

Use explicit binding, a signature permission for first-party apps, caller
identity verification, and app/operation grants. Define a release signing and
key-rotation policy. The current Gradle file uses debug signing for release
builds: production IPC trust must not assume that is an adequate publisher key.
Maintaining an Android application ID alone does not preserve upgrade
compatibility if its signing identity changes.

Do not copy the VPN foreground service's systemExempted classification into
Core or Files. Their background work needs its own valid lifecycle and service/
job policy, proven on supported Android versions. A bound service alone does
not promise indefinite background execution.
[Bound services](https://developer.android.com/develop/background-work/services/bound-services),
[background-start restrictions](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start)

### Windows

- Relocate the ordinary app/windows/ scaffold into Core; create separate VPN
  and Files runners with independent executable names and metadata.
- Move app/windows/runner/vpn_tray.cpp and vpn_tray.h to VPN's runner.
- Split VPNTray integration out of app/windows/runner/flutter_window.cpp,
  flutter_window.h, main.cpp, and win32_window.cpp. Preserve shared window
  behavior through reusable plugins/helpers only where useful.
- Update each app's windows/CMakeLists.txt, runner/CMakeLists.txt, Runner.rc,
  resource.h, icons, and runner.exe.manifest for its own products and libraries.
- Core packages pairing and the broker runtime; VPN packages the existing
  native/windows-vpn/ helper; Files packages file-provider integrations.
- Keep the installed EasyPrivacyVPN service/driver identity stable initially.
  Its privileged control pipe must remain separate from the unprivileged
  per-user Core broker pipe.
- Add an authenticated per-user named-pipe broker adapter in Core and matching
  SDK client. Document its local-user trust boundary rather than assuming
  Android signature permissions exist on Windows.

### Linux

- Move app/linux/ and its runner/my_application.cc, runner/CMakeLists.txt,
  top-level CMakeLists.txt, and icons into Core; update desktop identity and
  build paths while retaining the existing home-service control behavior.
- Add the per-user Unix-socket SDK/broker adapter, private socket permissions,
  application grants, and reconnection behavior.
- Keep root-required node setup behind the existing node CLI/helper boundary;
  do not run the Flutter Core UI as root.
- Generate a separate Files runner when Linux file support is implemented.
- Keep the old easyprivacy-desktop package identity or provide an explicit
  transitional package. Do not silently remove the working home-service GUI.

## 7. New shared connection contract and runtime

### Local API

Specify these operations in protocols/broker/v1/ before splitting their hosts:

| Operation group | Proposed operations | Authorization |
| --- | --- | --- |
| Discovery | getBrokerInfo, getCoreSummary, listServices, watchStatus | Approved capability app, limited to its allowed view |
| Connections | openServiceStream, closeStream, registerReceiver, unregisterReceiver | Explicit allowed service/device/purpose; no arbitrary destination proxy |
| VPN | listInternetExits, provisionInternetPeer, removeInternetPeer | VPN grant only; remove only its own purpose-specific peer |
| Lifecycle | requestCapabilityGrant, releaseCapabilityGrant, reportActivity | Explicit caller identity and bounded lifetime |

Return an unsupported-version/feature response and a usable upgrade message
when apps are incompatible. Add cancellation, request IDs, byte/connection
limits, deadlines, disconnect events, and backpressure to the contract.

For Android, pass streaming file descriptors/handles after authorizing a
connection. Do not serialize file payloads into Binder messages. Use corresponding
streaming IPC on desktop. Public endpoint descriptions and stream handles are
shareable; owner keys and management tokens are not.

Native runtime source candidates:

- native/core-runtime/go.mod and go.sum
- native/core-runtime/transport.go: embedded WireGuard/netstack lifecycle
- native/core-runtime/streams.go: bounded outbound streams and receiver dispatch
- native/core-runtime/service_routes.go: authorized destinations and private DNS
- native/core-runtime/transport_test.go and streams_test.go
- Core-owned platform lifecycle hosts and Core runtime credential/session adapters

Go with WireGuard's userspace netstack is the first implementation candidate,
not a completed platform integration. Prove native builds and Flutter/Android
hosting before fixing the ABI. The transport engine needs its traffic key, not
the Core enrollment seed. Keep credential authority in the Core-owned runtime,
independent of the visible UI.
[WireGuard netstack example](https://git.zx2c4.com/wireguard-go/tree/tun/netstack/examples/http_client.go)

Before the workspace move, use small test hosts under
integration_tests/broker_probe/ with isolated node state and test identities.
Do not migrate the owner's installed VPS, phone, or home-node state merely to
validate the prototype. Once the runtime is proven, move its hosts into the
production app projects and retain the probes as integration checks.

Initial stream support can be TCP. Do not promise transparent UDP, arbitrary
third-party apps, or incoming proxy connections. Receiver registration and
private relay/listener behavior must be demonstrated explicitly.

### Routing and failure behavior

- Without system VPN: service app -> Core broker -> embedded tunnel -> core node
  -> authorized service or recipient.
- With an external system VPN: the embedded tunnel's outer network connection
  ordinarily uses that VPN. Filtering, lockdown, blocked UDP, MTU, and reconnect
  behavior are compatibility test cases.
- With EasyPrivacy VPN: coordinate the two connections to prevent routing
  loops, peer replacement, and accidental nested transport. The prototype must
  choose and document how Core's transport socket reaches the node in this mode.
- Use separate WireGuard keys/addresses for independently active service and
  Internet connections. Never run two independent engines using one peer key.
- Service connection failure must not fall back to a public service endpoint.
  VPN exit failure must preserve the current no-silent-exit-fallback behavior.
- Route service DNS through the authorized private connection; do not replace
  all device DNS merely to resolve EasyPrivacy service names.
- Retain the current separate encrypted-hop trust model at the core. Application
  TLS/end-to-end encryption is a separate service/transfer property and must be
  described accurately rather than inferred from WireGuard.

## 8. Core-node and service-host changes

The app split alone cannot deliver the new connectivity model. Keep the Go
module and existing operating-system service names in place initially, and
introduce the following additive boundaries.

| Existing files | Required change/new ownership |
| --- | --- |
| core/internal/node/server.go | Register additive capability, service, and purpose-specific transport APIs. Preserve existing /api/v1 enrollment/VPN behavior for legacy clients. |
| core/internal/node/vpn.go | Retain legacy handlers as adapters; separate Internet exit provisioning from private-service transport provisioning. |
| core/internal/node/devices.go and device_auth.go | Preserve parent device identities; cascade revocation through all child transports, grants, sessions, and receiver registrations. |
| core/internal/node/state.go | Add versioned configuration for networking independent of Internet exit enablement, with explicit migration/defaults. |
| core/internal/vpn/types.go and manager.go | Extract common peer/profile handling into new core/internal/overlay/. Current peers are keyed by DeviceID and replacement removes the old traffic key. Add distinct purpose/instance records under the same enrolled device. |
| core/internal/vpn/linux.go, home_routing.go, site.go | Separate overlay forwarding/access policy from Internet-exit NAT/policy routing. Keep peer isolation except for explicitly authorized service/receiver paths. |
| core/internal/vpn/client.go | Version the typed local helper protocol for new operations; preserve the restricted helper boundary. |
| core/internal/link/client.go | Reuse/update the Go node client for service registration and protocol compatibility as needed. |
| core/cmd/easyprivacy-node/main.go, vpn.go, vpn_host.go | Separate private-network setup from enabling an Internet exit. Preserve current CLI commands as compatibility paths. |
| core/cmd/easyprivacy-node/service.go | Separate the node's outbound network membership from optional Home exit and installed storage workloads; preserve existing enrolled home-node configuration. |
| core/packaging/easyprivacy-node.service, easyprivacy-vpn.service, easyprivacy-service.service, easyprivacy-vpn.tmpfiles | Review permissions, helper operations, runtime directories, and independent enable/disable behavior. Do not rename/remove installed units during the first app reorganization. |
| core/packaging/postinst, prerm, postrm and core/scripts/package.sh | Package additive components and preserve private state, existing node identities, and operator-owned data through upgrades/removal. |

New Go areas:

- core/internal/overlay/: purpose-specific peer registry, transport profiles,
  service routes, validation, migration, and network tests.
- core/internal/capabilities/: service/app grants, bounded operations, revocation.
- core/internal/services/: node/service registry, health, installed versions,
  and a narrow deployment adapter.
- core/internal/transfers/: Send rendezvous/receiver metadata and authorization;
  no persistent payload storage for the initial Send mode.
- Node HTTP adapters for these components, with schemas/fixtures in
  protocols/core/v2/.

A transport record should identify its parent device, purpose, instance,
public key, assigned address, and authorized destinations. Supported purposes
initially include private-services, internet-exit, and service-node.
Internet-exit selection is a property of the Internet record, not the device's
entire membership in the private network.

Keep the existing v1 peer/state format readable during transition. Map legacy
peers to their existing purpose without changing keys or addresses unexpectedly.
Disconnecting one purpose must not delete every peer for that DeviceID.
Revoking the parent device must remove all of them.

Service installation runs on the selected Linux node using constrained
deployment operations. Do not give the public management API a general-purpose
root shell or unrestricted container socket.

## 9. Files implementation and engine selection

Create provider interfaces under apps/files/lib/providers/:

- device_transfer_provider.dart
- folder_sync_provider.dart
- drive_provider.dart

Keep progress, conflicts, job state, and user-visible errors independent of
engine-specific responses. Put public cross-app types in easyprivacy_protocol;
keep engine implementations and private caches in Files or the node adapter.

### Send

Evaluate croc as an existing encrypted transfer engine before adopting it.
Its relay and transport choices must be configured/adapted to the owner's core
and broker rather than default public services or independent tunnel engines.
Do not make the client/server API depend on the engine's product name.
[croc](https://github.com/schollz/croc)

Required behavior: online paired-device list, recipient acceptance, filename/
size metadata, streaming, progress, cancellation, collision policy, integrity
verification, and interrupted-transfer recovery. Keep any temporary partial
file on the recipient; document cleanup and resume expiry. No unbounded core
payload buffering and no silent offline store-and-forward.

### Sync

Evaluate Syncthing for device-to-device folder replicas. Run an optional
always-on replica on a service node only when requested. Scope folder grants,
device IDs, retention/versioning, deletion propagation, and conflict handling.
Synchronization is not a replacement for independent backups.
[Syncthing behavior](https://docs.syncthing.net/users/faq.html)

Prove fixed private endpoints/proxy integration and disable unintended direct
fallback and public discovery/relay paths. Its proxy support is outbound-only;
a private relay or explicit receiver integration may be necessary. A SOCKS
setting alone is not proof of working two-way device synchronization.
[Syncthing proxy support](https://docs.syncthing.net/users/proxying.html)

The original official Android wrapper is archived. Evaluate a maintained
integration or our own wrapper around the engine; do not adopt the archived
application unchanged.
[Original Android wrapper](https://github.com/syncthing/syncthing-android)

Android storage is a separate selection gate: a document-tree URI is not an
ordinary filesystem path. Prove the engine can use the granted storage model,
or explicitly choose app-owned folders/another supported access strategy.
Do not promise arbitrary-folder sync from a picker before this works.
[Android document access](https://developer.android.com/training/data-storage/shared/documents-files)

### Drive

Evaluate Nextcloud as the first self-hosted backend, using its documented file
API/WebDAV where appropriate. Installation must expose its service through
private networking without assuming public DNS or public share links.
Nextcloud's server-backed sync overlaps Sync, but does not by itself implement
the agreed server-independent replica model.
[Nextcloud file access](https://docs.nextcloud.com/server/latest/user_manual/en/files/access_webdav.html)

Required behavior: user-selected node and data location, quotas/capacity,
uploads/downloads, directory operations, per-device client credentials, restart
recovery, application-consistent backup/restore, and compatible engine upgrades.
An already-configured compatible service should eventually be importable through
an adapter rather than requiring a destructive reinstall.

For every engine, record maintenance status, supported platforms, distribution
license obligations, authentication model, broker compatibility, and update/
data-migration strategy before selecting and pinning a release. These candidates
are evaluation targets, not final implementation dependencies.

## 10. Builds, packaging, documentation, and tests

### Existing tooling to change

| Current path | Proposed change |
| --- | --- |
| app/tool/build-windows.ps1 | Replace with tool/build-windows.ps1 selecting core/vpn/files. Stage the required workspace topology, packages, and root lockfile at the existing short build path. Regenerate package metadata there; copying old absolute package_config paths is insufficient. |
| app/tool/build-android.ps1 | Move/generalize to tool/build-android.ps1 selecting an application; emit independently named APKs/AABs and checksums. |
| app/tool/build-linux.sh | Move/generalize to tool/build-linux.sh; preserve the existing Core desktop package upgrade path and add Files packaging when ready. |
| app/tool/build-pairing.ps1 | Move to tool/build-pairing.ps1; update repository-root discovery and stage outputs into Core only. |
| app/tool/build-vpn-windows.sh | Move to tool/build-vpn-windows.sh; update hard-coded app/native output to VPN's native bundle. Keep native/windows-vpn/ source and service compatibility. |
| app/tool/generate-icons.py | Move/generalize to tool/generate-icons.py with explicit app output targets and shared artwork inputs. |
| app/tool/export-notification-icons.py | Move/generalize with VPN as its explicit notification-resource target. |
| app/tool/pairing_smoke.dart and connection_smoke.dart | Move into apps/core/tool/ or integration_tests/core/ with package-based imports; keep test secrets out of process arguments/logs. |
| core/scripts/pairing-smoke.py | Update its hard-coded core.parent/'app' lookup to the new Core app and native output locations. |
| native/pairing/collect-licenses.py and native/windows-vpn/collect-licenses.py | Retain their source ownership; update destinations/composition if they assume one app-wide notice bundle. |
| .gitignore | Replace /app-specific generated/build/JNI ignores with correct apps/, packages/, workspace, and new native-runtime patterns. Continue tracking source lockfiles and generated-free protocol fixtures deliberately. |
| README.md, User-Guide.md, core/README.md, app/README.md | Update current setup/build paths; create one README for each application and explain the Core prerequisite and separate VPN installation. |
| docs/device-pairing.md, home-service-node.md, vpn-indicator-checks.md | Add migration/current-operation notes reflecting the new owners and commands. |
| docs/releases/1.0.0.md and completed milestone records | Preserve historical artifact names and verification claims; add a pointer to new migration docs if useful rather than rewriting history. |

Initially retain root VERSION as the coordinated release version to limit
packaging changes. Keep separate Android version codes and app package metadata.
Negotiate broker/node protocol versions explicitly; matching product versions
must not be the only compatibility check.

New shared tooling: tool/check-workspace.ps1 or a portable equivalent, a
repo-root/short-staging helper, a native-runtime build command, and a check that
apps do not import each other's lib/ or ship another app's private runtime.
Only create platform wrappers actually needed by the build environments.

### Existing tests to move or split

| Current tests | Destination/coverage |
| --- | --- |
| app/test/core_test.dart | Core session/API tests plus easyprivacy_protocol tests for extracted parsing/validation. |
| app/test/pairing_test.dart | Core enrollment/session tests; move reusable nonsecret fixtures out of test-to-test imports. |
| app/test/app_test.dart | Core onboarding/management widgets; add separate VPN/Files app-shell tests. |
| app/test/service_node_test.dart | Core node-management UI and CLI-adapter tests. |
| app/test/vpn_test.dart | VPN controller/backend tests using an SDK fake, not Core's private controller or pairing-test fake. |
| app/test/vpn_presence_test.dart | VPN notification/tray preference and lifecycle tests. |
| native/windows-vpn/config_test.go and security_windows_test.go | Retain and run for helper changes. |
| core/internal/node/*_test.go and core/internal/vpn/*_test.go | Preserve current pairing, revocation, Internet/Home exit and network behavior; add new transport-purpose and compatibility cases. |
| core/scripts/test-vpn-network.sh, test-package.py, smoke.py, pairing-smoke.py | Update only affected paths/protocols and extend the relevant real integration checks. |

New integration coverage must demonstrate:

- Core is enrolled once; VPN and Files work without another owner-password flow.
- An unauthorized Android app cannot bind/use the broker or obtain arbitrary
  destination streams, signing operations, or management credentials.
- Closing/reopening Core UI does not terminate a transfer; broker process death
  produces recoverable client state rather than silent success.
- Core private transport and VPN full transport coexist without replacing each
  other's server peer, key, address, or exit selection.
- VPN disconnect leaves private services usable. Parent-device revocation
  invalidates all child connections and grants.
- On Android, Files transfers while another provider's VPN is active; cover
  provider denial, screen-off/background, network changes, and locked-down modes.
- Send streams files larger than the chosen memory budget, validates integrity,
  handles rejection/interruption, and leaves no persistent core payload.
- Sync correctly handles two-way updates, conflicts, deletions, offline peers,
  selected storage permissions, and absence of unintended public fallback.
- Drive works when the sending laptop is offline, and a real backup can restore
  both service metadata and files on a replacement node.
- Old enrolled clients, the existing Home exit, IPv6 protection in Internet VPN
  mode, and the Windows privileged-helper checks retain their supported behavior.

Run focused Flutter/package, native, and Go checks for each slice, then the
required platform/integration checks at its exit gate. Do not run unchanged
heavy network suites repeatedly without a relevant change or unresolved issue.
No code tests are required merely to add this planning document.

## 11. Existing-user migration and installation behavior

1. Keep Core's existing Android ID and compatible signer. Verify Windows and
   Linux secure-storage namespaces before changing executable/product metadata;
   retaining a preference key name alone may not preserve vault access.
2. Preserve easyprivacy.revamp.core, the core fingerprint, device enrollment
   identity, and node-side enrolled records. Do not migrate enrollment secrets
   into VPN or Files.
3. Offer an explicit two-app migration from the legacy combined app. Preserve
   exit choice and notification preferences through an authenticated handoff.
   Prefer a new VPN-owned traffic key and purpose-specific reprovisioning over
   exporting Core's private vault. Delete obsolete traffic state only after a
   successful cutover with a documented rollback path.
4. Coordinate stopping the legacy system tunnel and transferring its controls
   before removing its Android service declarations or Windows tray ownership.
   Do not leave a user with an active tunnel and no local disconnect control.
5. Keep the combined MVP usable during structural extraction. Temporary legacy
   VPN components in Core are a migration measure, not the final ownership.
6. Make Core-missing, Core-not-enrolled, incompatible-version, service-missing,
   grant-denied, and node-offline states actionable in capability apps.
7. Uninstalling a capability app does not delete its server data. Revoke/expire
   its grant and stop its jobs independently. Forget/revoke Core provides a
   separate coordinated action with explicit effects on installed capabilities.
8. Back up and version node/network state before migrating peer records. Keep
   existing installed interfaces, CLI compatibility, and service-node identity
   until replacement behavior is verified.

## 12. Implementation sequence and completion gates

| Slice | Work | Completion gate |
| --- | --- | --- |
| 0. Plan | This document and the file/ownership inventory. | Agreed direction is recorded; implementation choices are distinguishable from proven behavior. |
| 1. Transport and IPC prototype | Minimal Core-owned embedded engine, one authorized companion client, streaming/receiver path, and external-VPN compatibility probe. | Android-to-Windows stream works without a second system VPN; memory, lifecycle, native ABI, and private-name resolution constraints are recorded. Select the runtime hosting approach from evidence. |
| 2. Workspace extraction | Move current app to apps/core/, extract public models/UI, add workspace/build scaffolding, retain combined MVP behavior temporarily. | Existing supported app builds, pairing tests, and affected smoke checks pass with existing identities and dependency versions. No feature app imports another app's lib/. |
| 3. Independent network membership | Add versioned overlay profiles, purpose-specific peers, helper/API compatibility, grants, and revocation cascade. | Private-services and internet-exit records coexist under one parent device; legacy clients/Home continue to work; purpose-specific disconnect and parent revoke are proven. |
| 4. Core runtime and SDK | Integrate the proven transport into Core-owned lifecycle hosts; implement broker API, authorization, events, and SDK adapters. | Core UI can close while an authorized client uses its connection; callers cannot obtain enrollment material; failures and version mismatches are handled. |
| 5. VPN application split | Move full-tunnel controller/native services/tray and finish user migration, packaging, and documentation. | Existing Android/Windows VPS/Home VPN behavior works from VPN; no second enrollment; service access survives Internet VPN disconnect. |
| 6. Files Send | Create Files, implement paired-device Send through the broker, recipient storage/permissions, progress/cancel/recovery. | A real phone/laptop transfer passes integrity and interruption tests with no persistent core file copy. |
| 7. Files Sync | Select/prove the engine adapter and storage model, configure peers/private paths, expose folder policy and conflicts. | Two-device synchronization, offline recovery, deletion/conflicts, storage permissions, and private-only transport pass. |
| 8. Files Drive | Select/prove the storage backend, service recipe, provisioning, client API, and node backup/restore. | A fresh chosen node can be configured from Core and used from Files; client-offline access and tested restore work. |
| 9. Release and migration | Complete supported platform artifacts, per-app notices, version matrix, upgrade/rollback instructions, and real-device checks. | Every advertised app/platform/mode combination is verified; legacy transition is complete without lost enrollment or data. |

Keep slices reviewable and avoid combining source relocation, dependency
upgrades, server-state migration, and new file features into one change.
The first production deliverable is Core + VPN with the shared connection
foundation; Files modes follow as individually completed capabilities.

## 13. Decisions to resolve through implementation evidence

- Native engine ABI and Core background hosting on Android, Windows, and Linux.
- Exact service-only network setup command and v2 API/profile schemas.
- Core socket routing when EasyPrivacy's own full VPN is enabled.
- Publisher signing/rotation and desktop-local application trust.
- Direct-transfer engine, Syncthing integration/storage strategy, and Drive
  backend, including actual private-transport compatibility.
- Minimum supported platform versions, large-transfer limits, and measured
  battery/background behavior.
- How much independent download/removal is worthwhile inside Files. Start with
  three installable apps and optional backend workloads; hiding a Files mode
  must not be presented as uninstalling its executable code.

These choices do not block the organizational plan. Each has an explicit
prototype or release gate before the dependent capability is declared complete.
