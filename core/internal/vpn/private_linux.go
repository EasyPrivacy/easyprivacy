package vpn

import (
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"strings"
	"time"
)

const privateChain = "EP_PRIVATE_V1"
const privateTag = "easyprivacy-private-v1"

func preparePrivateChain() error {
	raw, err := command("iptables", "", "-w", "3", "-t", "filter", "-S", privateChain)
	if err != nil {
		if _, err = command("iptables", "", "-w", "3", "-t", "filter", "-N", privateChain); err != nil {
			return err
		}
	} else {
		for _, line := range strings.Split(string(raw), "\n") {
			if strings.HasPrefix(line, "-A ") && !strings.Contains(line, "--comment "+privateTag) && !strings.Contains(line, "--comment \""+privateTag+"\"") {
				return errors.New("private access chain belongs to another configuration")
			}
		}
	}
	return (&Linux{}).SetPrivateAccess(nil)
}

func (l *Linux) SetPrivateAccess(grants []PrivateGrant) error {
	if len(grants) > 2048 {
		return errors.New("too many private access grants")
	}
	var text strings.Builder
	fmt.Fprintf(&text, "*filter\n-F %s\n", privateChain)
	for _, grant := range grants {
		source, e1 := netip.ParsePrefix(grant.Source)
		target, e2 := netip.ParsePrefix(grant.Destination)
		if e1 != nil || e2 != nil || source.Bits() != 32 || target.Bits() != 32 || !source.Addr().Is4() || !target.Addr().Is4() || !source.Addr().IsPrivate() || !target.Addr().IsPrivate() || source == target || grant.Port != FilesReceiverPort {
			return errors.New("invalid private receiver access")
		}
		fmt.Fprintf(&text, "-A %s -i %s -o %s -s %s -d %s -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -m comment --comment %s -j ACCEPT\n", privateChain, Interface, Interface, grant.Source, grant.Destination, grant.Port, privateTag)
		fmt.Fprintf(&text, "-A %s -i %s -o %s -s %s -d %s -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -m comment --comment %s -j ACCEPT\n", privateChain, Interface, Interface, grant.Destination, grant.Source, grant.Port, privateTag)
	}
	fmt.Fprintf(&text, "-A %s -m comment --comment %s -j DROP\nCOMMIT\n", privateChain, privateTag)
	_, err := command("iptables-restore", text.String(), "--noflush", "--wait", "3")
	return err
}

func cleanupPrivateChain() error {
	raw, err := command("iptables", "", "-w", "3", "-t", "filter", "-S", privateChain)
	if err != nil {
		return nil
	}
	for _, line := range strings.Split(string(raw), "\n") {
		if strings.HasPrefix(line, "-A ") && !strings.Contains(line, privateTag) {
			return errors.New("refusing to remove an unowned private access rule")
		}
	}
	if _, err = command("iptables", "", "-w", "3", "-t", "filter", "-F", privateChain); err != nil {
		return err
	}
	_, err = command("iptables", "", "-w", "3", "-t", "filter", "-X", privateChain)
	return err
}

func (l *Linux) startPrivateProbe(c Config) error {
	address := net.JoinHostPort(strings.TrimSuffix(c.Address(1), "/32"), fmt.Sprint(PrivateProbePort))
	listener, err := net.Listen("tcp4", address)
	if err != nil {
		return errors.New("cannot start the private network diagnostic listener")
	}
	l.probe = listener
	go func() {
		slots := make(chan struct{}, 16)
		for {
			stream, err := listener.Accept()
			if err != nil {
				return
			}
			select {
			case slots <- struct{}{}:
				go func() {
					defer func() { <-slots; stream.Close() }()
					_ = stream.SetDeadline(time.Now().Add(5 * time.Second))
					var nonce [32]byte
					if _, err := io.ReadFull(stream, nonce[:]); err == nil {
						_, _ = stream.Write(nonce[:])
					}
				}()
			default:
				stream.Close()
			}
		}
	}()
	return nil
}
