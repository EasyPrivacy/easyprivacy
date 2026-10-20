# EasyPrivacy V1.0.0: Ubuntu core and service node

Target: Ubuntu **24.04 LTS**, including the owner's reported **24.04.4 LTS**.
Separate `amd64` (x86-64) and `arm64` packages are built. This is the core
management connection, integrated VPS VPN exit and outbound home service node.
V1.0.0 designates the first MVP, accepted by the owner on October 18, 2026.
Existing installations can upgrade without repeating setup or enrollment; see
the source repository's `docs/releases/1.0.0.md` for release and upgrade details.

## Home VM service node

Install the same node package on the home VM, then run
`sudo easyprivacy-node service-setup`. It verifies the VPS using a pairing code,
then verifies your account password and saves an independent device identity.
The VM connects outbound to the VPS's existing VPN port and can offer a Home
Internet exit and home LAN access without a public IP or port forwarding.

The VPS is trusted: it decrypts the device leg and encrypts the home leg. Both
Internet links use WireGuard; HTTPS and SSH remain independently encrypted.
Home-selected traffic cannot silently fall back to the VPS exit during an outage.
One home service node is supported in this MVP.

Enter optional management destination IPv4 addresses without ports. Explicit
host routes make these addresses usable even when the remote device's local LAN
uses the same range as the home LAN. SSH to the VM's private uplink address is
included automatically. These routes are preferences, not an access-control list.

`easyprivacy-node service-status` reports status without secrets. Use
`sudo easyprivacy-node service-stop` or `service-start` to control the service.
It starts automatically after reboot. To replace its identity, use
`sudo easyprivacy-node service-forget` and re-enroll. Package removal preserves
keys and settings. An optional `easyprivacy-desktop` package provides GUI pairing,
setup and control of the same service; ordinary Linux client VPN routing remains
future work. See `docs/home-service-node.md` in the source repository for the
deployment walkthrough and tests.

## Enable the VPS Internet exit

After core setup, run `sudo easyprivacy-node vpn-setup`. The wizard asks for the
VPS's public hostname/IP, UDP port (default **51821**), private tunnel network
(default `10.87.0.0/24`), detected Internet uplink and DNS servers. It creates a
separate `epwg0` interface, enables IPv4 forwarding and starts the restricted
`easyprivacy-vpn.service` network helper. Existing `wg0` is independent. Overlapping
server routes and an occupied UDP port are rejected.

The public address prompt suggests an IPv4 address when exactly one ordinary
public IPv4 is assigned to the detected Internet interface. Press Enter to accept
it, or enter a DNS name instead. Detection reads local interfaces and makes no
requests to external IP lookup services. NAT, multiple public addresses or an
IPv6-only interface require an explicit address; the wizard explains that case.
Use only a hostname or IP, without a port or `https://`.

Allow the selected **UDP port** in the provider firewall. Active UFW receives the
matching inbound UDP rule. The helper scopes its forwarding and NAT rules to
its interface, subnet and uplink; stopping it removes those runtime rules.
Traffic between VPN devices is blocked. Client IPv4 traffic and DNS use the exit;
client IPv6 is routed into the tunnel and blocked on the server in this MVP.

In the updated Windows or Android app, connect to the core, choose the VPS
under **Internet exit**, and select **Connect VPN**. Devices generate separate
WireGuard keys locally; the core never receives their private keys. Initial
Windows setup asks once for administrator approval to install EasyPrivacy's
embedded service and driver. Android asks for the system VPN permission.
No separate WireGuard client application or manual config export is required.

Device revocation also removes its VPN peer. The helper independently checks
the authoritative device records each second; unavailable/corrupt authorization
causes it to stop and remove its interface. The public management service
retains its unprivileged identity and has no network-administration capability.
Only the separate helper gets network administration permission, through a
protected local socket and typed, bounded peer operations.

Private VPN state is retained in `/var/lib/easyprivacy-vpn` (root-only).
`sudo easyprivacy-node vpn-status` reports helper readiness. Diagnose startup with
`sudo journalctl -u easyprivacy-vpn --since today`. Re-running `vpn-setup` preserves
the server identity/configuration and reapplies service/firewall setup. Changing
an existing exit's configuration is not yet a guided flow.

The app reports a connected VPN only after a recent WireGuard handshake; this
does not independently verify Internet/DNS access. Check browsing and the public
IP on the real VPS deployment. VPN keys survive app restarts. Closing the app
can leave an already active tunnel running; use **Disconnect VPN** or the Android
notification to stop it. Automatic VPN connection after reboot is not implemented.
The VPS and Home are available exits. The exit ID/profile API leaves room for
additional exits without coupling
the VPN identity to the account password or enrollment key.

