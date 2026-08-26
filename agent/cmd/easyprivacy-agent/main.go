package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/easyprivacy/easyprivacy/agent/internal/api"
	"github.com/easyprivacy/easyprivacy/agent/internal/device"
	"github.com/easyprivacy/easyprivacy/agent/internal/system"
)

const version = "0.1.0"

func main() {
	if err := run(os.Args[1:]); err != nil {
		slog.Error("agent stopped", "error", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 {
		return errors.New("usage: easyprivacy-agent <init|device|serve|version>")
	}
	switch args[0] {
	case "init":
		return initialize(args[1:])
	case "device":
		return runDeviceCommand(args[1:])
	case "serve":
		return serve(args[1:])
	case "version", "--version", "-version":
		fmt.Printf("easyprivacy-agent %s\n", version)
		return nil
	default:
		return fmt.Errorf("unknown command %q; expected init, device, serve, or version", args[0])
	}
}

func initialize(args []string) error {
	flags := flag.NewFlagSet("init", flag.ContinueOnError)
	stateDir := flags.String("state-dir", defaultStateDir(), "directory for agent-owned state")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if err := os.MkdirAll(*stateDir, 0o700); err != nil {
		return fmt.Errorf("create state directory: %w", err)
	}
	if err := os.Chmod(*stateDir, 0o700); err != nil {
		return fmt.Errorf("secure state directory: %w", err)
	}

	tokenPath := filepath.Join(*stateDir, "agent.token")
	file, err := os.OpenFile(tokenPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if errors.Is(err, os.ErrExist) {
		return fmt.Errorf("agent is already initialized at %s", *stateDir)
	}
	if err != nil {
		return fmt.Errorf("create shared development token: %w", err)
	}

	token, err := randomToken()
	if err != nil {
		_ = file.Close()
		_ = os.Remove(tokenPath)
		return err
	}
	if _, err := fmt.Fprintln(file, token); err != nil {
		_ = file.Close()
		_ = os.Remove(tokenPath)
		return fmt.Errorf("write shared development token: %w", err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("close shared development token: %w", err)
	}

	fmt.Println("EasyPrivacy agent initialized.")
	fmt.Println("Shared development token (compatibility only):")
	fmt.Println(token)
	fmt.Println("The token is stored with owner-only permissions and is not logged again.")
	fmt.Println("Use 'easyprivacy-agent device enroll' for a distinct revocable device credential.")
	fmt.Println("This shared token is not finished per-device authentication.")
	return nil
}

func runDeviceCommand(args []string) error {
	if len(args) == 0 {
		return errors.New("usage: easyprivacy-agent device <enroll|list|revoke>")
	}
	switch args[0] {
	case "enroll":
		return enrollDevice(args[1:])
	case "list":
		return listDevices(args[1:])
	case "revoke":
		return revokeDevice(args[1:])
	default:
		return fmt.Errorf("unknown device command %q; expected enroll, list, or revoke", args[0])
	}
}

func enrollDevice(args []string) error {
	flags := flag.NewFlagSet("device enroll", flag.ContinueOnError)
	stateDir := flags.String("state-dir", defaultStateDir(), "directory for agent-owned state")
	name := flags.String("name", "", "owner-visible name for this app installation")
	if err := flags.Parse(args); err != nil {
		return err
	}
	store, err := device.Open(*stateDir)
	if err != nil {
		return err
	}
	credential, err := store.Enroll(*name)
	if err != nil {
		return err
	}
	fmt.Println("EasyPrivacy trusted device enrolled.")
	fmt.Printf("Device ID: %s\n", credential.Device.ID)
	fmt.Printf("Device name: %s\n", credential.Device.Name)
	fmt.Println("Device credential (shown once):")
	fmt.Println(credential.Token)
	fmt.Println("The server stored only a credential digest. Transfer this value only through the verified SSH session.")
	return nil
}

func listDevices(args []string) error {
	flags := flag.NewFlagSet("device list", flag.ContinueOnError)
	stateDir := flags.String("state-dir", defaultStateDir(), "directory for agent-owned state")
	if err := flags.Parse(args); err != nil {
		return err
	}
	store, err := device.Open(*stateDir)
	if err != nil {
		return err
	}
	records, err := store.List()
	if err != nil {
		return err
	}
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	return encoder.Encode(records)
}

func revokeDevice(args []string) error {
	flags := flag.NewFlagSet("device revoke", flag.ContinueOnError)
	stateDir := flags.String("state-dir", defaultStateDir(), "directory for agent-owned state")
	id := flags.String("id", "", "device identifier to revoke")
	if err := flags.Parse(args); err != nil {
		return err
	}
	store, err := device.Open(*stateDir)
	if err != nil {
		return err
	}
	if err := store.Revoke(*id); err != nil {
		if errors.Is(err, device.ErrDeviceNotFound) {
			return fmt.Errorf("device %q is not active", *id)
		}
		return err
	}
	fmt.Printf("Revoked EasyPrivacy device %s.\n", *id)
	return nil
}

func serve(args []string) error {
	flags := flag.NewFlagSet("serve", flag.ContinueOnError)
	listenAddress := flags.String("listen", "127.0.0.1:7443", "address for the management API")
	stateDir := flags.String("state-dir", defaultStateDir(), "directory containing agent state")
	tlsCert := flags.String("tls-cert", "", "PEM certificate for HTTPS")
	tlsKey := flags.String("tls-key", "", "PEM private key for HTTPS")
	storageRoot := flags.String("storage-root", string(filepath.Separator), "filesystem to report")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if (*tlsCert == "") != (*tlsKey == "") {
		return errors.New("--tls-cert and --tls-key must be provided together")
	}
	if *tlsCert == "" && !isLoopbackListenAddress(*listenAddress) {
		return errors.New("refusing non-loopback HTTP; configure TLS or bind to localhost")
	}

	tokenBytes, err := os.ReadFile(filepath.Join(*stateDir, "agent.token"))
	if err != nil {
		return fmt.Errorf("read agent token (run init first): %w", err)
	}
	token := strings.TrimSpace(string(tokenBytes))
	if token == "" {
		return errors.New("agent token is empty")
	}
	deviceStore, err := device.Open(*stateDir)
	if err != nil {
		return fmt.Errorf("open device credential store: %w", err)
	}

	collector := system.NewCollector(version, *storageRoot)
	handler := api.NewHandler(
		api.NewAnyAuthenticator(api.NewStaticAuthenticator(token), deviceStore),
		collector,
	)
	server := &http.Server{
		Addr:              *listenAddress,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	serveErrors := make(chan error, 1)
	go func() {
		slog.Info("EasyPrivacy agent listening", "address", *listenAddress, "tls", *tlsCert != "")
		if *tlsCert != "" {
			serveErrors <- server.ListenAndServeTLS(*tlsCert, *tlsKey)
			return
		}
		serveErrors <- server.ListenAndServe()
	}()

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(signals)

	select {
	case err := <-serveErrors:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-signals:
		shutdownContext, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		return server.Shutdown(shutdownContext)
	}
}

func randomToken() (string, error) {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", fmt.Errorf("generate shared development token: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(raw), nil
}

func isLoopbackListenAddress(address string) bool {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return false
	}
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func defaultStateDir() string {
	if override := os.Getenv("EASYPRIVACY_STATE_DIR"); override != "" {
		return override
	}
	return "/var/lib/easyprivacy"
}
