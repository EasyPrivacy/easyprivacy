package main

import (
	"net/netip"
	"testing"
)

func TestVPNPublicIPv4Default(t *testing.T) {
	for _, test := range []struct {
		name      string
		addresses []string
		want      string
	}{
		{"direct VPS", []string{"74.208.64.175"}, "74.208.64.175"},
		{"private plus public", []string{"10.1.2.3", "74.208.64.175"}, "74.208.64.175"},
		{"duplicate public", []string{"74.208.64.175", "74.208.64.175"}, "74.208.64.175"},
		{"NAT requires input", []string{"10.1.2.3", "192.168.1.5"}, ""},
		{"ambiguous public addresses", []string{"74.208.64.175", "8.8.8.8"}, ""},
		{"IPv6 only requires input", []string{"2606:4700:4700::1111"}, ""},
		{"no addresses", nil, ""},
	} {
		t.Run(test.name, func(t *testing.T) {
			var addresses []netip.Addr
			for _, address := range test.addresses {
				addresses = append(addresses, netip.MustParseAddr(address))
			}
			if got := vpnPublicIPv4Default(addresses); got != test.want {
				t.Fatalf("got %q, want %q", got, test.want)
			}
		})
	}
}

func TestVPNPublicIPv4DefaultSkipsSpecialAddresses(t *testing.T) {
	for _, value := range []string{
		"0.0.0.0", "0.1.2.3", "10.0.0.1", "100.64.0.1", "100.127.255.254",
		"127.0.0.1", "169.254.1.2", "172.16.1.2", "172.31.255.254",
		"192.0.0.9", "192.0.2.1", "192.31.196.1", "192.52.193.1",
		"192.88.99.2", "192.168.0.1", "192.175.48.1", "198.18.0.1",
		"198.19.255.254", "198.51.100.1", "203.0.113.1", "224.0.0.1",
		"240.0.0.1", "255.255.255.255", "::1", "::ffff:10.0.0.1",
	} {
		t.Run(value, func(t *testing.T) {
			if got := vpnPublicIPv4Default([]netip.Addr{netip.MustParseAddr(value)}); got != "" {
				t.Fatalf("suggested special-purpose address %q", got)
			}
		})
	}
	if got := vpnPublicIPv4Default([]netip.Addr{{}}); got != "" {
		t.Fatalf("suggested invalid address %q", got)
	}
}
