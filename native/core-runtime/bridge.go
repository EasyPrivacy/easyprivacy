package coreruntime

import (
	"bufio"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/netip"
	"strings"
	"sync"
	"time"
)

// Bridge carries file bytes on pinned local TLS sockets. The control process
// alone can mint single-use tickets; remote enrollment credentials never enter
// this process. Neither JSON RPC nor Android Binder carries the payload.
type Bridge struct {
	mu        sync.Mutex
	transport *Transport
	listener  net.Listener
	tlsConfig *tls.Config
	pin       string
	tickets   map[[32]byte]*streamTicket
	active    map[net.Conn]streamOwner
	receivers map[string]*receiver
	epochs    map[string]uint64
	done      chan struct{}
	closed    bool
}
type streamTicket struct {
	capability, service string
	receiver            string
	target              netip.AddrPort
	incoming            net.Conn
	expires             time.Time
	epoch               uint64
}
type streamOwner struct{ capability, receiver string }
type receiver struct {
	listener net.Listener
	pending  chan net.Conn
	done     chan struct{}
}

func NewBridge(transport *Transport) (*Bridge, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, err
	}
	template := &x509.Certificate{SerialNumber: serial, NotBefore: time.Now().Add(-5 * time.Minute), NotAfter: time.Now().Add(365 * 24 * time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, IPAddresses: []net.IP{net.ParseIP("127.0.0.1")}}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return nil, err
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	digest := sha256.Sum256(der)
	bridge := &Bridge{transport: transport, listener: listener, pin: fmt.Sprintf("SHA256:%X", digest), tickets: map[[32]byte]*streamTicket{}, active: map[net.Conn]streamOwner{}, receivers: map[string]*receiver{}, epochs: map[string]uint64{}, done: make(chan struct{}), tlsConfig: &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}}}}
	go bridge.serve()
	go func() {
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-bridge.done:
				return
			case <-ticker.C:
				bridge.mu.Lock()
				bridge.expireLocked()
				bridge.mu.Unlock()
			}
		}
	}()
	return bridge, nil
}

func (b *Bridge) expireLocked() {
	for key, ticket := range b.tickets {
		if !time.Now().Before(ticket.expires) {
			if ticket.incoming != nil {
				ticket.incoming.Close()
				delete(b.active, ticket.incoming)
			}
			delete(b.tickets, key)
		}
	}
}

func (b *Bridge) issueLocked(ticket *streamTicket) (map[string]any, error) {
	b.expireLocked()
	if b.closed || len(b.tickets) >= 32 {
		return nil, errors.New("private stream tickets unavailable")
	}
	if ticket.capability != "core" && ticket.capability != "files" {
		return nil, errors.New("invalid capability")
	}
	token := make([]byte, 32)
	if _, err := rand.Read(token); err != nil {
		return nil, err
	}
	encoded := hex.EncodeToString(token)
	ticket.expires = time.Now().Add(30 * time.Second)
	ticket.epoch = b.epochs[ticket.capability]
	b.tickets[sha256.Sum256([]byte(encoded))] = ticket
	return map[string]any{"protocol": 1, "port": b.listener.Addr().(*net.TCPAddr).Port, "pin": b.pin, "ticket": encoded, "expires_at": ticket.expires.UTC()}, nil
}

func (b *Bridge) Issue(capability, service string, target netip.AddrPort) (map[string]any, error) {
	id, receiverService := strings.CutPrefix(service, "receiver.")
	decoded, decodeErr := hex.DecodeString(id)
	if (service == "core.probe" && target.Port() != 41930) ||
		(service != "core.probe" && (!receiverService || decodeErr != nil || len(decoded) != 16 || target.Port() != 41931)) {
		return nil, errors.New("invalid service")
	}
	if err := b.transport.Grant(service, target); err != nil {
		return nil, err
	}
	b.transport.RevokeGrant(service)
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.issueLocked(&streamTicket{capability: capability, service: service, target: target})
}

