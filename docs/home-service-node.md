# EasyPrivacy V1.0.0: home service node

Decision: use separate encrypted WireGuard legs, with the VPS trusted to decrypt
and forward traffic between them. The owner selected this simpler implementation
instead of a nested VPN. Both Internet links are encrypted; HTTPS and SSH retain
their own end-to-end protection. Plain HTTP remains plaintext after the home exit.

```text
Windows / Android -- encrypted --> VPS -- encrypted --> Home VM
                                                     |-- Home Internet exit
                                                     `-- Home LAN management
```

The home VM initiates the connection to the VPS's existing WireGuard endpoint.
Persistent keepalives maintain its NAT mapping. No public home IP, incoming home
port forwarding, second VPN app, or additional VPS UDP port is needed.

First MVP accepted by the owner on October 18, 2026; release designated 1.0.0
on October 19, 2026. See [release notes](releases/1.0.0.md) for upgrading an existing
installation without repeating setup or enrollment.

## Owner's deployment

- VPS: Ubuntu 24.04.4 LTS, existing management port TCP 7444 and VPN UDP 51821.
- Existing VPS tunnel network: `10.10.10.0/24`; preserve it during upgrades.
- Home VM: Ubuntu 24.04.3 LTS, `ens18`, `192.168.50.247/24`.
- Home gateway: `192.168.50.1`; LAN: `192.168.50.0/24`.
- Server management: `192.168.50.137` and `192.168.50.136:8006`.
- Development Windows Wi-Fi is also in `192.168.50.0/24`. Specific management
  host routes ensure these addresses traverse Home despite that overlap.

## Install and connect

Disconnect the app's VPN before upgrading the core; its network helper restarts.
On the VPS, upgrade the existing package, retaining its identity and configuration:

```bash
sudo apt install ./easyprivacy-node_1.0.0_amd64.deb
sudo easyprivacy-node pair
```

The second command displays a fresh pairing code. An already paired app can also
create that code using Add device, without re-entering the account password.

Copy the node package to the home VM, then run:

```bash
sudo apt install ./easyprivacy-node_1.0.0_amd64.deb
sudo easyprivacy-node service-setup
```

Do not run the VPS's `setup` or `vpn-setup` commands on the home VM. The home
wizard asks for the core address (`kasonsummers.com:7444`), home exit name, pairing
code, account username and hidden password. Code verification authenticates the
core before the password is sent. It detects `ens18` as the uplink. At the
management-address prompt, enter:

```text
192.168.50.137,192.168.50.136
```

Enter IP addresses without ports. SSH to the VM itself is included automatically
by advertising its private uplink address. The service rejects a core tunnel
network that overlaps its own LAN. It enables forwarding, scoped NAT/firewall
rules and automatic startup of `easyprivacy-service.service`.

Update the Windows/Android app, refresh VPN exits, choose Home, and connect.
Windows requests administrator approval to update its helper for management
routes when an older helper is installed. Its full-tunnel firewall remains active.
Internet traffic and DNS use the home exit; IPv6 remains captured and blocked.

For a Linux VM with a desktop, optionally install the GUI package alongside the
node package:

```bash
sudo apt install ./easyprivacy-node_1.0.0_amd64.deb ./easyprivacy-desktop_1.0.0_amd64.deb
easyprivacy-desktop
```

Pair the VM in the GUI and use Home service node to configure the exit. A local
administrator prompt authorizes service installation. If the CLI already set it
up, the GUI reads its status and can start/stop that same service without another
enrollment. Closing the GUI leaves the service running. The optional GUI has no
separate network engine. This Linux GUI milestone manages a service node; an
ordinary Linux full-tunnel client remains future work.

## Administration

```bash
easyprivacy-node service-status
sudo easyprivacy-node service-stop
sudo easyprivacy-node service-start
sudo journalctl -u easyprivacy-service --no-pager -n 40
```

`service-status` returns public JSON status without credentials or private keys.
Root-only state lives under `/var/lib/easyprivacy-service`. The Linux service
uses its own Ed25519 enrolled identity and X25519 WireGuard key. Passwords and
management tokens are not stored. Signed device login renews access automatically.

Revoking the home device at the core removes its gateway peer. Home-selected
clients remain assigned to Home and cannot silently use the VPS exit. To replace
a local service identity, first run `sudo easyprivacy-node service-forget`, then
re-enroll with a new code. This stops/disables the service and removes its local
keys. Remove its old paired-device record at the core when no longer needed.

## Routing and limitations

One home service node is supported in this MVP. Devices retain one tunnel to the
VPS. The VPS uses source policy routing for Home-selected peers, with a terminal
unreachable route and a separate firewall guard against VPS-uplink fallback.
Normal device-to-device forwarding stays blocked. The VM accepts the overlay
through its outbound link, forwards to its LAN/uplink and applies NAT, so LAN
servers do not need return routes for the overlay network.

Management addresses add private IPv4 /32 routes; they are routing preferences,
not an access-control list. All paired devices belong to the owner account and
can manage enrollment. Broader per-user permissions and additional home exits
are future work. Other home LAN addresses may need explicit management routes
when the local and home LAN ranges overlap. Selecting Home always routes through
the VPS; there is no direct-path optimization or fallback.

An up-to-date handshake describes the VPN leg. It does not prove Internet access.
Home readiness is based on its latest WireGuard handshake and can take up to
three minutes to age out after an outage. Already selected Home traffic stops
immediately when its path cannot forward and resumes when that path recovers.

## Verification

The isolated Linux network suite uses real kernel WireGuard interfaces and an
outbound home VM behind a NAT router. It checks home public egress, DNS, LAN
management, overlapping LAN host routes, outage/recovery, missing policy guards,
revocation, crash cleanup, restored Home selection and explicit VPS selection.
The existing VPS exit, IPv6 protection, key authorization and device revocation
checks remain in place. Enrollment tests exercise the Go client against the real
core's code-then-password and signed-login protocols. GUI tests verify control of
an existing headless service without reenrollment.

The owner verified the working setup and declared the first MVP complete on
October 18, 2026. The management destinations include SSH and
`https://192.168.50.136:8006`. Future updates should retain these working paths.

Release checks completed October 18, 2026: core race tests and vet; 32 Flutter
tests and clean analysis; both real-kernel network suites; Windows configuration
and named-pipe authentication tests; Ubuntu 24.04.4 upgrade/removal/reinstall
checks; Linux GUI launch/render; Android ZIP and ARM64 ELF 16 KB alignment.
The Pixel's saved pairing reconnected after its previous MVP update. The 1.0.0
app uses Android build counter 7 so it can upgrade that existing installation.
Node packages are built for amd64 and arm64; the optional GUI build is amd64.
The GUI package includes the session/keyring dependencies required for secure
enrollment storage. Headless installation does not include those desktop packages.

[WireGuard keepalive guidance](https://www.wireguard.com/quickstart/)
