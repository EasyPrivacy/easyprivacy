package coreruntime

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/netip"
	"strings"
	"testing"
	"time"
)

func localStream(t *testing.T, ticket map[string]any, wantAck byte) net.Conn {
	t.Helper()
	config := &tls.Config{MinVersion: tls.VersionTLS13, InsecureSkipVerify: true, VerifyConnection: func(state tls.ConnectionState) error {
		if len(state.PeerCertificates) != 1 || fmt.Sprintf("SHA256:%X", sha256.Sum256(state.PeerCertificates[0].Raw)) != ticket["pin"] {
			return fmt.Errorf("certificate pin mismatch")
		}
		return nil
	}}
	conn, err := tls.Dial("tcp4", fmt.Sprintf("127.0.0.1:%v", ticket["port"]), config)
	if err != nil {
		t.Fatal(err)
	}
	conn.SetDeadline(time.Now().Add(15 * time.Second))
	if err = json.NewEncoder(conn).Encode(map[string]any{"protocol": 1, "ticket": ticket["ticket"]}); err != nil {
		conn.Close()
		t.Fatal(err)
	}
	var ack [1]byte
	if _, err = io.ReadFull(conn, ack[:]); err != nil {
		conn.Close()
		t.Fatal(err)
	}
	if ack[0] != wantAck {
		conn.Close()
		t.Fatalf("ack = %d, want %d", ack[0], wantAck)
	}
	return conn
}

func TestBridgeTransferTicketsAndRevocation(t *testing.T) {
	a, ap := testKey(t)
	b, bp := testKey(t)
	prefix := netip.MustParsePrefix("10.87.0.0/24")
	receiverTransport, err := New(Config{PrivateKey: b, PeerPublicKey: ap, Address: netip.MustParseAddr("10.87.0.3"), AllowedPrefix: prefix})
	if err != nil {
		t.Fatal(err)
	}
	defer receiverTransport.Close()
	port, err := receiverTransport.Port()
	if err != nil {
		t.Fatal(err)
	}
	senderTransport, err := New(Config{PrivateKey: a, PeerPublicKey: bp, Endpoint: fmt.Sprintf("127.0.0.1:%d", port), Address: netip.MustParseAddr("10.87.0.2"), AllowedPrefix: prefix})
	if err != nil {
		t.Fatal(err)
	}
	defer senderTransport.Close()
	receiver, err := NewBridge(receiverTransport)
	if err != nil {
		t.Fatal(err)
	}
	defer receiver.Close()
	sender, err := NewBridge(senderTransport)
	if err != nil {
		t.Fatal(err)
	}
	defer sender.Close()
	id := strings.Repeat("a", 32)
	if err = receiver.RegisterReceiver(id); err != nil {
		t.Fatal(err)
	}
	ticket, err := sender.Issue("files", "receiver."+id, netip.MustParseAddrPort("10.87.0.3:41931"))
	if err != nil {
		t.Fatal(err)
	}
	outgoing := localStream(t, ticket, 0)
	defer outgoing.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	incomingTicket, err := receiver.AcceptReceiver(ctx, id)
	if err != nil || incomingTicket["waiting"] == true {
		t.Fatalf("incoming stream: %v, %v", incomingTicket, err)
	}
	incoming := localStream(t, incomingTicket, 0)
	defer incoming.Close()
	payload := bytes.Repeat([]byte("private file payload"), 200*1024)
	expected := sha256.Sum256(payload)
	done := make(chan error, 1)
	go func() {
		hash := sha256.New()
		_, copyErr := io.CopyN(hash, incoming, int64(len(payload)))
		if copyErr == nil && !bytes.Equal(hash.Sum(nil), expected[:]) {
			copyErr = fmt.Errorf("payload integrity failed")
		}
		if copyErr == nil {
			_, copyErr = incoming.Write(hash.Sum(nil))
		}
		done <- copyErr
	}()
	if _, err = io.Copy(outgoing, bytes.NewReader(payload)); err != nil {
		t.Fatal(err)
	}
	var receipt [32]byte
	if _, err = io.ReadFull(outgoing, receipt[:]); err != nil {
		t.Fatal(err)
	}
	if receipt != expected {
		t.Fatal("receipt integrity failed")
	}
	if err = <-done; err != nil {
		t.Fatal(err)
	}
	localStream(t, ticket, 1).Close()
	pending, err := sender.Issue("files", "receiver."+id, netip.MustParseAddrPort("10.87.0.3:41931"))
	if err != nil {
		t.Fatal(err)
	}
	sender.Revoke("files")
	localStream(t, pending, 1).Close()
	if _, err = outgoing.Read(make([]byte, 1)); err == nil {
		t.Fatal("revoked stream remained open")
	}
	receiver.CloseReceiver(id)
	if _, err = receiver.AcceptReceiver(ctx, id); err == nil {
		t.Fatal("closed receiver accepted")
	}
	if _, err = sender.Issue("files", "receiver."+id, netip.MustParseAddrPort("8.8.8.8:41931")); err == nil {
		t.Fatal("public destination accepted")
	}
}

func TestTransportCloseReleasesAcceptedStreams(t *testing.T) {
	a, ap := testKey(t)
	b, bp := testKey(t)
	prefix := netip.MustParsePrefix("10.87.0.0/24")
	receiver, err := New(Config{PrivateKey: b, PeerPublicKey: ap, Address: netip.MustParseAddr("10.87.0.3"), AllowedPrefix: prefix})
	if err != nil {
		t.Fatal(err)
	}
	defer receiver.Close()
	port, _ := receiver.Port()
	sender, err := New(Config{PrivateKey: a, PeerPublicKey: bp, Endpoint: fmt.Sprintf("127.0.0.1:%d", port), Address: netip.MustParseAddr("10.87.0.2"), AllowedPrefix: prefix, Services: map[string]netip.AddrPort{"test": netip.MustParseAddrPort("10.87.0.3:9000")}})
	if err != nil {
		t.Fatal(err)
	}
	defer sender.Close()
	listener, err := receiver.Listen(9000)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	client, err := sender.Open(ctx, "test")
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	accepted, err := listener.Accept()
	if err != nil {
		t.Fatal(err)
	}
	receiver.Close()
	accepted.SetReadDeadline(time.Now().Add(time.Second))
	if _, err = accepted.Read(make([]byte, 1)); err == nil {
		t.Fatal("accepted stream survived shutdown")
	}
	if _, err = listener.Accept(); err == nil {
		t.Fatal("listener survived shutdown")
	}
}
