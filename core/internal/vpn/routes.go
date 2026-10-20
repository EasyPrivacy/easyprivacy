package vpn

import (
	"errors"
	"net/netip"
	"strings"
)

func CheckRoutes(subnet, routes string) error {
	wanted, e := netip.ParsePrefix(subnet)
	if e != nil {
		return e
	}
	for _, line := range strings.Split(routes, "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		for _, field := range fields {
			p, e := netip.ParsePrefix(field)
			if e == nil && p.Bits() != 0 && (p.Contains(wanted.Addr()) || wanted.Contains(p.Addr())) {
				return errors.New("VPN subnet overlaps an existing route; choose another private /24 network")
			}
		}
	}
	return nil
}
