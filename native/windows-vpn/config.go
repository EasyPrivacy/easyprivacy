package main

import (
	"encoding/base64"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"regexp"
	"strings"
)

type Config struct {
	PrivateKey       string   `json:"private_key"`
	PublicKey        string   `json:"public_key"`
	Endpoint         string   `json:"endpoint"`
	Address          string   `json:"address"`
	AddressV6        string   `json:"address_v6"`
	DNS              []string `json:"dns"`
	MTU              int      `json:"mtu"`
	Keepalive        int      `json:"keepalive"`
	ManagementRoutes []string `json:"management_routes,omitempty"`
}

func (c Config) Text() (string, error) {
	for _, key := range []string{c.PrivateKey, c.PublicKey} {
		b, e := base64.StdEncoding.DecodeString(key)
		if e != nil || len(b) != 32 || base64.StdEncoding.EncodeToString(b) != key {
			return "", errors.New("invalid VPN key")
		}
	}
	h, p, e := net.SplitHostPort(c.Endpoint)
	if e != nil || h == "" || len(h) > 253 || strings.ContainsAny(h, "\r\n\x00 /\\@") || !regexp.MustCompile(`^[0-9]{1,5}$`).MatchString(p) {
		return "", errors.New("invalid VPN endpoint")
	}
	_, e = net.LookupPort("udp", p)
	if e != nil {
		return "", e
	}
	if p == "0" {
		return "", errors.New("invalid VPN port")
	}
	if _, err := netip.ParseAddr(h); err != nil {
		if !regexp.MustCompile(`^[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?\.?$`).MatchString(h) || strings.Contains(h, "..") {
			return "", errors.New("invalid VPN hostname")
		}
	}
	a, e := netip.ParsePrefix(c.Address)
	if e != nil || !a.Addr().Is4() || !a.Addr().IsPrivate() || a.Bits() != 32 {
		return "", errors.New("invalid VPN address")
	}
	v6, e := netip.ParsePrefix(c.AddressV6)
	if e != nil || !v6.Addr().Is6() || !v6.Addr().IsPrivate() || v6.Bits() != 128 {
		return "", errors.New("invalid VPN IPv6 protection address")
	}
	if c.MTU != 1280 || c.Keepalive != 25 || len(c.DNS) < 1 || len(c.DNS) > 3 {
		return "", errors.New("invalid tunnel settings")
	}
	for _, d := range c.DNS {
		a, e := netip.ParseAddr(d)
		if e != nil || !a.Is4() || a.IsUnspecified() || a.IsMulticast() {
			return "", errors.New("invalid DNS server")
		}
	}
	if len(c.ManagementRoutes) > 16 {
		return "", errors.New("too many home management routes")
	}
	seen := map[string]bool{}
	for _, route := range c.ManagementRoutes {
		prefix, err := netip.ParsePrefix(route)
		if err != nil || !prefix.Addr().Is4() || !prefix.Addr().IsPrivate() || prefix.Bits() != 32 || seen[route] {
			return "", errors.New("invalid home management route")
		}
		seen[route] = true
	}
	allowed := "0.0.0.0/0, ::/0"
	if len(c.ManagementRoutes) > 0 {
		allowed += ", " + strings.Join(c.ManagementRoutes, ", ")
	}
	return fmt.Sprintf("[Interface]\nPrivateKey = %s\nAddress = %s, %s\nDNS = %s\nMTU = 1280\n\n[Peer]\nPublicKey = %s\nEndpoint = %s\nAllowedIPs = %s\nPersistentKeepalive = 25\n", c.PrivateKey, c.Address, c.AddressV6, strings.Join(c.DNS, ", "), c.PublicKey, c.Endpoint, allowed), nil
}
