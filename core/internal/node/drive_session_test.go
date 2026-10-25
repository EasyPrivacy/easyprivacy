package node

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"io"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/easyprivacy/easyprivacy/core/internal/drive"
	"github.com/easyprivacy/easyprivacy/core/internal/link"
	"github.com/easyprivacy/easyprivacy/core/internal/vpn"
)

func driveIdentity(t *testing.T, s *Server, address, name string) (link.Identity, ed25519.PrivateKey) {
	t.Helper()
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	device, err := s.devices.Add(name, public)
	if err != nil {
		t.Fatal(err)
	}
	return link.Identity{Address: address, Fingerprint: s.state.Fingerprint(), DeviceID: device.ID,
		DeviceSeed: base64.StdEncoding.EncodeToString(private.Seed())}, private
}

func signInCount(s *Server) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.global.Count
}

func TestDriveRepeatedLoginsHitExistingSignInLimit(t *testing.T) {
	s, ts, _ := runningServer(t)
	identity, _ := driveIdentity(t, s, ts.URL, "Drive node")
	client := link.Client{Identity: identity}
	for i := 0; i < 6; i++ {
		token, err := client.Login()
		if i == 5 {
			var response *link.HTTPError
			if !errors.As(err, &response) || response.Code != 429 {
				t.Fatalf("sixth per-operation login did not reproduce rate limiting: %v", err)
			}
			return
		}
		if err != nil {
			t.Fatal(err)
		}
		if err = client.Request("GET", "/api/v1/devices", token, nil, nil); err != nil {
			t.Fatal(err)
		}
		if err = client.Request("POST", "/api/v1/logout", token, nil, nil); err != nil {
			t.Fatal(err)
		}
	}
}

func TestDriveSessionSharesLoginButFetchesFreshAuthorization(t *testing.T) {
	s, ts, _ := runningServer(t)
	s.UseVPN(&privateNetworkFixture{})
	identity, _ := driveIdentity(t, s, ts.URL, "Drive node")
	requester, private := driveIdentity(t, s, ts.URL, "Phone")
	client := link.NewSessionClient(identity)
	defer client.Close()
	errorsCh := make(chan error, 64)
	var workers sync.WaitGroup
	for i := 0; i < 8; i++ {
		workers.Go(func() {
			for j := 0; j < 8; j++ {
				key, err := client.DeviceKey(requester.DeviceID)
				if err == nil && !key.Equal(private.Public()) {
					err = errors.New("wrong authoritative device key")
				}
				errorsCh <- err
			}
		})
	}
	workers.Wait()
	close(errorsCh)
	for err := range errorsCh {
		if err != nil {
			t.Fatal(err)
		}
	}
	key, _ := vpn.GenerateKey()
	for i := 0; i < 12; i++ {
		if err := client.Request("POST", "/api/v2/network/private/peer", map[string]string{"public_key": key}, nil); err != nil {
			t.Fatal(err)
		}
		if err := client.Request("POST", "/api/v2/network/private/receiver", map[string]string{"capability": "drive", "name": "Drive node"}, nil); err != nil {
			t.Fatal(err)
		}
	}
	if got := signInCount(s); got != 2 {
		t.Fatalf("64 checks and 12 lease renewals used %d sign-in requests; want one challenge/login", got)
	}
	if err := s.devices.Revoke(requester.DeviceID); err != nil {
		t.Fatal(err)
	}
	if _, err := client.DeviceKey(requester.DeviceID); err == nil {
		t.Fatal("a cached authorization survived target revocation")
	}
	if got := signInCount(s); got != 2 {
		t.Fatalf("target revocation caused another login: %d", got)
	}
}

func TestDriveSessionRenewsExpiryAndBoundsRevokedNodeRetries(t *testing.T) {
	s, ts, _ := runningServer(t)
	identity, _ := driveIdentity(t, s, ts.URL, "Drive node")
	requester, _ := driveIdentity(t, s, ts.URL, "Phone")
	client := link.NewSessionClient(identity)
	defer client.Close()
	if _, err := client.DeviceKey(requester.DeviceID); err != nil {
		t.Fatal(err)
	}
	s.mu.Lock()
	for key, value := range s.sessions {
		value.Expires = time.Now().Add(-time.Second)
		s.sessions[key] = value
	}
	s.mu.Unlock()
	var workers sync.WaitGroup
	errorsCh := make(chan error, 16)
	for i := 0; i < 16; i++ {
		workers.Go(func() { _, err := client.DeviceKey(requester.DeviceID); errorsCh <- err })
	}
	workers.Wait()
	close(errorsCh)
	for err := range errorsCh {
		if err != nil {
			t.Fatal(err)
		}
	}
	if got := signInCount(s); got != 4 {
		t.Fatalf("concurrent expiry used %d sign-in requests; want two total logins", got)
	}
	if err := s.devices.Revoke(identity.DeviceID); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 16; i++ {
		if _, err := client.DeviceKey(requester.DeviceID); err == nil {
			t.Fatal("revoked storage node retained access")
		}
	}
	if got := signInCount(s); got != 5 {
		t.Fatalf("revoked-node retries were not bounded: %d sign-in requests", got)
	}
}

