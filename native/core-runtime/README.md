# Core userspace transport

This module hosts a private IPv4 WireGuard/netstack without an OS TUN interface
or default-route changes. Core launches cmd/core-runtime as its private child;
only Core receives its control pipe. Capability apps receive authorized byte
streams through easyprivacy_core_sdk.

The process accepts its separately provisioned traffic key, private address,
canonical RFC1918 prefix and resolved core UDP endpoint over stdin. Subsequent
bounded JSON requests issue service tickets, manage the Files receiver or revoke
a capability. Payload bytes travel through certificate-pinned local TLS 1.3,
then WireGuard. There is no direct-network fallback. EOF closes listeners,
pending tickets, accepted/outbound streams and WireGuard.

Run go test -race ./... and go vet ./.... Tests create real userspace peers,
transfer multi-megabyte payloads with SHA-256 checks, verify full-duplex receipts,
reject public destinations/replayed tickets and verify revocation/shutdown.

From the repository root, bash tool/build-core-runtime.sh builds Android ARM64,
Windows x64 and Linux x64 helpers and stages licenses. Other targets can be
specified individually; Android pairing artifacts are built separately.
The ARM64 Android PIE executable is packaged in the APK's extracted native
library directory. No executable is downloaded into writable app data.

The production Core broker and SDK are connected to this runtime. Physical
Android startup, manual reconnect, short backgrounding, Wi-Fi/mobile handovers
and coexistence with EasyPrivacy VPN and Proton VPN passed functional checks.
Extended recovery and additional VPN settings/providers remain validation
gates. Files Send/Sync/Drive engines are
not implemented by this module. See protocols/broker/v1 and protocols/core/v2.

Android platform references: [packaged executable requirement](https://developer.android.com/about/versions/10/behavior-changes-10#execute-permission)
and [connected-device foreground services](https://developer.android.com/develop/background-work/services/fgs/service-types#connected-device).
