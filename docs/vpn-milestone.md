# EasyPrivacy V1.0.0: VPN milestone

First MVP accepted October 18, 2026; release designation October 19, 2026.
Core/package version: `1.0.0`; app: `1.0.0+7` (Android build counter 7).

The completed MVP includes Windows and Android VPN clients, a VPS Internet exit,
and a home VM exit reached through a second encrypted leg. The home VM connects
outbound without a public IP or incoming router port forwarding. Optional Linux
GUI and headless commands control the same home service node. The VPS remains
trusted with forwarding between the encrypted legs.

The owner verified the working setup and declared the MVP complete. See the
[home service-node guide](home-service-node.md) for deployment details and
[release notes](releases/1.0.0.md) for current artifacts, upgrades and limitations.

For an existing amd64 VPS:

```bash
sudo apt install ./easyprivacy-node_1.0.0_amd64.deb
easyprivacy-node version
```

Existing identities, enrolled devices and VPN settings are preserved; repeating
setup or enrollment is unnecessary for the version update. On a new VPS, run
`sudo easyprivacy-node vpn-setup` after core setup and allow the configured UDP
port in the provider firewall. The default is 51821; active UFW is handled by the
wizard. Existing `wg0` on UDP 51820 remains separate.

## Implemented flow

1. Install or upgrade the core package. Run `sudo easyprivacy-node vpn-setup`
   when configuring the VPN for the first time; an existing configured VPN does
   not need setup again for the 1.0.0 upgrade.
2. Confirm the detected public IPv4 or enter a hostname/IP, then choose the UDP
   port (51821 by default), private IPv4 /24, Internet uplink and DNS servers.
   Allow the UDP port in the provider firewall.
3. Connect the enrolled app, select the VPS exit and choose **Connect VPN**.
4. Windows asks once to install EasyPrivacy's protected native service. Android
   asks for the operating system's VPN consent. No separate WireGuard app or
   manual configuration export is required.
5. The device keeps a separate X25519 traffic key locally and sends only its
   public key over the existing authenticated core connection.
6. The core allocates a stable tunnel address and provisions the authorized peer.
   Full IPv4 traffic and DNS traverse the VPN; IPv6 enters the tunnel and is
   blocked on this first exit.
7. The app distinguishes core reachability, tunnel startup and a recent
   WireGuard handshake. Transfer counters come from the actual native engine.
8. **Disconnect VPN** restores normal networking and requests peer removal.
   Active native tunnels remain disconnectable even before core login.

A recent handshake confirms the encrypted peer connection. It does not by itself
prove working DNS or Internet access; browsing and the public exit IP must be
checked against the owner's actual VPS.

## Privilege and state boundaries

The management service remains unprivileged. A separate Linux helper owns
`epwg0`, forwarding/NAT and root-only state under `/var/lib/easyprivacy-vpn`.
Its local socket is accessible only to root and the core's service group; the
protocol permits bounded typed peer operations rather than arbitrary commands.
The helper independently checks device authorizations each second and stops its
interface if the authoritative records cannot be read. Revocation requests also
remove the peer synchronously; a failure is reported as a warning after the
management authorization has been revoked.

Its restricted capabilities include read-only traversal of the core's private
authorization directory. The filesystem sandbox keeps that directory read-only
to the helper. A package regression check verifies access under the declared
capabilities and verifies denial without the required read capability.

Existing `wg0` and UDP 51820 are separate. Setup detects the selected UDP port
and overlapping routes. Scoped, tagged forwarding and NAT rules are removed
when the helper stops. The global IPv4-forwarding sysctl and UFW UDP allow rule
remain after package removal because they may be shared with other services.
The helper uses the shared xtables lock inside its filesystem sandbox.

The Windows helper embeds the official WireGuard Windows service package and
signed WireGuardNT driver DLL. Installation puts the executable, DLL and private
configuration in protected Program Files / ProgramData directories. Local control
is limited to the installing Windows account and Local System. Before sending
VPN keys, the app's native bridge checks that the pipe's server PID matches the
installed service reported by Windows Service Control Manager.