## Install and set up

Copy the matching `.deb` to your VPS, then run:

```bash
sudo apt install ./easyprivacy-node_1.0.0_amd64.deb
sudo easyprivacy-node setup
```

Use the `arm64` filename on an ARM64 server. `dpkg --print-architecture` reports
your Ubuntu machine's package architecture. The setup wizard asks for:

1. Core name.
2. Listening TCP port (default **7444**, configurable from 1024 to 65535).
3. Username.
4. Password/passphrase of at least 15 characters, entered twice with input hidden.

The package prints the setup command rather than requesting a password inside
APT. Setup saves the core's identity and credentials, then enables and starts
`easyprivacy-node.service`. Installation alone leaves an unconfigured node
without a public listener. There is no remote signup endpoint.

Setup displays a temporary **eight-digit pairing code**. In the updated app,
enter the core address, a name for this device, and that code to verify the core.
Then enter the setup username and password to authorize the new device over a
fresh TLS connection pinned to that verified identity. Code verification alone
does not authorize a device. No public domain certificate or manually copied
fingerprint is needed. Each device creates its
own Ed25519 key pair and saves its private key using platform-protected storage.
The app saves its credential only after both steps succeed; the account password
is never saved. Routine reconnects use the enrolled device key.

To generate another code in the trusted VPS terminal:

```bash
sudo easyprivacy-node pair
```

Codes expire after five minutes and authorize one device, with five exchange
starts maximum. Creating a replacement invalidates the previous code and its
pending exchanges. The core enforces a ten-second interval between code creations.
Codes are kept in memory; restarting invalidates them, while paired devices persist.
Core verification expires with the code and allows at most five account-password
attempts. Replacement, expiry or revocation of the code's creator invalidates
pending account enrollment too. A successful account enrollment consumes the code.

An authorized paired app can use **Add device** to display a new code without
an extra password or PIN. A future optional short PIN is outside this MVP.
Paired apps reconnect using their own private keys and can list/revoke devices.
Revocation immediately invalidates the selected device's sessions and any code
it created. Terminal recovery remains available:

```bash
sudo easyprivacy-node devices
sudo easyprivacy-node revoke DEVICE_ID
```

Existing installations: install the new package, run `sudo easyprivacy-node pair`,
and choose **Use a pairing code** in the app if a legacy login profile is loaded.
The existing core identity, username and password are preserved. Legacy pinned
password login remains compatible, but its sessions cannot create pairing codes.

After the service passes its local TLS check, installed setup detects Ubuntu's
UFW firewall. When UFW is active, setup automatically adds an inbound allow rule
for **only the selected TCP port** (equivalent to `sudo ufw allow 7444/tcp` for
the default). Existing matching rules are handled by UFW without duplicates.
UFW's IPv6 configuration determines whether it also adds an IPv6 rule. Setup
never enables, disables or resets UFW, changes SSH rules, or installs UFW on a
machine that does not use it. Other host firewalls require manual configuration.
Use `sudo easyprivacy-node setup --skip-firewall` to manage all rules yourself.
Development setup with a custom `--state-dir` never changes host firewall rules.

Allow the selected TCP port in your **VPS provider's firewall** too; a local
package cannot configure that external firewall without provider access.
Setup checks whether the selected port is available; choose another port if an
earlier iteration or another service is already using it.

For an existing installation, upgrade the package and apply the saved port's
UFW rule without repeating setup or changing your login/fingerprint:

```bash
sudo apt install ./easyprivacy-node_1.0.0_amd64.deb
sudo easyprivacy-node firewall
```

The `firewall` command can also be rerun after enabling UFW later. A failed UFW
check or rule update reports the error and a recovery command; the saved core
identity and running service remain available. Package installation and upgrades
do not change firewall rules themselves; fresh installed setup does.

For legacy apps, copy the displayed **Core fingerprint** along with your
VPS address (for example `203.0.113.8:7444`), username and password. Obtain the
fingerprint from your trusted VPS terminal, not from an unverified network
connection. Display it again with:

```bash
sudo easyprivacy-node identity
systemctl status easyprivacy-node
sudo journalctl -u easyprivacy-node --since today
```

If setup saved your configuration but the service could not start, fix the
reported cause and run `sudo systemctl enable --now easyprivacy-node`. Use the
identity command above to retrieve the fingerprint; setup preserves the existing
identity rather than overwriting it.

## Installed behavior and data

- `/usr/bin/easyprivacy-node`: compiled executable; no Go toolchain is needed on the VPS.
- `/usr/lib/systemd/system/easyprivacy-node.service`: hardened service running
  as the non-login `easyprivacy-node` account.
