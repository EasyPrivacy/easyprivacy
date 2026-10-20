package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/easyprivacy/easyprivacy/core/internal/link"
	"github.com/easyprivacy/easyprivacy/core/internal/vpn"
	"golang.org/x/term"
)

const serviceDir = "/var/lib/easyprivacy-service"
const serviceStatusPath = "/run/easyprivacy-service/status.json"
const serviceInfoPath = "/var/lib/easyprivacy-service-info.json"

type serviceConfig struct {
	Schema     int           `json:"schema"`
	Name       string        `json:"name"`
	Identity   link.Identity `json:"identity"`
	PrivateKey string        `json:"private_key"`
	Uplink     string        `json:"uplink"`
	Management string        `json:"management_addresses,omitempty"`
}
type serviceStatus struct {
	Configured bool   `json:"configured"`
	Running    bool   `json:"running"`
	Installed  bool   `json:"installed"`
	Active     bool   `json:"active"`
	Name       string `json:"name,omitempty"`
	Core       string `json:"core,omitempty"`
	Message    string `json:"message,omitempty"`
	vpn.Status
}

func (c serviceConfig) validate() error {
	if _, err := vpn.ManagementRoutes(c.Management); err != nil {
		return err
	}
	if c.Schema != 1 || strings.TrimSpace(c.Name) == "" || len(c.Name) > 80 || strings.ContainsAny(c.Name, "\r\n\x00") {
		return errors.New("invalid service name")
	}
	if _, err := link.Authority(c.Identity.Address); err != nil {
		return err
	}
	key, err := c.Identity.PrivateKey()
	clear(key)
	if err != nil {
		return err
	}
	check := vpn.Config{Schema: 1, Name: c.Name, Endpoint: "127.0.0.1:51821", Port: 51821, Subnet: "10.87.0.0/24", Uplink: c.Uplink, DNS: []string{"1.1.1.1"}, PrivateKey: c.PrivateKey}
	return check.Validate()
}
func serviceUplink() (string, error) {
	raw, err := exec.Command("ip", "-4", "route", "show", "default").Output()
	if err != nil {
		return "", err
	}
	fields := strings.Fields(string(raw))
	for i, s := range fields {
		if s == "dev" && i+1 < len(fields) {
			return fields[i+1], nil
		}
	}
	return "", errors.New("no IPv4 Internet uplink was detected")
}
func runService(action string, args []string) error {
	if len(args) != 0 {
		return errors.New("unexpected service-node arguments")
	}
	if action == "service-status" {
		raw, err := os.ReadFile(serviceStatusPath)
		if err != nil {
			raw, err = os.ReadFile(serviceInfoPath)
		}
		if err == nil {
			var status serviceStatus
			if json.Unmarshal(raw, &status) == nil {
				return json.NewEncoder(os.Stdout).Encode(status)
			}
		}
		return json.NewEncoder(os.Stdout).Encode(serviceStatus{Installed: true, Message: "Home service is stopped or has not been configured."})
	}
	if os.Geteuid() != 0 {
		return errors.New("run service-node setup/administration with sudo")
	}
	switch action {
	case "service-setup":
		return setupService()
	case "service-install":
		// GUI enrollment uses exactly the same installed daemon/configuration as CLI.
		var input struct {
			Identity   link.Identity `json:"identity"`
			Name       string        `json:"name"`
			Uplink     string        `json:"uplink"`
			Management string        `json:"management_addresses"`
		}
		decoder := json.NewDecoder(io.LimitReader(os.Stdin, 16385))
		decoder.DisallowUnknownFields()
		var extra any
		if decoder.Decode(&input) != nil || decoder.Decode(&extra) != io.EOF {
			return errors.New("invalid service setup request")
		}
		return installService(input.Identity, input.Name, input.Uplink, input.Management)
	case "service-start", "service-stop":
		verb := "start"
		if action == "service-stop" {
			verb = "stop"
		}
		if verb == "start" {
			if _, err := loadService(); err != nil {
				return err
			}
		}
		return exec.Command("systemctl", verb, "easyprivacy-service.service").Run()
	case "service-cleanup":
		return vpn.SiteDown(vpn.SiteConfig{})
	case "service-forget":
		if err := exec.Command("systemctl", "disable", "--now", "easyprivacy-service.service").Run(); err != nil {
			return err
		}
		if c, err := loadService(); err == nil {
			_ = disconnectSite(c.Identity)
		}
		if err := vpn.SiteDown(vpn.SiteConfig{}); err != nil {
			return err
		}
		for _, path := range []string{filepath.Join(serviceDir, "service.json"), filepath.Join(serviceDir, "site.json"), serviceInfoPath} {
			if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
				return err
			}
		}
		fmt.Println("Local home-service identity removed. Revoke its old paired-device entry on the core if it is no longer needed.")
		return nil
	case "service-serve":
		return serveService()
	default:
		return errors.New("unknown service-node command")
	}
}
func loadService() (serviceConfig, error) {
	var c serviceConfig
	err := vpn.ReadPrivate(filepath.Join(serviceDir, "service.json"), &c)
	if err == nil {
		err = c.validate()
	}
	return c, err
}
func setupService() error {
	if !term.IsTerminal(int(os.Stdin.Fd())) {
		return errors.New("service setup needs an interactive terminal")
	}
	if _, err := loadService(); err == nil {
		return exec.Command("systemctl", "enable", "--now", "easyprivacy-service.service").Run()
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	fmt.Println("Home service-node setup\nThis VM connects outbound to your VPS and offers your home Internet/LAN through it.\nYour VPS is trusted with traffic between the two encrypted VPN legs.")
	reader := bufio.NewReader(os.Stdin)
	ask := func(label, def string) (string, error) {
		fmt.Printf("%s [%s]: ", label, def)
		s, err := reader.ReadString('\n')
		s = strings.TrimSpace(s)
		if s == "" {
			s = def
		}
		return s, err
	}
	address, err := ask("Core address (management port)", "")
	if err != nil {
		return err
	}
	name, err := ask("Home exit name", "Home")
	if err != nil {
		return err
	}
	code, err := ask("Pairing code displayed by your core or a paired device", "")
	if err != nil {
		return err
	}
	username, err := ask("Core username", "")
	if err != nil {
		return err
	}
	fmt.Print("Core password: ")
	password, err := term.ReadPassword(int(os.Stdin.Fd()))
	fmt.Println()
	if err != nil {
		return err
	}
	defer clear(password)
	identity, err := link.Enroll(address, strings.ReplaceAll(code, " ", ""), name, username, string(password))
	if err != nil {
		return err
	}
	uplink, err := serviceUplink()
	if err != nil {
		return err
	}
	uplink, err = ask("Home LAN / Internet interface", uplink)
	if err != nil {
		return err
	}
	management, err := ask("Server management IPv4 addresses, comma-separated (without ports)", "")
	if err != nil {
		return err
	}
	return installService(identity, name, uplink, management)
}
func installService(identity link.Identity, name, uplink, management string) error {
	if _, err := os.Lstat(filepath.Join(serviceDir, "service.json")); err == nil {
		return errors.New("a home identity is already installed; use service-start or revoke the old identity before replacing its configuration")
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if uplink == "" {
		var err error
		uplink, err = serviceUplink()
		if err != nil {
			return err
		}
	}
	key, err := vpn.GenerateKey()
	if err != nil {
		return err
	}
	if _, err := vpn.ManagementRoutes(management); err != nil {
		return err
	}
	// Include SSH to this VM. Explicit /32 routes also work when the remote
	// device happens to use the same LAN range as the home network.
	iface, err := net.InterfaceByName(uplink)
	if err != nil {
		return err
	}
	addresses, err := iface.Addrs()
	if err != nil {
		return err
	}
	values := []string{}
	seen := map[string]bool{}
	for _, value := range strings.Split(management, ",") {
		value = strings.TrimSpace(value)
		if value != "" {
			values = append(values, value)
			seen[value] = true
		}
	}
	for _, value := range addresses {
		prefix, e := netip.ParsePrefix(value.String())
		if e == nil && prefix.Addr().Is4() && prefix.Addr().IsPrivate() && !seen[prefix.Addr().String()] {
			values = append(values, prefix.Addr().String())
			seen[prefix.Addr().String()] = true
		}
	}
	management = strings.Join(values, ",")
	c := serviceConfig{Schema: 1, Name: name, Identity: identity, PrivateKey: key, Uplink: uplink, Management: management}
	if err = c.validate(); err != nil {
		return err
	}
	// Fetch and validate a real profile before persisting/starting this role.
	profile, err := registerSite(c)
	if err != nil {
		return err
	}
	persisted := false
	defer func() {
		if !persisted {
			_ = disconnectSite(identity)
		}
	}()
	routes, err := exec.Command("ip", "-4", "route", "show", "table", "all").Output()
	if err != nil {
		return err
	}
	if err = vpn.CheckRoutes(profile.Subnet, string(routes)); err != nil {
		return fmt.Errorf("the core VPN network overlaps a home network: %w", err)
	}
	if info, err := os.Lstat(serviceDir); err == nil {
		if !info.IsDir() || info.Mode().Perm() != 0700 {
			return errors.New("service state must be a private directory")
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err = os.MkdirAll(serviceDir, 0700); err != nil {
		return err
	}
	if err = vpn.SavePrivate(filepath.Join(serviceDir, "service.json"), c); err != nil {
		return err
	}
	persisted = true
	if err = vpn.SavePrivate(filepath.Join(serviceDir, "site.json"), profile); err != nil {
		return err
	}
	info := serviceStatus{Installed: true, Configured: true, Name: name, Core: identity.Address, Message: "Home service is stopped."}
	if err = vpn.SavePrivate(serviceInfoPath, info); err != nil {
		return err
	}
	if err = os.Chmod(serviceInfoPath, 0644); err != nil {
		return err
	}
	if err = exec.Command("systemctl", "enable", "--now", "easyprivacy-service.service").Run(); err != nil {
		return err
	}
	fmt.Println("Home service installed. It starts automatically after reboot.\nCheck: sudo easyprivacy-node service-status\nRefresh the app's Internet exits, then choose your home exit.")
	return nil
}
func registerSite(c serviceConfig) (vpn.SiteConfig, error) {
	client := link.Client{Identity: c.Identity}
	token, err := client.Login()
	if err != nil {
		return vpn.SiteConfig{}, err
	}
	defer client.Request("POST", "/api/v1/logout", token, nil, nil)
	public := vpn.Config{PrivateKey: c.PrivateKey}.PublicKey()
	var profile vpn.ServiceProfile
	err = client.Request("POST", "/api/v1/vpn/service", token, map[string]string{"name": c.Name, "public_key": public, "management_addresses": c.Management}, &profile)
	site := vpn.SiteConfig{ServiceProfile: profile, PrivateKey: c.PrivateKey, Uplink: c.Uplink}
	if err == nil {
		err = site.Validate()
	}
	return site, err
}
func disconnectSite(identity link.Identity) error {
	client := link.Client{Identity: identity}
	token, err := client.Login()
	if err != nil {
		return err
	}
	defer client.Request("POST", "/api/v1/logout", token, nil, nil)
	return client.Request("POST", "/api/v1/vpn/disconnect", token, nil, nil)
}
func serveService() error {
	c, err := loadService()
	if err != nil {
		return err
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	var current vpn.SiteConfig
	active := false
	defer func() {
		if active {
			_ = vpn.SiteDown(current)
		}
		_ = os.Remove(serviceStatusPath)
	}()
	report := func(message string) {
		status := serviceStatus{Installed: true, Configured: true, Running: true, Name: c.Name, Core: c.Identity.Address, Message: message}
		if active {
			status.Status, _ = vpn.SiteStatus(current.PublicKey)
			status.Active = status.Status.Active
			status.Status.Active = false
		}
		// Only sanitized status is public; identity and WireGuard keys stay root-only.
		if err := vpn.SavePrivate(serviceStatusPath, status); err == nil {
			_ = os.Chmod(serviceStatusPath, 0644)
		}
	}
	next := time.Time{}
	lastMessage := ""
	ticker := time.NewTicker(3 * time.Second)
	defer ticker.Stop()
	for {
		if !time.Now().Before(next) {
			site, err := registerSite(c)
			if err != nil {
				var rejected *link.HTTPError
				if errors.As(err, &rejected) && (rejected.Code == 401 || rejected.Code == 403) {
					if active {
						_ = vpn.SiteDown(current)
						active = false
					}
					report("Device authorization was rejected. Re-enroll this service node.")
					return err
				}
				lastMessage = err.Error()
				report(lastMessage)
				next = time.Now().Add(30 * time.Second)
			} else {
				before, _ := json.Marshal(current)
				after, _ := json.Marshal(site)
				status, _ := vpn.SiteStatus(site.PublicKey)
				if !active || string(before) != string(after) || !status.Active {
					if active {
						if err = vpn.SiteDown(current); err != nil {
							return err
						}
						active = false
					}
					if err = vpn.SavePrivate(filepath.Join(serviceDir, "site.json"), site); err != nil {
						return err
					}
					if err = vpn.SiteUp(site); err != nil {
						report(err.Error())
						return err
					}
					current = site
					active = true
				}
				lastMessage = ""
				report(lastMessage)
				next = time.Now().Add(30 * time.Second)
			}
		} else {
			report(lastMessage)
		}
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
		}
	}
}
