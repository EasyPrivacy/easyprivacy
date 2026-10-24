#!/usr/bin/env bash
set -euo pipefail
[[ $(id -u) == 0 ]] || { printf 'Run as root in the local Linux test environment.\n' >&2; exit 1; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
temp=$(mktemp -d /tmp/easyprivacy-vpn-nettest.XXXXXXXX)
cleanup() { case "$temp" in /tmp/easyprivacy-vpn-nettest.*) rm -rf -- "$temp" ;; esac; }
trap cleanup EXIT
cd "$root"
"${EASYPRIVACY_GO:-go}" test -c -o "$temp/vpn.test" ./internal/vpn
# /run is replaced only inside a private mount namespace: named network
# namespaces, forwarding, routes and firewall rules never touch the host.
for test in TestLinuxWireGuardInternetDNSIPv6AndRevocation TestLinuxRoutedHomeExit TestLinuxPrivateReceiverIsolation; do
unshare --mount --net --propagation private bash -c '
  mount -t tmpfs tmpfs /run
  mkdir /run/netns
  exec env EPVPN_NETWORK_TEST=1 "$1" -test.run "^$2$" -test.v
' _ "$temp/vpn.test" "$test"
done
