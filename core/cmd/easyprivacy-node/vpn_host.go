package main

import (
	"net"
	"net/netip"
	"strings"

	"github.com/easyprivacy/easyprivacy/core/internal/vpn"
)

// Conservatively skip IANA special-purpose IPv4 blocks, including globally
// reachable protocol anycasts that are not ordinary VPS endpoint addresses.
// https://www.iana.org/assignments/iana-ipv4-special-registry/
var vpnSpecialIPv4 = []netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/8"),
	netip.MustParsePrefix("10.0.0.0/8"),
	netip.MustParsePrefix("100.64.0.0/10"),
	netip.MustParsePrefix("127.0.0.0/8"),
	netip.MustParsePrefix("169.254.0.0/16"),
	netip.MustParsePrefix("172.16.0.0/12"),
	netip.MustParsePrefix("192.0.0.0/24"),
	netip.MustParsePrefix("192.0.2.0/24"),
	netip.MustParsePrefix("192.31.196.0/24"),
	netip.MustParsePrefix("192.52.193.0/24"),
	netip.MustParsePrefix("192.88.99.0/24"),
	netip.MustParsePrefix("192.168.0.0/16"),
	netip.MustParsePrefix("192.175.48.0/24"),
	netip.MustParsePrefix("198.18.0.0/15"),
	netip.MustParsePrefix("198.51.100.0/24"),
	netip.MustParsePrefix("203.0.113.0/24"),
	netip.MustParsePrefix("224.0.0.0/4"),
	netip.MustParsePrefix("240.0.0.0/4"),
}

func vpnPublicIPv4Default(addresses []netip.Addr) string {
	candidates := make(map[netip.Addr]bool)
	for _, address := range addresses {
		if !address.Is4() || !address.IsGlobalUnicast() {
			continue
		}
		special := false
		for _, block := range vpnSpecialIPv4 {
			if block.Contains(address) {
				special = true
				break
			}
		}
		if !special {
			candidates[address] = true
		}
	}
	// Multiple public addresses need an explicit choice; do not pick arbitrarily.
	if len(candidates) == 1 {
		for address := range candidates {
			return address.String()
		}
	}
	return ""
}

func detectVPNHost(uplink string) string {
	if uplink == "" || uplink == vpn.Interface || strings.HasPrefix(uplink, "wg") {
		return ""
	}
	iface, err := net.InterfaceByName(uplink)
	if err != nil || iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
		return ""
	}
	addresses, err := iface.Addrs()
	if err != nil {
		return ""
	}
	var candidates []netip.Addr
	for _, address := range addresses {
		if prefix, err := netip.ParsePrefix(address.String()); err == nil {
			candidates = append(candidates, prefix.Addr())
		}
	}
	return vpnPublicIPv4Default(candidates)
}
