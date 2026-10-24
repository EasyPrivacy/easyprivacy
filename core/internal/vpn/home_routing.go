package vpn

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// A dedicated table with a terminal unreachable default prevents policy lookup
// from falling through to the VPS Internet route if the site disappears.
const homeTable = "51844"
const routeProtocol = "242"

func prepareHomeRouting() error {
	raw, err := command("ip", "", "-N", "-4", "route", "show", "table", "all")
	if err != nil {
		return err
	}
	for _, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		if strings.Contains(" "+line+" ", " table "+homeTable+" ") && !strings.Contains(line, "proto "+routeProtocol) {
			return errors.New("routing table 51844 is in use by another application")
		}
	}
	_, err = command("ip", "", "-4", "route", "replace", "unreachable", "default", "metric", "32767", "table", homeTable, "proto", routeProtocol)
	return err
}

func cleanupHomeRouting() error {
	raw, err := command("ip", "", "-N", "-j", "-4", "rule", "show")
	if err != nil {
		return err
	}
	var rules []struct {
		Priority int             `json:"priority"`
		Table    json.RawMessage `json:"table"`
		Protocol json.RawMessage `json:"protocol"`
	}
	if json.Unmarshal(raw, &rules) != nil {
		return errors.New("cannot read policy routes")
	}
	for _, r := range rules {
		if strings.Trim(string(r.Table), "\"") == homeTable && strings.Trim(string(r.Protocol), "\"") == routeProtocol {
			if _, err = command("ip", "", "-4", "rule", "del", "priority", fmt.Sprint(r.Priority), "table", homeTable, "protocol", routeProtocol); err != nil {
				return err
			}
		}
	}
	routes, err := command("ip", "", "-N", "-4", "route", "show", "table", "all")
	if err != nil {
		return err
	}
	for _, line := range strings.Split(string(routes), "\n") {
		if strings.Contains(" "+line+" ", " table "+homeTable+" ") && strings.Contains(line, "proto "+routeProtocol) {
			_, err = command("ip", "", "-4", "route", "flush", "table", homeTable, "proto", routeProtocol)
			return err
		}
	}
	return nil
}

func peerRules(c Config, p Peer) []rule {
	makeRule := func(args ...string) rule {
		head := append([]string{}, args[:len(args)-2]...)
		head = append(head, "-m", "comment", "--comment", fmt.Sprintf("easyprivacy-peer-%d", p.Host))
		head = append(head, args[len(args)-2:]...)
		return rule{"iptables", "filter", "FORWARD", head}
	}
	address := c.Address(p.Host)
	if p.Service {
		return nil
	}
	if p.Purpose == PrivatePurpose {
		// The dedicated chain has a terminal DROP and only leased receiver grants.
		jump := makeRule("-i", Interface, "-s", address, "-j", privateChain)
		drop := makeRule("-i", Interface, "-s", address, "-j", "DROP")
		drop.chain = "INPUT"
		probe := makeRule("-i", Interface, "-s", address, "-d", c.Address(1), "-p", "tcp", "--dport", fmt.Sprint(PrivateProbePort), "-j", "ACCEPT")
		probe.chain = "INPUT"
		return []rule{jump, drop, probe}
	}
	if p.ExitID != "home" {
		return []rule{makeRule("-i", Interface, "-o", c.Uplink, "-s", address, "-j", "ACCEPT")}
	}
	// Insert order is reversed by -I. Keep the explicit uplink guard even if a
	// policy route is accidentally missing, and preserve ordinary peer isolation.
	return []rule{
		makeRule("-i", Interface, "-o", c.Uplink, "-s", address, "-j", "DROP"),
		makeRule("-i", Interface, "-o", Interface, "!", "-s", c.Subnet, "-d", address, "-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED", "-j", "ACCEPT"),
		makeRule("-i", Interface, "-o", Interface, "-s", address, "!", "-d", c.Subnet, "-j", "ACCEPT"),
	}
}

func (l *Linux) configurePeerRouting(c Config, p Peer, remove bool) error {
	if remove {
		if err := applyRules(peerRules(c, p), true); err != nil {
			return err
		}
		if !p.Service && p.ExitID == "home" {
			// It is safe to delete this rule after its WireGuard peer has been removed.
			_, err := command("ip", "", "-4", "rule", "del", "priority", fmt.Sprint(18800+p.Host), "from", c.Address(p.Host), "table", homeTable, "protocol", routeProtocol)
			return err
		}
		return nil
	}
	if !p.Service && p.ExitID == "home" {
		if _, err := command("ip", "", "-4", "route", "replace", "default", "dev", Interface, "metric", "1", "table", homeTable, "proto", routeProtocol); err != nil {
			return err
		}
		// Refuse a conflicting priority rather than overriding somebody else's rule.
		raw, err := command("ip", "", "-4", "rule", "show", "priority", fmt.Sprint(18800+p.Host))
		if err != nil {
			return err
		}
		if strings.TrimSpace(string(raw)) != "" {
			return errors.New("home routing policy priority is already in use")
		}
		if _, err = command("ip", "", "-4", "rule", "add", "priority", fmt.Sprint(18800+p.Host), "from", c.Address(p.Host), "table", homeTable, "protocol", routeProtocol); err != nil {
			return err
		}
	}
	return applyRules(peerRules(c, p), false)
}
