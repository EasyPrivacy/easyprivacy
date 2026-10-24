package vpn

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

type Linux struct {
	config Config
	peers  map[string]Peer
	probe  net.Listener
}

func Cleanup(c Config) error { return (&Linux{config: c}).Down() }
func CleanupBrokenConfig() error {
	return (&Linux{}).Down()
}
func command(name, input string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	if input != "" {
		cmd.Stdin = strings.NewReader(input)
	}
	b, e := cmd.Output()
	if e != nil {
		return nil, fmt.Errorf("VPN network command %s failed", name)
	}
	if len(b) > 131072 {
		return nil, errors.New("network response too large")
	}
	return b, nil
}
func ownedInterface() (bool, error) {
	b, e := command("ip", "", "-j", "link", "show", "dev", Interface)
	if e != nil {
		return false, nil
	}
	var links []struct {
		Alias string `json:"ifalias"`
	}
	if json.Unmarshal(b, &links) != nil || len(links) != 1 || links[0].Alias != "easyprivacy-vpn-v1" {
		return false, errors.New("epwg0 already exists and is not owned by EasyPrivacy")
	}
	return true, nil
}

type rule struct {
	tool, table, chain string
	args               []string
}

func rules(c Config) []rule {
	comment := []string{"-m", "comment", "--comment", "easyprivacy-vpn-v1"}
	makeRule := func(tool, table, chain string, args ...string) rule {
		prefix := append([]string{}, args[:len(args)-2]...)
		prefix = append(prefix, comment...)
		prefix = append(prefix, args[len(args)-2:]...)
		return rule{tool, table, chain, prefix}
	}
	// Insert drops first, then scoped accepts so the accepts precede the drops.
	result := []rule{
		makeRule("iptables", "filter", "FORWARD", "-i", Interface, "-j", "DROP"),
		makeRule("iptables", "filter", "FORWARD", "-o", Interface, "-j", "DROP"),
		makeRule("ip6tables", "filter", "FORWARD", "-i", Interface, "-j", "DROP"),
		makeRule("ip6tables", "filter", "FORWARD", "-o", Interface, "-j", "DROP"),
	}
	if !c.PrivateOnly {
		result = append(result,
			makeRule("iptables", "filter", "FORWARD", "-i", c.Uplink, "-o", Interface, "-d", c.Subnet, "-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED", "-j", "ACCEPT"),
			makeRule("iptables", "nat", "POSTROUTING", "-s", c.Subnet, "-o", c.Uplink, "-j", "MASQUERADE"))
	}
	return result
}
func setRules(c Config, remove bool) error {
	return applyRules(rules(c), remove)
}
func applyRules(rules []rule, remove bool) error {
	for _, r := range rules {
		base := []string{"-w", "3", "-t", r.table}
		check := append(append([]string{}, base...), "-C", r.chain)
		check = append(check, r.args...)
		_, exists := command(r.tool, "", check...)
		if remove {
			if exists == nil {
				args := append(append([]string{}, base...), "-D", r.chain)
				args = append(args, r.args...)
				if _, e := command(r.tool, "", args...); e != nil {
					return e
				}
			}
		} else if exists != nil {
			args := append(append([]string{}, base...), "-I", r.chain, "1")
			args = append(args, r.args...)
			if _, e := command(r.tool, "", args...); e != nil {
				return e
			}
		}
	}
	return nil
}
func (l *Linux) Up(c Config) (err error) {
	if l.probe != nil {
		_ = l.probe.Close()
		l.probe = nil
	}
	l.config = c
	l.peers = map[string]Peer{}
	if e := c.Validate(); e != nil {
		return e
	}
	owned, e := ownedInterface()
	if e != nil {
		return e
	}
	if owned {
		if e = l.Down(); e != nil {
			return e
		}
	}
	if e = cleanupCoreRules(); e != nil {
		return e
	}
	if e = cleanupHomeRouting(); e != nil {
		return e
	}
	if e := preparePrivateChain(); e != nil {
		return e
	}
	if !c.PrivateOnly {
		if e := prepareHomeRouting(); e != nil {
			return e
		}
	}
	forward, e := os.ReadFile("/proc/sys/net/ipv4/ip_forward")
	if e != nil || strings.TrimSpace(string(forward)) != "1" {
		return errors.New("IPv4 forwarding is disabled; run sudo easyprivacy-node vpn-setup")
	}
	// Reject overlapping routes before adding this interface. Never alter wg0.
	routes, e := command("ip", "", "-4", "route", "show", "table", "all")
	if e != nil {
		return e
	}
	if e = CheckRoutes(c.Subnet, string(routes)); e != nil {
		return e
	}
	v6routes, e := command("ip", "", "-6", "route", "show", "table", "all")
	if e != nil {
		return e
	}
	if CheckRoutes(IPv6Prefix+"/64", string(v6routes)) != nil {
		return errors.New("the VPN IPv6 protection subnet is already in use by another interface")
	}
	if _, e = command("ip", "", "link", "add", Interface, "type", "wireguard"); e != nil {
		return e
	}
	if _, e = command("ip", "", "link", "set", "dev", Interface, "alias", "easyprivacy-vpn-v1"); e != nil {
		_, _ = command("ip", "", "link", "delete", Interface)
		return e
	}
	defer func() {
		if err != nil {
			_ = l.Down()
		}
	}()
	network := strings.TrimSuffix(c.Address(1), "/32") + "/24"
	if _, e = command("ip", "", "address", "add", network, "dev", Interface); e != nil {
		return e
	}
	if _, e = command("ip", "", "-6", "address", "add", IPv6Prefix+"1/64", "dev", Interface); e != nil {
		return e
	}
	text := fmt.Sprintf("[Interface]\nPrivateKey = %s\nListenPort = %d\n", c.PrivateKey, c.Port)
	if _, e = command("wg", text, "setconf", Interface, "/dev/stdin"); e != nil {
		return e
	}
	if _, e = command("ip", "", "link", "set", "dev", Interface, "mtu", "1280", "up"); e != nil {
		return e
	}
	if e = setRules(c, false); e != nil {
		return e
	}
	return l.startPrivateProbe(c)
}
func (l *Linux) SetPeer(c Config, p Peer) error {
	if l.peers == nil {
		l.peers = map[string]Peer{}
	}
	if old, ok := l.peers[p.PublicKey]; ok {
		if old == p {
			return nil
		}
		// Disable the peer before changing routes: a partial update cannot leak
		// a home-selected connection through the VPS uplink.
		if e := l.RemovePeer(old.PublicKey); e != nil {
			return e
		}
	}
	if err := l.configurePeerRouting(c, p, false); err != nil {
		return err
	}
	allowed := c.Address(p.Host) + "," + fmt.Sprintf("%s%x/128", IPv6Prefix, p.Host)
	if p.Purpose == PrivatePurpose {
		allowed = c.Address(p.Host)
	}
	if p.Service {
		allowed = "0.0.0.0/0"
	}
	_, e := command("wg", "", "set", Interface, "peer", p.PublicKey, "allowed-ips", allowed)
	if e != nil {
		_ = l.configurePeerRouting(c, p, true)
		return e
	}
	l.peers[p.PublicKey] = p
	return nil
}
func (l *Linux) RemovePeer(key string) error {
	if _, e := Key(key); e != nil {
		return e
	}
	_, e := command("wg", "", "set", Interface, "peer", key, "remove")
	if e == nil {
		if p, ok := l.peers[key]; ok {
			e = l.configurePeerRouting(l.config, p, true)
			if e == nil {
				delete(l.peers, key)
			}
		}
	}
	return e
}
func (l *Linux) PeerStatus(key string) (Status, error) {
	return interfaceStatus(Interface, key)
}
func interfaceStatus(iface, key string) (Status, error) {
	var s Status
	b, e := command("wg", "", "show", iface, "latest-handshakes")
	if e != nil {
		return s, e
	}
	for _, line := range bytes.Split(b, []byte{'\n'}) {
		v := strings.Fields(string(line))
		if len(v) == 2 && v[0] == key {
			s.Active = true
			s.LastHandshake, _ = strconv.ParseInt(v[1], 10, 64)
		}
	}
	b, e = command("wg", "", "show", iface, "transfer")
	if e != nil {
		return s, e
	}
	for _, line := range bytes.Split(b, []byte{'\n'}) {
		v := strings.Fields(string(line))
		if len(v) == 3 && v[0] == key {
			s.Received, _ = strconv.ParseUint(v[1], 10, 64)
			s.Sent, _ = strconv.ParseUint(v[2], 10, 64)
		}
	}
	return s, nil
}
func (l *Linux) Down() error {
	if l.probe != nil {
		_ = l.probe.Close()
		l.probe = nil
	}
	owned, e := ownedInterface()
	if e != nil {
		return e
	}
	// Remove the ingress interface first, including on crash cleanup where the
	// in-memory peer map is unavailable. Then remove only our tagged rules.
	if owned {
		if _, e = command("ip", "", "link", "delete", Interface); e != nil {
			return e
		}
	}
	l.peers = map[string]Peer{}
	if e = cleanupCoreRules(); e != nil {
		return e
	}
	if e = cleanupPrivateChain(); e != nil {
		return e
	}
	return cleanupHomeRouting()
}

