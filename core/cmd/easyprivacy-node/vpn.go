package main

import (
	"bufio"
	"context"
	"errors"
	"flag"
	"fmt"
	"github.com/easyprivacy/easyprivacy/core/internal/node"
	"github.com/easyprivacy/easyprivacy/core/internal/vpn"
	"golang.org/x/term"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func runVPN(command string, args []string) error {
	fs := flag.NewFlagSet(command, flag.ContinueOnError)
	coreDir := fs.String("state-dir", node.DefaultStateDir, "core state directory")
	dir := fs.String("vpn-dir", vpn.Directory, "VPN state directory")
	socket := fs.String("socket", vpn.Socket, "private VPN control socket")
	if e := fs.Parse(args); e != nil {
		return e
	}
	if fs.NArg() != 0 {
		return errors.New("unexpected VPN arguments")
	}
	if command == "vpn-status" {
		v, e := (vpn.Client{SocketPath: *socket}).Info()
		if e != nil {
			return e
		}
		fmt.Printf("VPN exit: %s (%s)\nReady: %t\n", v.Name, v.ID, v.Ready)
		return nil
	}
	if os.Geteuid() != 0 {
		return errors.New("run VPN setup/administration with sudo")
	}
	if command == "vpn-setup" {
		if *coreDir != node.DefaultStateDir || *dir != vpn.Directory || *socket != vpn.Socket {
			return errors.New("VPN setup configures the installed node; omit directory overrides")
		}
		return vpnSetup()
	}
	c, e := vpn.LoadConfig(*dir)
	if e != nil {
		if command == "vpn-cleanup" {
			return vpn.CleanupBrokenConfig()
		}
		return e
	}
	backend := &vpn.Linux{}
	if command == "vpn-cleanup" {
		return cleanupVPN(c)
	}
	if command != "vpn-serve" {
		return errors.New("unknown VPN command")
	}
	group, e := user.LookupGroup("easyprivacy-node")
	if e != nil {
		return e
	}
	gid, e := strconv.Atoi(group.Gid)
	if e != nil {
		return e
	}
	auth := func() (map[string]bool, error) {
		store, e := node.OpenDeviceStore(filepath.Join(*coreDir, "runtime"))
		if e != nil {
			return nil, e
		}
		active := map[string]bool{}
		for _, d := range store.List() {
			active[d.ID] = !d.Revoked
		}
		return active, nil
	}
	manager, e := vpn.NewManager(c, *dir, backend, auth)
	if e != nil {
		return e
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	return manager.Serve(ctx, *socket, gid)
}

func cleanupVPN(c vpn.Config) error { return vpn.Cleanup(c) }
func vpnSetup() error {
	state, e := node.Load(node.DefaultStateDir)
	if e != nil {
		return fmt.Errorf("complete core setup first: %w", e)
	}
	if c, e := vpn.LoadConfig(vpn.Directory); e == nil {
		return enableVPN(c)
	} else if !errors.Is(e, os.ErrNotExist) {
		return e
	}
	if !term.IsTerminal(int(os.Stdin.Fd())) {
		return errors.New("VPN setup needs an interactive terminal")
	}
	fmt.Println("EasyPrivacy VPN exit setup\nThe VPS will carry IPv4 Internet traffic. IPv6 is blocked through this first exit.")
	reader := bufio.NewReader(os.Stdin)
	ask := func(label, def string) (string, error) {
		fmt.Printf("%s [%s]: ", label, def)
		s, e := reader.ReadString('\n')
		s = strings.TrimSpace(s)
		if s == "" {
			s = def
		}
		return s, e
	}
	output, e := exec.Command("ip", "-4", "route", "show", "default").Output()
	if e != nil {
		return e
	}
	fields := strings.Fields(string(output))
	uplink := ""
	for i, f := range fields {
		if f == "dev" && i+1 < len(fields) {
			uplink = fields[i+1]
			break
		}
	}
	hostDefault := detectVPNHost(uplink)
	fmt.Println("Devices reach the VPN at this address. Enter a public IP or DNS name, without a port.")
	if hostDefault != "" {
		fmt.Printf("Detected public IPv4 on %s. Press Enter to accept it, or enter your preferred DNS name.\n", uplink)
	} else {
		fmt.Println("No single public IPv4 was detected on the Internet interface. Use your VPS dashboard's public IP or your DNS name.")
	}
	host, e := ask("Public hostname or IP of this VPS", hostDefault)
	if e != nil {
		return e
	}
	portText, e := ask("VPN UDP port", "51821")
	if e != nil {
		return e
	}
	port, e := strconv.Atoi(portText)
	if e != nil {
		return e
	}
	subnet, e := ask("Private tunnel network", "10.87.0.0/24")
	if e != nil {
		return e
	}
	uplink, e = ask("Internet network interface", uplink)
	if e != nil {
		return e
	}
	dns, e := ask("DNS servers, comma-separated", "1.1.1.1,9.9.9.9")
	if e != nil {
		return e
	}
	dnsValues := strings.Split(dns, ",")
	for i := range dnsValues {
		dnsValues[i] = strings.TrimSpace(dnsValues[i])
	}
	key, e := vpn.GenerateKey()
	if e != nil {
		return e
	}
	c := vpn.Config{Schema: 1, Name: state.Name, Endpoint: net.JoinHostPort(strings.Trim(host, "[]"), strconv.Itoa(port)), Port: port, Subnet: subnet, Uplink: uplink, DNS: dnsValues, PrivateKey: key}
	if e = c.Validate(); e != nil {
		return e
	}
	listener, e := net.ListenPacket("udp", fmt.Sprintf(":%d", port))
	if e != nil {
		return fmt.Errorf("UDP port unavailable: %w", e)
	}
	listener.Close()
	routes, e := exec.Command("ip", "-4", "route", "show", "table", "all").Output()
	if e != nil {
		return e
	}
	if e = vpn.CheckRoutes(subnet, string(routes)); e != nil {
		return e
	}
	if info, e := os.Lstat(vpn.Directory); e == nil {
		if !info.IsDir() || info.Mode().Perm() != 0700 {
			return errors.New("VPN state directory must be a private regular directory")
		}
	} else if !errors.Is(e, os.ErrNotExist) {
		return e
	}
	if e = os.MkdirAll(vpn.Directory, 0700); e != nil {
		return e
	}
	if e = vpn.SavePrivate(filepath.Join(vpn.Directory, "vpn.json"), c); e != nil {
		return e
	}
	return enableVPN(c)
}
func enableVPN(c vpn.Config) error {
	if e := os.WriteFile(filepath.Join(node.DefaultStateDir, "vpn-enabled"), []byte("1\n"), 0644); e != nil {
		return e
	}
	if e := os.WriteFile("/etc/sysctl.d/70-easyprivacy-vpn.conf", []byte("# EasyPrivacy VPN IPv4 forwarding\nnet.ipv4.ip_forward = 1\n"), 0644); e != nil {
		return e
	}
	if e := exec.Command("sysctl", "-w", "net.ipv4.ip_forward=1").Run(); e != nil {
		return e
	}
	if path, e := exec.LookPath("ufw"); e == nil {
		cmd := exec.Command(path, "status")
		cmd.Env = append(os.Environ(), "LC_ALL=C")
		out, e := cmd.Output()
		if e != nil {
			return e
		}
		first, _, _ := strings.Cut(string(out), "\n")
		if first == "Status: active" {
			cmd = exec.Command(path, "allow", fmt.Sprintf("%d/udp", c.Port))
			cmd.Env = append(os.Environ(), "LC_ALL=C")
			if e = cmd.Run(); e != nil {
				return e
			}
		} else if first != "Status: inactive" {
			return errors.New("unknown UFW state; inspect sudo ufw status")
		}
	}
	if e := exec.Command("systemctl", "enable", "--now", "easyprivacy-vpn.service").Run(); e != nil {
		return e
	}
	var info vpn.Exit
	var e error
	deadline := time.Now().Add(10 * time.Second)
	for {
		info, e = (vpn.Client{SocketPath: vpn.Socket}).Info()
		if e == nil || time.Now().After(deadline) {
			break
		}
		time.Sleep(150 * time.Millisecond)
	}
	if e != nil {
		return fmt.Errorf("VPN service not ready; inspect sudo journalctl -u easyprivacy-vpn: %w", e)
	}
	fmt.Printf("VPN exit ready: %s\nEndpoint: %s\nAllow inbound UDP %d in the VPS provider firewall.\nConnect to this core in EasyPrivacy and choose Connect VPN.\n", info.Name, c.Endpoint, c.Port)
	return nil
}
