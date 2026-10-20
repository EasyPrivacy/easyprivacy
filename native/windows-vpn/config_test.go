package main

import (
	"encoding/base64"
	"strings"
	"testing"
)

func TestTunnelConfigurationRejectsHooksAndRoutesOutsideTheContract(t *testing.T) {
	key := base64.StdEncoding.EncodeToString([]byte(strings.Repeat("a", 32)))
	good := Config{PrivateKey: key, PublicKey: key, Endpoint: "203.0.113.8:51821", Address: "10.87.0.2/32", AddressV6: "fd6e:7072:6976::2/128", DNS: []string{"1.1.1.1"}, MTU: 1280, Keepalive: 25}
	text, e := good.Text()
	if e != nil || !strings.Contains(text, "AllowedIPs = 0.0.0.0/0, ::/0") {
		t.Fatal("valid full-tunnel configuration rejected", e)
	}
	home := good
	home.ManagementRoutes = []string{"192.168.50.136/32", "192.168.50.137/32"}
	text, e = home.Text()
	if e != nil || !strings.Contains(text, "0.0.0.0/0, ::/0, 192.168.50.136/32, 192.168.50.137/32") {
		t.Fatal("management host routes lost full-tunnel protection", e)
	}
	for _, route := range []string{"8.8.8.8/32", "0.0.0.0/0", "192.168.50.0/24", "192.168.50.1/32\nPostUp = x"} {
		bad := good
		bad.ManagementRoutes = []string{route}
		if _, e = bad.Text(); e == nil {
			t.Fatal("unsafe management route accepted")
		}
	}
	for _, change := range []func(*Config){func(c *Config) { c.Endpoint = "example.com:51821\nPostUp = cmd.exe" }, func(c *Config) { c.DNS = []string{"1.1.1.1\nPostUp = x"} }, func(c *Config) { c.Address = "0.0.0.0/0" }, func(c *Config) { c.PrivateKey = "bad" }, func(c *Config) { c.MTU = 9000 }} {
		bad := good
		change(&bad)
		if _, e = bad.Text(); e == nil {
			t.Fatal("unsafe native tunnel configuration accepted")
		}
	}
}