Android embeds the official `com.wireguard.android:tunnel` library and uses
Android's VPN consent and foreground service lifecycle. Its VPN is not registered
as always-on: automatic boot connection/reconnection policy is future work.
Already established tunnels may continue when the app UI closes. Stopping them
is available in the app and in Android's VPN/notification controls.

The VPS exit has its own identifier and profile. Client traffic keys are scoped
to the enrolled identity, trusted core and exit, independently of passwords and
enrollment signing keys. Home service registration, source-based routing and
management host routes are implemented; selected Home traffic fails closed if
its path disappears. One home service node is supported in V1.0.0.

## Validation

- Go unit/race tests and vet: passed, including authorization, peer allocation,
  key rotation rollback, persistence, revocation and corrupt-state behavior.
- Real Linux kernel WireGuard test in private mount/network namespaces: passed
  handshake, NAT, DNS, IPv6 blocking, revocation, normal-route restoration and
  firewall cleanup. Host routing and firewall were not changed by these tests.
- Public address suggestion tests cover direct VPS addresses, NAT, shared address
  space, special-purpose ranges, duplicate addresses and ambiguous public IPs.
  The wizard queries local interfaces only; it keeps a manual override and does
  not contact external IP lookup services. Existing configured endpoints are kept.
  The actual terminal wizard was exercised in private mount/network namespaces:
  a simulated public interface populated the default and accepted a DNS override;
  a private-only interface displayed the fallback explanation.
- Flutter analysis: passed. App tests: 32 passed for the accepted MVP, including key separation,
  cancellation, denied installation, storage failure, handshake status, recovery
  before core login, and phone/desktop layouts.
- Windows helper: compiled; one-time installation and status RPC passed on this
  computer. Native Windows tests passed, including rejection of a fake pipe.
- Windows and Android prerelease builds compiled successfully during MVP development.
  Bundled helper versions, APK signature, ZIP alignment and ARM64 ELF alignment
  were checked; all ARM64 native libraries support 16 KB pages. The APK uses the
  existing development signing key for local MVP testing.
- Ubuntu 24.04.4 fresh installation and upgrade/remove/reinstall/purge checks
  passed in disposable roots with private, read-only kernel filesystem mounts.
  Core identity, account credentials and device records survived the lifecycle.
  The final upgrade also passed the restricted helper capability regression check.
  Prerelease-to-prerelease upgrades passed the same package lifecycle checks.
- SHA-256 sidecars accompany both Ubuntu packages, the Windows ZIP and Android APK.
- ARM64 package is cross-compiled; actual ARM64 Ubuntu hardware remains untested.
- The owner verified the working setup and accepted the first MVP on the actual
  deployment. The agent did not log into or administratively modify the remote
  servers. The Pixel's saved enrollment reconnected after its previous update.
  A legacy core's plain-text VPN-route 404 displays upgrade/setup guidance rather
  than a JSON parsing error; this was verified on Pixel 10.

WireGuard engine versions: Windows module `v1.1.1`, WireGuardNT SDK `1.1`, Android
library `1.0.20260102`. Dependency notices are bundled in the app's Licenses view.
The signed driver DLL was verified before embedding and its hash is pinned in
the build helper. This application integration has not had an independent audit.

## Owner acceptance

The owner accepted the first MVP on October 18, 2026 after verifying the working
setup. The V1.0.0 designation records that milestone. Release upgrades preserve
the accepted behavior and existing configuration.

Useful ongoing checks are browsing/DNS and exit IP, return to normal networking
after disconnect, device revocation, reconnect after core/home outages, and
server restart. These remain practical regression checks for later features.

## References

- [WireGuard embedding](https://www.wireguard.com/embedding/)
- [Windows service integration](https://git.zx2c4.com/wireguard-windows/about/embeddable-dll-service/README.md)
- [WireGuardNT SDK](https://download.wireguard.com/wireguard-nt/)
- [Android VPN lifecycle](https://developer.android.com/develop/connectivity/vpn)
- [Windows service security](https://learn.microsoft.com/en-us/windows/win32/services/service-security-and-access-rights)