func removeTaggedRules(tool, table, chain string, matches func(string) bool) error {
	raw, err := command(tool, "", "-w", "3", "-t", table, "-S", chain)
	if err != nil {
		return err
	}
	for _, line := range strings.Split(string(raw), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 3 || fields[0] != "-A" || fields[1] != chain {
			continue
		}
		match := false
		for i, f := range fields {
			if f == "--comment" && i+1 < len(fields) && matches(strings.Trim(fields[i+1], "\"")) {
				match = true
			}
		}
		if !match {
			continue
		}
		args := append([]string{"-w", "3", "-t", table, "-D", chain}, fields[2:]...)
		// iptables quotes comment strings when printing them.
		for i := range args {
			if i > 0 && args[i-1] == "--comment" {
				args[i] = strings.Trim(args[i], "\"")
			}
		}
		if _, err = command(tool, "", args...); err != nil {
			return err
		}
	}
	return nil
}
func cleanupCoreRules() error {
	match := func(tag string) bool {
		if tag == "easyprivacy-vpn-v1" {
			return true
		}
		if !strings.HasPrefix(tag, "easyprivacy-peer-") {
			return false
		}
		host, err := strconv.Atoi(strings.TrimPrefix(tag, "easyprivacy-peer-"))
		return err == nil && host >= 2 && host <= 254
	}
	for _, r := range [][3]string{{"iptables", "filter", "FORWARD"}, {"iptables", "filter", "INPUT"}, {"iptables", "nat", "POSTROUTING"}, {"ip6tables", "filter", "FORWARD"}} {
		if err := removeTaggedRules(r[0], r[1], r[2], match); err != nil {
			return err
		}
	}
	return nil
}
