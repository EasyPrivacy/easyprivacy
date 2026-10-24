package coreruntime

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"io"
	"net/netip"
	"testing"
	"time"
)

func testKey(t *testing.T) (string, string) {
	t.Helper()
	k, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(k.Bytes()), base64.StdEncoding.EncodeToString(k.PublicKey().Bytes())
}

func TestPrivateTransferWithoutSystemInterface(t *testing.T) {
	a, ap := testKey(t)
	b, bp := testKey(t)
	prefix := netip.MustParsePrefix("10.87.0.0/24")
	receiver, err := New(Config{PrivateKey: b, PeerPublicKey: ap, Address: netip.MustParseAddr("10.87.0.3"), AllowedPrefix: prefix})
	if err != nil {
		t.Fatal(err)
	}
	defer receiver.Close()
	port, err := receiver.Port()
	if err != nil {
		t.Fatal(err)
	}
	sender, err := New(Config{PrivateKey: a, PeerPublicKey: bp, Endpoint: fmt.Sprintf("127.0.0.1:%d", port), Address: netip.MustParseAddr("10.87.0.2"), AllowedPrefix: prefix, Services: map[string]netip.AddrPort{"files.receiver": netip.MustParseAddrPort("10.87.0.3:9000")}})
	if err != nil {
		t.Fatal(err)
	}
	defer sender.Close()
	listener, err := receiver.Listen(9000)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	payload := bytes.Repeat([]byte("private transfer payload"), 128*1024)
	expected := sha256.Sum256(payload)
	done := make(chan error, 1)
	go func() {
		stream, err := listener.Accept()
		if err != nil {
			done <- err
			return
		}
		defer stream.Close()
		stream.SetDeadline(time.Now().Add(20 * time.Second))
		h := sha256.New()
		_, err = io.CopyN(h, stream, int64(len(payload)))
		if err == nil && !bytes.Equal(h.Sum(nil), expected[:]) {
			err = fmt.Errorf("payload integrity failed")
		}
		if err == nil {
			_, err = stream.Write([]byte("received"))
		}
		done <- err
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	stream, err := sender.Open(ctx, "files.receiver")
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Close()
	stream.SetDeadline(time.Now().Add(20 * time.Second))
	if _, err = io.Copy(stream, bytes.NewReader(payload)); err != nil {
		t.Fatal(err)
	}
	ack := make([]byte, 8)
	if _, err = io.ReadFull(stream, ack); err != nil {
		t.Fatal(err)
	}
	if string(ack) != "received" {
		t.Fatal("missing receipt")
	}
	if err = <-done; err != nil {
		t.Fatal(err)
	}
	if _, err = sender.Open(ctx, "not-granted"); err == nil {
		t.Fatal("ungranted destination accepted")
	}
	sender.Close()
	if _, err = sender.Open(ctx, "files.receiver"); err == nil {
		t.Fatal("closed transport accepted a connection")
	}
}

func TestRejectsPublicRoutesAndServiceEscape(t *testing.T) {
	a, _ := testKey(t)
	_, b := testKey(t)
	for _, prefix := range []string{"0.0.0.0/0", "8.8.8.0/24"} {
		_, err := New(Config{PrivateKey: a, PeerPublicKey: b, Address: netip.MustParseAddr("10.87.0.2"), AllowedPrefix: netip.MustParsePrefix(prefix)})
		if err == nil {
			t.Fatalf("accepted route %s", prefix)
		}
	}
	_, err := New(Config{PrivateKey: a, PeerPublicKey: b, Address: netip.MustParseAddr("10.87.0.2"), AllowedPrefix: netip.MustParsePrefix("10.87.0.0/24"), Services: map[string]netip.AddrPort{"escape": netip.MustParseAddrPort("1.1.1.1:443")}})
	if err == nil {
		t.Fatal("accepted public service target")
	}
}