- `/var/lib/easyprivacy-node/core.json`: core settings, salted password
  verifier and private server identity; root-owned, mode 0640, readable by the
  dedicated service group, inside a 0750 directory.
- The service has no network-administration capabilities in this milestone.
- Existing iteration-one/two state under `/var/lib/easyprivacy` is separate.
- `/var/lib/easyprivacy-node/runtime/devices.json`: private, durable device
  authorization records; only public device keys are stored on the core. The
  service owns its 0700 runtime subdirectory and writes records atomically.
- `/run/easyprivacy-node/admin.sock`: mode-0600 local administration socket
  inside a 0700 service directory, accessible to root and the service identity.

The server requires TLS 1.3. The desktop checks the exact certificate fingerprint
before sending credentials. Credentials use PBKDF2-HMAC-SHA256 with a random
16-byte salt and 600,000 iterations, following the previous prototype's password
verifier approach. Login work, request sizes, login attempts and active sessions
are bounded. Errors do not distinguish an unknown username from a wrong password.

Sessions expire after one hour and are invalidated when the server restarts.
Disconnect revokes the current session when the server is reachable; if it is
unreachable, the desktop discards local access and the server session expires
normally. The app saves the core address, verified fingerprint and device private
key in platform-protected storage. Legacy profiles also retain the username.
Passwords, pairing codes and session tokens are not saved to disk. Disconnect
retains device pairing; **Forget this core** removes the local pairing. Use
device revocation to remove server authorization as well.

The self-signed core certificate lasts two years. Automatic certificate renewal,
password changes and recovery are not implemented in this first milestone.
Setup refuses to overwrite an existing identity. Back up the private state file
securely before changes. `apt remove` and `apt purge` preserve the core's state
and service account; deletion of private owner data is a separate admin action.
Removal also preserves UFW allow rules, which may be shared with an administrator's
existing configuration. Remove an unused rule explicitly with
`sudo ufw delete allow 7444/tcp`, substituting the configured port.

## If the app cannot reach the core

On the VPS, check the service, listener and local TLS response:

```bash
sudo systemctl status easyprivacy-node --no-pager
sudo ss -ltnp 'sport = :7444'
curl --insecure --silent --show-error https://127.0.0.1:7444/healthz
sudo ufw status verbose
sudo easyprivacy-node firewall
```

Substitute your selected port. The local health request sends no credentials;
`--insecure` is only for this loopback diagnostic, not app authentication.
If the local service responds but the app cannot reach it, confirm that DNS
points to the VPS public IP and the provider firewall also allows that TCP port.
An applied UFW rule and a successful local health check do not prove public
reachability; another firewall rule or network policy can still block access.

## Upgrade / remove

```bash
sudo apt install ./easyprivacy-node_VERSION_amd64.deb
sudo apt remove easyprivacy-node
```

Upgrades preserve the complete core state and try to restart an already running
service. Removal stops the service and removes package-managed files. No cloud
account or external EasyPrivacy service is required.

## Build and check

Pairing uses the shared RustCrypto `spake2` 0.4.0 implementation, not a handwritten
Dart PAKE port. It authenticates the core fingerprint and new device key with
mutual confirmation, then uses pinned TLS and fresh signed challenges for login.
The upstream library and our integration have not received an independent security
audit. Tests and interoperability checks are not a substitute for such an audit.
Dependency notices are included in the package and app.

Development needs Go 1.27+, Rust (tested with 1.99.1), a C linker, Python 3, and
Ubuntu's `dpkg-deb`. ARM64 builds additionally need the Rust
`aarch64-unknown-linux-gnu` target and `gcc-aarch64-linux-gnu`. Build on Linux:

```bash
cd core
bash scripts/build-pairing.sh amd64
go test -race ./...
go vet ./...
bash scripts/package.sh amd64
bash scripts/package.sh arm64
```

`EASYPRIVACY_GO` may name an absolute Go executable. Packages and SHA-256
checksums are written under `core/dist/`. Checksums detect changed bytes; obtain
both the package and checksum through a trusted channel. The V1.0.0 packages
are manual downloads rather than a signed APT repository.

For isolated development only, `setup`, `serve`, and `identity` accept
`--state-dir /absolute/private/directory`. This bypasses installed service
management and supports testing without changing a machine's installed node.
For a development core, the `pair`, `devices` and `revoke` commands use the same
`--state-dir` to reach its private local administration socket. Linux packages
include the compiled native code and declare their Ubuntu libc dependencies;
end users need no Go, Rust or compiler installation.
