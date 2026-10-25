package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/easyprivacy/easyprivacy/core/internal/node"
	"github.com/easyprivacy/easyprivacy/core/internal/vpn"
	"golang.org/x/term"
)

var version = "1.0.0"

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "EasyPrivacy:", err)
		os.Exit(1)
	}
}

func run() error {
	if len(os.Args) < 2 {
		return errors.New("usage: easyprivacy-node <setup|serve|identity|firewall|pair|devices|revoke|version> [--state-dir PATH]")
	}
	command := os.Args[1]
	if strings.HasPrefix(command, "drive-") {
		return runDrive(command, os.Args[2:])
	}
	if strings.HasPrefix(command, "service-") {
		return runService(command, os.Args[2:])
	}
	if strings.HasPrefix(command, "vpn-") || strings.HasPrefix(command, "network-") {
		return runVPN(command, os.Args[2:])
	}
	if command == "version" {
		fmt.Println("easyprivacy-node", version)
		return nil
	}
	flags := flag.NewFlagSet(command, flag.ContinueOnError)
	dir := flags.String("state-dir", node.DefaultStateDir, "absolute state directory (override only for isolated development)")
	var skipFirewall bool
	if command == "setup" {
		flags.BoolVar(&skipFirewall, "skip-firewall", false, "leave host firewall rules unchanged")
	}
	if err := flags.Parse(os.Args[2:]); err != nil {
		return err
	}
	if (command == "revoke" && flags.NArg() != 1) || (command != "revoke" && flags.NArg() != 0) {
		return errors.New("unexpected arguments")
	}
	switch command {
	case "setup":
		return setup(*dir, skipFirewall)
	case "firewall":
		return firewall(*dir)
	case "pair", "devices", "revoke":
		return administer(*dir, command, flags.Args())
	case "identity":
		state, err := node.Load(*dir)
		if err != nil {
			return err
		}
		printIdentity(state)
		return nil
	case "serve":
		state, err := node.Load(*dir)
		if err != nil {
			return err
		}
		ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		defer cancel()
		store, err := node.OpenDeviceStore(filepath.Join(*dir, "runtime"))
		if err != nil {
			return fmt.Errorf("open device records: %w", err)
		}
		server := node.NewServer(state, version)
		server.UseDeviceStore(store)
		if *dir == node.DefaultStateDir {
			server.UseVPN(vpn.Client{SocketPath: vpn.Socket, ConfigMarker: filepath.Join(node.DefaultStateDir, "vpn-enabled")})
		}
		fmt.Printf("EasyPrivacy core listening with TLS on %s\n", state.Listen)
		return server.ServeWithAdmin(ctx, adminSocket(*dir))
	default:
		return errors.New("use setup, serve, identity, firewall, pair, devices, revoke, or version")
	}
}

func setup(dir string, skipFirewall bool) error {
	if !term.IsTerminal(int(os.Stdin.Fd())) {
		return errors.New("setup needs an interactive terminal; passwords are never accepted on the command line")
	}
	if _, err := os.Lstat(node.StatePath(dir)); err == nil {
		return errors.New("this core is already configured; use 'easyprivacy-node identity' to display its fingerprint")
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	gid := -1
	installed := dir == node.DefaultStateDir
	if installed {
		if os.Geteuid() != 0 {
			return errors.New("run setup with sudo")
		}
		group, err := user.LookupGroup("easyprivacy-node")
		if err != nil {
			return errors.New("install the EasyPrivacy Ubuntu package before running setup")
		}
		gid, err = strconv.Atoi(group.Gid)
		if err != nil {
			return err
		}
	}
	fmt.Println("EasyPrivacy core setup\nCreate the login you will use in the desktop app.")
	reader := bufio.NewReader(os.Stdin)
	ask := func(prompt, fallback string) (string, error) {
		if fallback != "" {
			fmt.Printf("%s [%s]: ", prompt, fallback)
		} else {
			fmt.Printf("%s: ", prompt)
		}
		value, err := reader.ReadString('\n')
		if err != nil {
			return "", err
		}
		value = strings.TrimSpace(value)
		if value == "" {
			value = fallback
		}
		return value, nil
	}
	name, err := ask("Core name", "My EasyPrivacy Core")
	if err != nil {
		return err
	}
	var port int
	for {
		text, err := ask("Listening port", "7444")
		if err != nil {
			return err
		}
		port, err = strconv.Atoi(text)
		if err == nil && port >= 1024 && port <= 65535 {
			break
		}
		fmt.Println("Choose a port between 1024 and 65535.")
	}
	listener, err := net.Listen("tcp", net.JoinHostPort("", strconv.Itoa(port)))
	if err != nil {
		return fmt.Errorf("port %d is unavailable; rerun setup and choose another port: %w", port, err)
	}
	_ = listener.Close()
	var username string
	for {
		username, err = ask("Username", "")
		if err != nil {
			return err
		}
		if node.ValidUsername(username) {
			break
		}
		fmt.Println("Use letters, numbers, underscores or hyphens (1–64 characters).")
	}
	var password string
	for {
		fmt.Print("Password (at least 15 characters, hidden): ")
		value, err := term.ReadPassword(int(os.Stdin.Fd()))
		fmt.Println()
		if err != nil {
			return err
		}
		password = string(value)
		if err := node.ValidatePassword(password); err != nil {
			fmt.Println(err)
			continue
		}
		fmt.Print("Confirm password (hidden): ")
		confirmation, err := term.ReadPassword(int(os.Stdin.Fd()))
		fmt.Println()
		if err != nil {
			return err
		}
		if password == string(confirmation) {
			break
		}
		fmt.Println("Passwords did not match. Try again.")
	}
	state, err := node.NewState(name, port, username, password)
	password = ""
	if err != nil {
		return err
	}
	if err := node.SaveNew(dir, state, gid); err != nil {
		return err
	}
	if installed {
		cmd := exec.Command("systemctl", "enable", "--now", "easyprivacy-node.service")
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("setup is saved, but the service could not start; inspect 'journalctl -u easyprivacy-node': %w", err)
		}
		check := exec.Command("systemctl", "is-active", "--quiet", "easyprivacy-node.service")
		if err := check.Run(); err != nil {
			return errors.New("setup is saved, but the service is not active; inspect 'journalctl -u easyprivacy-node'")
		}
		if err := waitReady(state); err != nil {
			return err
		}
	}
	fmt.Println("\nCore configured.")
	printIdentity(state)
	if installed && !skipFirewall {
		if err := configureHostFirewall(state); err != nil {
			return fmt.Errorf("core setup is saved and the service is running, but firewall configuration failed; fix the reported issue and retry 'sudo easyprivacy-node firewall': %w", err)
		}
	} else {
		fmt.Printf("Host firewall configuration skipped. If needed, allow inbound TCP %d in your host firewall.\n", port)
	}
	fmt.Println("\nSetup complete.")
	printProviderReminder(port)
	if installed {
		if err := administer(dir, "pair", nil); err != nil {
			fmt.Println("Create a pairing code when ready with: sudo easyprivacy-node pair")
		}
	} else {
		fmt.Println("Start the core, then use 'easyprivacy-node pair --state-dir PATH' to create a pairing code.")
	}
	fmt.Println("Your password is not displayed or stored in plain text.")
	return nil
}

