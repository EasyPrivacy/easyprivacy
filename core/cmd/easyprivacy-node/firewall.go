package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/easyprivacy/easyprivacy/core/internal/node"
)

// Existing installations can configure their saved port without recreating
// credentials or the core identity. Development state never changes a firewall.
func firewall(dir string) error {
	if dir != node.DefaultStateDir {
		return errors.New("firewall configuration is only available for the installed core; omit --state-dir")
	}
	if os.Geteuid() != 0 {
		return errors.New("run firewall configuration with sudo")
	}
	state, err := node.Load(dir)
	if err != nil {
		return err
	}
	if err := configureHostFirewall(state); err != nil {
		return err
	}
	_, textPort, _ := net.SplitHostPort(state.Listen)
	port, _ := strconv.Atoi(textPort)
	printProviderReminder(port)
	return nil
}

func configureHostFirewall(state *node.State) error {
	_, textPort, err := net.SplitHostPort(state.Listen)
	if err != nil {
		return err
	}
	port, err := strconv.Atoi(textPort)
	if err != nil {
		return err
	}
	path, err := exec.LookPath("ufw")
	if err != nil && !errors.Is(err, exec.ErrNotFound) {
		return fmt.Errorf("find UFW: %w", err)
	}
	run := func(args ...string) ([]byte, error) {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, path, args...)
		// UFW's status text is translated unless the locale is fixed.
		cmd.Env = append(os.Environ(), "LC_ALL=C")
		return cmd.CombinedOutput()
	}
	return configureUFW(port, err == nil, run, os.Stdout)
}

func configureUFW(port int, available bool, run func(...string) ([]byte, error), out io.Writer) error {
	if port < 1024 || port > 65535 {
		return errors.New("invalid core port; firewall was not changed")
	}
	if !available {
		fmt.Fprintf(out, "UFW is not installed. If another host firewall is in use, allow inbound TCP %d there.\n", port)
		return nil
	}
	status, err := run("status")
	if err != nil {
		return fmt.Errorf("could not check UFW; inspect 'sudo ufw status verbose': %w: %s", err, strings.TrimSpace(string(status)))
	}
	firstLine, _, _ := strings.Cut(strings.TrimSpace(string(status)), "\n")
	switch strings.TrimSpace(firstLine) {
	case "Status: inactive":
		fmt.Fprintf(out, "UFW is inactive; left unchanged. If another host firewall is in use, allow inbound TCP %d there.\n", port)
		return nil
	case "Status: active":
		fmt.Fprintf(out, "UFW is active. Allowing inbound TCP %d for the core...\n", port)
	default:
		return errors.New("could not determine UFW status; firewall was not changed; inspect 'sudo ufw status verbose'")
	}
	result, err := run("allow", strconv.Itoa(port)+"/tcp")
	if err != nil {
		return fmt.Errorf("could not allow TCP %d in UFW; try 'sudo ufw allow %d/tcp': %w: %s", port, port, err, strings.TrimSpace(string(result)))
	}
	fmt.Fprintf(out, "UFW allow rule applied for TCP %d.\n", port)
	return nil
}

func printProviderReminder(port int) {
	fmt.Printf("If your VPS has a provider firewall, allow inbound TCP %d there too.\n", port)
}