func TestDriveUploadUsesFreshCoreAuthorizationBeforePublication(t *testing.T) {
	s, ts, _ := runningServer(t)
	identity, _ := driveIdentity(t, s, ts.URL, "Drive node")
	requester, private := driveIdentity(t, s, ts.URL, "Phone")
	client := link.NewSessionClient(identity)
	defer client.Close()
	volume := drive.VolumeConfig{ID: strings.Repeat("1", 32), Name: "Cloud files", Path: t.TempDir(), Quota: 1024 * 1024}
	if err := drive.PrepareVolume(volume); err != nil {
		t.Fatal(err)
	}
	store, err := drive.Open([]drive.VolumeConfig{volume})
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	verify := &drive.Verifier{Core: identity.Fingerprint, Node: identity.DeviceID, Lookup: client.DeviceKey}
	exchange := func(command drive.Command) net.Conn {
		t.Helper()
		var nonce [32]byte
		if _, err := rand.Read(nonce[:]); err != nil {
			t.Fatal(err)
		}
		auth := drive.Authorization{Core: identity.Fingerprint, Device: requester.DeviceID, Node: identity.DeviceID,
			Nonce: hex.EncodeToString(nonce[:]), Expires: time.Now().Add(time.Minute).Unix(), Command: command,
			Identity: private.Public().(ed25519.PublicKey)}
		claim, err := auth.Claim()
		if err != nil {
			t.Fatal(err)
		}
		auth.Signature = ed25519.Sign(private, []byte(claim))
		outgoing, incoming := net.Pipe()
		outgoing.SetDeadline(time.Now().Add(10 * time.Second))
		done := make(chan struct{})
		go func() { defer close(done); drive.ServeConnection(incoming, store, verify) }()
		t.Cleanup(func() { outgoing.Close(); <-done })
		if err := drive.WriteFrame(outgoing, auth); err != nil {
			t.Fatal(err)
		}
		return outgoing
	}
	frame := func(conn net.Conn) map[string]any {
		t.Helper()
		var value map[string]any
		if err := drive.ReadFrame(conn, &value, 65536); err != nil {
			t.Fatal(err)
		}
		return value
	}
	for i := 0; i < 16; i++ {
		conn := exchange(drive.Command{Op: "volumes"})
		if result := frame(conn); result["status"] != "ok" {
			t.Fatal(result)
		}
		conn.Close()
	}
	payload := bytes.Repeat([]byte("independent photo upload"), 2048)
	hash := sha256.Sum256(payload)
	command := drive.Command{Op: "upload", Volume: volume.ID, Path: "photo.jpg", Size: int64(len(payload)), SHA256: hex.EncodeToString(hash[:])}
	conn := exchange(command)
	if result := frame(conn); result["status"] != "ready" {
		t.Fatal(result)
	}
	if _, err := io.Copy(conn, bytes.NewReader(payload)); err != nil {
		t.Fatal(err)
	}
	if result := frame(conn); result["status"] != "ok" {
		t.Fatal(result)
	}
	conn.Close()
	if signInCount(s) != 2 {
		t.Fatal("browsing and upload verification repeatedly authenticated the node")
	}
	command.Path = "revoked-photo.jpg"
	conn = exchange(command)
	if result := frame(conn); result["status"] != "ready" {
		t.Fatal(result)
	}
	if err := s.devices.Revoke(requester.DeviceID); err != nil {
		t.Fatal(err)
	}
	if _, err := io.Copy(conn, bytes.NewReader(payload)); err != nil {
		t.Fatal(err)
	}
	if result := frame(conn); result["status"] != "error" {
		t.Fatal("revoked upload was published", result)
	}
	conn.Close()
	entries, _, err := store.List(drive.Command{Op: "list", Volume: volume.ID})
	if err != nil || len(entries) != 1 || entries[0].Name != "photo.jpg" {
		t.Fatal("revoked upload changed cloud files", entries, err)
	}
	if volumes := store.Volumes(); volumes[0].Reserved != 0 || volumes[0].Used != int64(len(payload)) {
		t.Fatal("revoked upload retained data or quota", volumes)
	}
}
