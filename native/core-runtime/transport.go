// Package coreruntime provides private service connections without an OS VPN.
// Only Core hosts this engine. Capability apps receive authorized streams.
package coreruntime

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"sync"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

type Config struct {
	PrivateKey    string
	Address       netip.Addr
	PeerPublicKey string
	Endpoint      string
	AllowedPrefix netip.Prefix
	Services      map[string]netip.AddrPort
}

type Transport struct {
	mu        sync.Mutex
	wireguard *device.Device
	network   *netstack.Net
	services  map[string]netip.AddrPort
	closed    bool
	streams   map[net.Conn]struct{}
	listeners map[*trackedListener]struct{}
	pending   int
	prefix    netip.Prefix
	address   netip.Addr
}

func key(value string) (string, error) {
	bytes, err := base64.StdEncoding.DecodeString(value)
	if err != nil || len(bytes) != 32 {
		return "", errors.New("invalid transport key")
	}
	var nonzero byte
	for _, b := range bytes {
		nonzero |= b
	}
	if nonzero == 0 || base64.StdEncoding.EncodeToString(bytes) != value {
		return "", errors.New("invalid transport key")
	}
	return hex.EncodeToString(bytes), nil
}

func New(config Config) (*Transport, error) {
	private, err := key(config.PrivateKey)
	if err != nil {
		return nil, err
	}
	public, err := key(config.PeerPublicKey)
	if err != nil {
		return nil, err
	}
	privateNetwork := false
	for _, network := range []string{"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"} {
		prefix := netip.MustParsePrefix(network)
		if config.AllowedPrefix.IsValid() && config.AllowedPrefix == config.AllowedPrefix.Masked() && prefix.Contains(config.AllowedPrefix.Addr()) && config.AllowedPrefix.Bits() >= prefix.Bits() {
			privateNetwork = true
		}
	}
	if !config.Address.IsPrivate() || !config.Address.Is4() || !privateNetwork ||
		!config.AllowedPrefix.Contains(config.Address) {
		return nil, errors.New("a private IPv4 service network is required")
	}
	if config.Endpoint != "" {
		endpoint, e := netip.ParseAddrPort(config.Endpoint)
		if e != nil || endpoint.Port() == 0 {
			return nil, errors.New("use a resolved IP endpoint and port")
		}
	}
	services := make(map[string]netip.AddrPort, len(config.Services))
	for id, target := range config.Services {
		if id == "" || len(id) > 120 || !target.IsValid() || !target.Addr().IsPrivate() || target.Port() == 0 ||
			!config.AllowedPrefix.Contains(target.Addr()) || target.Addr() == config.Address {
			return nil, errors.New("service destination is outside the private network")
		}
		services[id] = target
	}
	tun, network, err := netstack.CreateNetTUN([]netip.Addr{config.Address}, nil, 1280)
	if err != nil {
		return nil, err
	}
	wg := device.NewDevice(tun, conn.NewDefaultBind(), device.NewLogger(device.LogLevelSilent, ""))
	text := "private_key=" + private + "\nlisten_port=0\npublic_key=" + public + "\nallowed_ip=" + config.AllowedPrefix.String() + "\npersistent_keepalive_interval=25\n"
	if config.Endpoint != "" {
		text += "endpoint=" + config.Endpoint + "\n"
	}
	if err = wg.IpcSet(text); err == nil {
		err = wg.Up()
	}
	if err != nil {
		wg.Close()
		return nil, err
	}
	return &Transport{wireguard: wg, network: network, services: services, streams: map[net.Conn]struct{}{}, listeners: map[*trackedListener]struct{}{}, prefix: config.AllowedPrefix, address: config.Address}, nil
}

func (t *Transport) Grant(id string, target netip.AddrPort) error {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.closed {
		return net.ErrClosed
	}
	_, exists := t.services[id]
	if id == "" || len(id) > 120 || !target.IsValid() || target.Port() == 0 || !target.Addr().Is4() || !t.prefix.Contains(target.Addr()) || target.Addr() == t.address || (!exists && len(t.services) >= 64) {
		return errors.New("invalid service grant")
	}
	// The netstack itself can only send through the configured WireGuard peer.
	t.services[id] = target
	return nil
}