func adminSocket(dir string) string {
	if dir == node.DefaultStateDir {
		return "/run/easyprivacy-node/admin.sock"
	}
	return filepath.Join(dir, "runtime", "admin.sock")
}

func administer(dir, command string, args []string) error {
	if dir == node.DefaultStateDir && os.Geteuid() != 0 {
		return errors.New("run terminal administration with sudo")
	}
	method, path := "GET", "/devices"
	if command == "pair" {
		method, path = "POST", "/pairing-code"
	}
	if command == "revoke" {
		if len(args) != 1 || !vpn.ValidID(args[0]) {
			return errors.New("provide the full device ID from 'easyprivacy-node devices'")
		}
		method, path = "POST", "/devices/"+args[0]+"/revoke"
	}
	transport := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", adminSocket(dir))
	}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 5 * time.Second}
	request, err := http.NewRequest(method, "http://local"+path, nil)
	if err != nil {
		return err
	}
	response, err := client.Do(request)
	if err != nil {
		return fmt.Errorf("could not reach the core's local administration socket; check that the service is running: %w", err)
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(response.Body, 65537))
	if err != nil || len(raw) > 65536 {
		return errors.New("invalid local administration response")
	}
	if response.StatusCode != 200 {
		var value struct {
			Error string `json:"error"`
		}
		_ = json.Unmarshal(raw, &value)
		return fmt.Errorf("local administration failed: %s", value.Error)
	}
	if command == "pair" {
		var value node.PairingCode
		if err := json.Unmarshal(raw, &value); err != nil {
			return err
		}
		if len(value.Code) != 8 {
			return errors.New("invalid pairing code response")
		}
		fmt.Printf("Pairing code: %s %s\nExpires: %s\nEnter your core address and this code in the app. One device, five attempts maximum.\n", value.Code[:4], value.Code[4:], value.ExpiresAt.Local().Format(time.RFC1123))
	} else if command == "devices" {
		var value struct {
			Devices []node.Device `json:"devices"`
		}
		if err := json.Unmarshal(raw, &value); err != nil {
			return err
		}
		if len(value.Devices) == 0 {
			fmt.Println("No devices are paired yet.")
		}
		for _, d := range value.Devices {
			status := "authorized"
			if d.Revoked {
				status = "revoked"
			}
			fmt.Printf("%s  %s\n  %s\n", d.Name, status, d.ID)
		}
	} else {
		fmt.Println("Device revoked; its active sessions are invalidated.")
		var result struct {
			Warning string `json:"warning"`
		}
		if json.Unmarshal(raw, &result) == nil && result.Warning != "" {
			fmt.Println(result.Warning)
		}
	}
	return nil
}

func printIdentity(state *node.State) {
	fmt.Printf("Core: %s\nListening port: %s\nUsername: %s\nCore fingerprint: %s\n", state.Name, state.Listen, state.Username, state.Fingerprint())
}

func waitReady(state *node.State) error {
	cert, err := state.Certificate()
	if err != nil {
		return err
	}
	roots := x509.NewCertPool()
	roots.AddCert(cert.Leaf)
	transport := &http.Transport{TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS13, RootCAs: roots, ServerName: "core.easyprivacy.invalid"}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 500 * time.Millisecond, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	_, port, _ := net.SplitHostPort(state.Listen)
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		response, err := client.Get("https://127.0.0.1:" + port + "/healthz")
		if err == nil {
			response.Body.Close()
			if response.StatusCode == http.StatusOK {
				return nil
			}
		}
		time.Sleep(200 * time.Millisecond)
	}
	return errors.New("setup is saved, but the authenticated local TLS health check failed; inspect 'journalctl -u easyprivacy-node'")
}