func (b *Bridge) serve() {
	slots := make(chan struct{}, 32)
	for {
		stream, err := b.listener.Accept()
		if err != nil {
			return
		}
		select {
		case slots <- struct{}{}:
			go func() { defer func() { <-slots }(); b.relay(stream) }()
		default:
			stream.Close()
		}
	}
}

func (b *Bridge) relay(raw net.Conn) {
	local := tls.Server(raw, b.tlsConfig)
	defer local.Close()
	_ = local.SetDeadline(time.Now().Add(5 * time.Second))
	if err := local.Handshake(); err != nil {
		return
	}
	reader := bufio.NewReaderSize(local, 2048)
	line, err := reader.ReadSlice('\n')
	if err != nil || len(line) > 1024 {
		return
	}
	var request struct {
		Protocol int    `json:"protocol"`
		Ticket   string `json:"ticket"`
	}
	if json.Unmarshal(line, &request) != nil || request.Protocol != 1 || len(request.Ticket) != 64 {
		return
	}
	b.mu.Lock()
	key := sha256.Sum256([]byte(request.Ticket))
	ticket := b.tickets[key]
	delete(b.tickets, key)
	valid := ticket != nil && !b.closed && time.Now().Before(ticket.expires) && ticket.epoch == b.epochs[ticket.capability]
	if valid {
		b.active[local] = streamOwner{ticket.capability, ticket.receiver}
	} else if ticket != nil && ticket.incoming != nil {
		ticket.incoming.Close()
		delete(b.active, ticket.incoming)
	}
	b.mu.Unlock()
	if !valid {
		_, _ = local.Write([]byte{1})
		return
	}
	defer func() { b.mu.Lock(); delete(b.active, local); b.mu.Unlock() }()
	_ = local.SetDeadline(time.Now().Add(15 * time.Second))
	remote := ticket.incoming
	if remote == nil {
		id := request.Ticket
		if err = b.transport.Grant(id, ticket.target); err != nil {
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		remote, err = b.transport.Open(ctx, id)
		cancel()
		b.transport.RevokeGrant(id)
		if err != nil {
			_, _ = local.Write([]byte{1})
			return
		}
		if strings.HasPrefix(ticket.service, "receiver.") {
			_ = remote.SetWriteDeadline(time.Now().Add(5 * time.Second))
			_, err = io.WriteString(remote, "EPPR1"+strings.TrimPrefix(ticket.service, "receiver."))
			if err != nil {
				remote.Close()
				return
			}
			_ = remote.SetWriteDeadline(time.Time{})
		}
	}
	defer remote.Close()
	b.mu.Lock()
	valid = !b.closed && ticket.epoch == b.epochs[ticket.capability]
	if valid {
		b.active[remote] = streamOwner{ticket.capability, ticket.receiver}
	}
	b.mu.Unlock()
	if !valid {
		return
	}
	defer func() { b.mu.Lock(); delete(b.active, remote); b.mu.Unlock() }()
	_ = local.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err = local.Write([]byte{0}); err != nil {
		return
	}
	_ = local.SetDeadline(time.Time{})
	done := make(chan struct{}, 2)
	go func() { _, _ = io.CopyBuffer(remote, reader, make([]byte, 32*1024)); done <- struct{}{} }()
	go func() { _, _ = io.CopyBuffer(local, remote, make([]byte, 32*1024)); done <- struct{}{} }()
	<-done
	local.Close()
	remote.Close()
	<-done
}

func (b *Bridge) RegisterReceiver(id string) error {
	if decoded, err := hex.DecodeString(id); err != nil || len(decoded) != 16 {
		return errors.New("invalid receiver")
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return net.ErrClosed
	}
	if b.receivers[id] != nil {
		return nil
	}
	if len(b.receivers) != 0 {
		return errors.New("only one Files receiver is supported")
	}
	listener, err := b.transport.Listen(41931)
	if err != nil {
		return err
	}
	r := &receiver{listener: listener, pending: make(chan net.Conn, 4), done: make(chan struct{})}
	b.receivers[id] = r
	go func() {
		for {
			stream, err := listener.Accept()
			if err != nil {
				return
			}
			b.mu.Lock()
			b.active[stream] = streamOwner{"files", id}
			b.mu.Unlock()
			_ = stream.SetReadDeadline(time.Now().Add(5 * time.Second))
			var header [37]byte
			_, err = io.ReadFull(stream, header[:])
			_ = stream.SetReadDeadline(time.Time{})
			b.mu.Lock()
			if err != nil || string(header[:]) != "EPPR1"+id || b.closed || b.receivers[id] != r {
				stream.Close()
				delete(b.active, stream)
				b.mu.Unlock()
				continue
			}
			select {
			case r.pending <- stream:
			default:
				stream.Close()
				delete(b.active, stream)
			}
			b.mu.Unlock()
		}
	}()
	return nil
}

func (b *Bridge) AcceptReceiver(ctx context.Context, id string) (map[string]any, error) {
	b.mu.Lock()
	r := b.receivers[id]
	epoch := b.epochs["files"]
	b.mu.Unlock()
	if r == nil {
		return nil, errors.New("receiver is not registered")
	}
	select {
	case stream := <-r.pending:
		b.mu.Lock()
		defer b.mu.Unlock()
		if b.closed || b.epochs["files"] != epoch || b.receivers[id] != r {
			stream.Close()
			delete(b.active, stream)
			return nil, net.ErrClosed
		}
		ticket, err := b.issueLocked(&streamTicket{capability: "files", incoming: stream, receiver: id})
		if err != nil {
			stream.Close()
			delete(b.active, stream)
			return nil, err
		}
		ticket["peer_address"] = stream.RemoteAddr().String()
		return ticket, nil
	case <-r.done:
		return nil, net.ErrClosed
	case <-ctx.Done():
		return map[string]any{"waiting": true}, nil
	}
}

func (b *Bridge) closeReceiverLocked(id string) {
	r := b.receivers[id]
	if r == nil {
		return
	}
	delete(b.receivers, id)
	for stream, owner := range b.active {
		if owner.receiver == id {
			stream.Close()
			delete(b.active, stream)
		}
	}
	for key, ticket := range b.tickets {
		if ticket.receiver == id {
			if ticket.incoming != nil {
				ticket.incoming.Close()
			}
			delete(b.tickets, key)
		}
	}
	close(r.done)
	r.listener.Close()
	for {
		select {
		case stream := <-r.pending:
			stream.Close()
			delete(b.active, stream)
		default:
			return
		}
	}
}
func (b *Bridge) CloseReceiver(id string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.closeReceiverLocked(id)
}

func (b *Bridge) Revoke(capability string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.epochs[capability]++
	for key, ticket := range b.tickets {
		if ticket.capability == capability {
			if ticket.incoming != nil {
				ticket.incoming.Close()
				delete(b.active, ticket.incoming)
			}
			delete(b.tickets, key)
		}
	}
	for stream, owner := range b.active {
		if owner.capability == capability {
			stream.Close()
			delete(b.active, stream)
		}
	}
	if capability == "files" {
		for id := range b.receivers {
			b.closeReceiverLocked(id)
		}
	}
}

func (b *Bridge) Close() error {
	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		return nil
	}
	b.closed = true
	close(b.done)
	b.listener.Close()
	for id := range b.receivers {
		b.closeReceiverLocked(id)
	}
	for stream := range b.active {
		stream.Close()
	}
	for _, ticket := range b.tickets {
		if ticket.incoming != nil {
			ticket.incoming.Close()
		}
	}
	b.mu.Unlock()
	return b.transport.Close()
}