func (t *Transport) RevokeGrant(id string) { t.mu.Lock(); delete(t.services, id); t.mu.Unlock() }

// Port is the outer UDP endpoint. It is not an OS tunnel or a service listener.
func (t *Transport) Port() (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.closed {
		return 0, net.ErrClosed
	}
	state, err := t.wireguard.IpcGet()
	if err != nil {
		return 0, err
	}
	for line := range strings.SplitSeq(state, "\n") {
		if value, found := strings.CutPrefix(line, "listen_port="); found {
			return strconv.Atoi(value)
		}
	}
	return 0, errors.New("transport has no UDP endpoint")
}

func (t *Transport) Open(ctx context.Context, serviceID string) (net.Conn, error) {
	t.mu.Lock()
	target, allowed := t.services[serviceID]
	closed := t.closed
	if !closed && allowed {
		if len(t.streams)+t.pending >= 16 {
			t.mu.Unlock()
			return nil, errors.New("private stream limit reached")
		}
		t.pending++
	}
	t.mu.Unlock()
	if closed {
		return nil, net.ErrClosed
	}
	if !allowed {
		return nil, errors.New("service access is not granted")
	}
	stream, err := t.network.DialContext(ctx, "tcp", target.String())
	t.mu.Lock()
	t.pending--
	defer t.mu.Unlock()
	if err != nil {
		return nil, err
	}
	if t.closed {
		stream.Close()
		return nil, net.ErrClosed
	}
	wrapped := &trackedConn{Conn: stream, owner: t}
	t.streams[wrapped] = struct{}{}
	return wrapped, nil
}

// Listen accepts an authorized receiver inside the private network only.
// The platform broker must authorize the receiver before calling this method.
func (t *Transport) Listen(port uint16) (net.Listener, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.closed {
		return nil, net.ErrClosed
	}
	if port == 0 {
		return nil, errors.New("a fixed receiver port is required")
	}
	if len(t.listeners) >= 4 {
		return nil, errors.New("private receiver limit reached")
	}
	listener, err := t.network.ListenTCP(&net.TCPAddr{Port: int(port)})
	if err != nil {
		return nil, err
	}
	wrapped := &trackedListener{Listener: listener, owner: t}
	t.listeners[wrapped] = struct{}{}
	return wrapped, nil
}

func (t *Transport) Close() error {
	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		return nil
	}
	t.closed = true
	streams := make([]net.Conn, 0, len(t.streams))
	for stream := range t.streams {
		streams = append(streams, stream)
	}
	listeners := make([]*trackedListener, 0, len(t.listeners))
	for listener := range t.listeners {
		listeners = append(listeners, listener)
	}
	t.mu.Unlock()
	for _, listener := range listeners {
		listener.Close()
	}
	for _, stream := range streams {
		stream.Close()
	}
	t.wireguard.Close()
	return nil
}

type trackedListener struct {
	net.Listener
	owner *Transport
	once  sync.Once
}

func (l *trackedListener) Accept() (net.Conn, error) {
	stream, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	l.owner.mu.Lock()
	defer l.owner.mu.Unlock()
	if l.owner.closed || len(l.owner.streams)+l.owner.pending >= 16 {
		stream.Close()
		return nil, net.ErrClosed
	}
	wrapped := &trackedConn{Conn: stream, owner: l.owner}
	l.owner.streams[wrapped] = struct{}{}
	return wrapped, nil
}
func (l *trackedListener) Close() error {
	var err error
	l.once.Do(func() { err = l.Listener.Close(); l.owner.mu.Lock(); delete(l.owner.listeners, l); l.owner.mu.Unlock() })
	return err
}

type trackedConn struct {
	net.Conn
	owner *Transport
	once  sync.Once
}

func (c *trackedConn) Close() error {
	var err error
	c.once.Do(func() {
		err = c.Conn.Close()
		c.owner.mu.Lock()
		delete(c.owner.streams, c)
		c.owner.mu.Unlock()
	})
	return err
}
