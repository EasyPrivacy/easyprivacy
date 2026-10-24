# Private-network development update

Candidate: **1.0.1~reorg1**, built from codex/reorg-app. This is a development
node update for the separate Core/VPN apps, not a completed Files release.

The node adds private peers, a connection diagnostic, discovery and leased
Files receivers alongside the existing Internet/Home VPN. Existing enrollment,
certificate, traffic keys, addresses and Internet-exit settings are retained.
The Core app now owns the userspace private connection; the VPN app remains the
optional full-device tunnel. The later Core 1.0.0+10 and Files 1.0.0+2 apps add
the first Send implementation using these same node APIs. Sync and Drive follow.

## Choose and copy the package

On the node:

~~~bash
dpkg --print-architecture
dpkg-query -W -f='${Version}\n' easyprivacy-node
sudo easyprivacy-node identity
~~~

Record the current fingerprint and retain the installer for that existing
version for rollback. Use the package matching the node's architecture:

- [amd64 package](../core/dist/easyprivacy-node_1.0.1~reorg1_amd64.deb) and
  [checksum](../core/dist/easyprivacy-node_1.0.1~reorg1_amd64.deb.sha256).
- [arm64 package](../core/dist/easyprivacy-node_1.0.1~reorg1_arm64.deb) and
  [checksum](../core/dist/easyprivacy-node_1.0.1~reorg1_arm64.deb.sha256).

Copy the chosen .deb and its .deb.sha256 file to the same directory on the node.
The checksums should come from the same trusted local build. For example, for
an amd64 node:

~~~bash
sha256sum --check easyprivacy-node_1.0.1~reorg1_amd64.deb.sha256
~~~

Expect brief VPN interruptions while backing up and restarting the helper.
Use a VPS console or an SSH path that remains available when this VPN stops.

## Back up existing state

Run this on the node. It briefly stops whichever EasyPrivacy services are active,
copies their private state without printing it, then restores their running
state even if the backup fails. Keep the printed backup directory private.

~~~bash
sudo bash -eu <<'SH'
umask 077
backup="/root/easyprivacy-before-reorg-$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 0700 "$backup"
touch "$backup/active-units.txt"
restart_units() {
    for unit in easyprivacy-node.service easyprivacy-vpn.service easyprivacy-service.service; do
        if grep -Fxq "$unit" "$backup/active-units.txt"; then systemctl start "$unit"; fi
    done
}
trap restart_units EXIT
dpkg-query -W -f='${Version}\n' easyprivacy-node > "$backup/package-version.txt"
for unit in easyprivacy-vpn.service easyprivacy-service.service easyprivacy-node.service; do
    if systemctl is-active --quiet "$unit"; then
        printf '%s\n' "$unit" >> "$backup/active-units.txt"
        systemctl stop "$unit"
    fi
done
for dir in /var/lib/easyprivacy-node /var/lib/easyprivacy-vpn /var/lib/easyprivacy-service; do
    if [ -d "$dir" ]; then cp -a -- "$dir" "$backup/"; fi
done
printf 'Backup directory: %s\n' "$backup"
SH
~~~

## Install and verify

For amd64 (substitute arm64 in both filenames for an arm64 node):

~~~bash
sudo apt install ./easyprivacy-node_1.0.1~reorg1_amd64.deb
dpkg-query -W -f='${Version}\n' easyprivacy-node
sudo easyprivacy-node identity
sudo systemctl status easyprivacy-node easyprivacy-vpn --no-pager
sudo easyprivacy-node network-status
~~~

The fingerprint must match the recorded fingerprint. Existing VPN installations
keep their exit enabled and reuse the current UDP endpoint; no new public ports
are needed. The private probe and receiver TCP ports stay inside WireGuard.
An inactive helper is expected if networking has never been set up.

For a **new private-only installation**, after completing the usual core setup:

~~~bash
sudo easyprivacy-node network-setup
~~~

That command asks for the public UDP endpoint and private subnet and enables
private services without Internet NAT or an Internet exit. Allow its selected
UDP port in the provider firewall. Existing Internet-enabled installations
retain their configuration if this command is run; it does not disable the VPN.

To enable an Internet exit later, run sudo easyprivacy-node vpn-setup.
It preserves the private-network key, endpoint and subnet and saves the prior
configuration as vpn.pre-internet.json.

## Test the updated apps

Install Core 1.0.0+9 and VPN 1.0.0+2 from this branch, preserving app data.
Use the existing pairing; an upgrade should not require enrollment again.

ARM64 test APKs: [Core](../apps/core/build/easyprivacy-core-android-arm64-1.0.0-release.apk)
and [VPN](../apps/vpn/build/easyprivacy-vpn-android-arm64-1.0.0-release.apk).
Both retain the existing test publisher certificate. Other Android architectures
need their own pairing/runtime artifacts and builds.

1. In Core, open Private service connection and choose Start private connection.
   It verifies a fresh 32-byte nonce through the private WireGuard path.
2. Choose Check connection. Stop it and start it again.
3. With the private connection enabled, connect/disconnect the separate VPN app
   and repeat the private connection check. Internet and DNS should still work
   through the selected full tunnel.
4. Disconnect EasyPrivacy VPN, connect another Android VPN and repeat the
   private check. Its own network restrictions/lockdown settings may affect
   access to the node's encrypted UDP endpoint.
5. Repeat Wi-Fi/mobile switching, a short complete outage, dismissing the Core
   screen and screen lock. Check the connection after recovery.
6. Stop the private connection and confirm the Core foreground notification
   disappears; the Internet VPN remains independently controllable.

The initial Files app was a shell. The later Files 1.0.0+2 build adds native file
selection, recipient approval and encrypted Send with Core 1.0.0+10; see
[Files Send](files-send.md). Actual phone/laptop file transfers passed with 8 MiB
in each direction. This node package does not install a sync engine or Drive.
Physical Android startup, manual reconnect, short background operation and
EasyPrivacy VPN coexistence have passed a smoke test against the updated node.
Wi-Fi/mobile handovers also passed with and without Proton VPN. Extended screen
lock was deferred by the owner to personal use; longer recovery and additional
VPN settings remain future checks. See the implementation status for details.

## Rollback

Stop the new helper and node **before** installing an older package. Old helpers
cannot parse private-services peer records.

~~~bash
sudo systemctl stop easyprivacy-vpn easyprivacy-node
~~~

If /var/lib/easyprivacy-vpn/peers.pre-private.json exists, restore it to peers.json
while the helper is stopped:

~~~bash
sudo cp -a /var/lib/easyprivacy-vpn/peers.pre-private.json /var/lib/easyprivacy-vpn/peers.json
~~~

Otherwise use peers.json from the private backup above. Restore the backup's
vpn.json as well if its configuration was changed to schema 2/private-only;
the existing Internet-enabled upgrade normally leaves that file unchanged.
For a new private-only deployment, leave the older VPN helper disabled.

Install the retained previous package using sudo apt install --allow-downgrades
./PREVIOUS-PACKAGE.deb, replacing that filename with the actual old installer.
Then start the node and, if its restored Internet configuration exists, the VPN
helper. Check the recorded fingerprint and the old VPN connection.

Preserve the current core enrollment/revocation database during normal binary
rollback: restoring an older device database would undo later device revocations.
The snapshot can omit Internet peers registered after it was taken; those
clients can reconnect/provision again. Receiver leases are transient and are
not restored. The new Core private connection will require the newer node again.

## Local validation

See [implementation status](app-reorganization-progress.md) for exact checks and
remaining device gates. Builds and package tests use synthetic local state.
The owner subsequently installed the node update; the recorded phone smoke
test used that updated node.
