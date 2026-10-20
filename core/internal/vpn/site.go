package vpn

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"strconv"
)

const SiteInterface = "epsite0"
const siteAlias = "easyprivacy-site-v1"

type SiteConfig struct {
	ServiceProfile
	PrivateKey string `json:"private_key"`
	Uplink     string `json:"uplink"`
}

func (c SiteConfig) Validate() error {
	// Reuse the strict privileged-config validation, including interface/endpoint
	// syntax. Neither a server response nor GUI input may inject network commands.
	_, port, err := splitEndpoint(c.Endpoint)
	if err != nil {
		return err
	}
	check := Config{Schema: 1, Name: c.ExitName, Endpoint: c.Endpoint, Port: port, Subnet: c.Subnet, Uplink: c.Uplink, DNS: c.DNS, PrivateKey: c.PrivateKey}
	if err := check.Validate(); err != nil {
		return err
	}
	if c.Uplink == SiteInterface {
		return errors.New("the site uplink cannot be its own tunnel")
	}
	if _, err := Key(c.PublicKey); err != nil {
		return err
	}
	subnet, _ := netip.ParsePrefix(c.Subnet)
	addr, err := netip.ParsePrefix(c.Address)
	if err != nil || !addr.Addr().Is4() || addr.Bits() != 32 || !subnet.Contains(addr.Addr()) || addr.Addr() == subnet.Addr() || addr.Addr().As4()[3] < 2 || addr.Addr().As4()[3] > 254 || c.MTU != 1280 || c.Keepalive != 25 || len(c.AllowedIPs) != 1 || c.AllowedIPs[0] != c.Subnet {
		return errors.New("invalid service-node tunnel profile")
	}
	return nil
}

func siteOwned() (bool, error) {
	raw, err := command("ip", "", "-j", "link", "show", "dev", SiteInterface)
	if err != nil {
		return false, nil
	}
	var links []struct {
		Alias string `json:"ifalias"`
	}
	if json.Unmarshal(raw, &links) != nil || len(links) != 1 || links[0].Alias != siteAlias {
		return false, errors.New("epsite0 is owned by another application")
	}
	return true, nil
}
func siteRules(c SiteConfig) []rule {
	makeRule := func(table, chain string, args ...string) rule {
		head := append([]string{}, args[:len(args)-2]...)
		head = append(head, "-m", "comment", "--comment", siteAlias)
		head = append(head, args[len(args)-2:]...)
		return rule{"iptables", table, chain, head}
	}
	return []rule{
		makeRule("filter", "FORWARD", "-i", SiteInterface, "-j", "DROP"),
		makeRule("filter", "FORWARD", "-o", SiteInterface, "-j", "DROP"),
		makeRule("filter", "FORWARD", "-i", c.Uplink, "-o", SiteInterface, "-d", c.Subnet, "-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED", "-j", "ACCEPT"),
		makeRule("filter", "FORWARD", "-i", SiteInterface, "-o", c.Uplink, "-s", c.Subnet, "!", "-d", c.Subnet, "-j", "ACCEPT"),
		makeRule("nat", "POSTROUTING", "-s", c.Subnet, "-o", c.Uplink, "-j", "MASQUERADE"),
		// SSH to the VM itself also works when UFW's default input policy is deny.
		makeRule("filter", "INPUT", "-i", SiteInterface, "-s", c.Subnet, "-p", "tcp", "--dport", "22", "-j", "ACCEPT"),
	}
}

func SiteDown(c SiteConfig) error {
	owned, err := siteOwned()
	if err != nil {
		return err
	}
	if owned {
		if _, err = command("ip", "", "link", "delete", SiteInterface); err != nil {
			return err
		}
	}
	for _, r := range [][2]string{{"filter", "FORWARD"}, {"filter", "INPUT"}, {"nat", "POSTROUTING"}} {
		if err := removeTaggedRules("iptables", r[0], r[1], func(tag string) bool { return tag == siteAlias }); err != nil {
			return err
		}
	}
	return nil
}
func SiteUp(c SiteConfig) (err error) {
	if err = c.Validate(); err != nil {
		return err
	}
	if err = SiteDown(c); err != nil {
		return err
	}
	raw, err := command("ip", "", "-4", "route", "show", "table", "all")
	if err != nil {
		return err
	}
	if err = CheckRoutes(c.Subnet, string(raw)); err != nil {
		return fmt.Errorf("home LAN conflicts with the core's tunnel network: %w", err)
	}
	if _, err = command("ip", "", "link", "add", SiteInterface, "type", "wireguard"); err != nil {
		return err
	}
	if _, err = command("ip", "", "link", "set", "dev", SiteInterface, "alias", siteAlias); err != nil {
		_, _ = command("ip", "", "link", "delete", SiteInterface)
		return err
	}
	defer func() {
		if err != nil {
			_ = SiteDown(c)
		}
	}()
	if _, err = command("ip", "", "address", "add", c.Address, "dev", SiteInterface); err != nil {
		return err
	}
	conf := fmt.Sprintf("[Interface]\nPrivateKey = %s\n[Peer]\nPublicKey = %s\nEndpoint = %s\nAllowedIPs = %s\nPersistentKeepalive = 25\n", c.PrivateKey, c.PublicKey, c.Endpoint, c.Subnet)
	if _, err = command("wg", conf, "setconf", SiteInterface, "/dev/stdin"); err != nil {
		return err
	}
	if _, err = command("ip", "", "link", "set", SiteInterface, "mtu", "1280", "up"); err != nil {
		return err
	}
	if _, err = command("ip", "", "-4", "route", "add", c.Subnet, "dev", SiteInterface); err != nil {
		return err
	}
	if _, err = command("sysctl", "", "-w", "net.ipv4.ip_forward=1", "net.ipv4.conf."+SiteInterface+".rp_filter=2"); err != nil {
		return err
	}
	return applyRules(siteRules(c), false)
}
func SiteStatus(key string) (Status, error) { return interfaceStatus(SiteInterface, key) }
func splitEndpoint(endpoint string) (string, int, error) {
	host, portText, err := net.SplitHostPort(endpoint)
	if err != nil {
		return "", 0, err
	}
	port, err := strconv.Atoi(portText)
	return host, port, err
}

// The site intentionally receives no IPv6 route: the existing client/core
// protection continues to capture and block IPv6 rather than leak it locally.
