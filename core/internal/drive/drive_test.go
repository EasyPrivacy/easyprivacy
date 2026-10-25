package drive

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// Synthetic loopback fixture used by the real Dart client interoperability test.
func TestDriveClientFixture(t *testing.T) {
	if os.Getenv("EP_DRIVE_FIXTURE") != "1" {
		t.Skip("operator-only Dart/Go fixture")
	}
	s, c := fixture(t, 1024*1024)
	keys := map[string]ed25519.PublicKey{}
	for _, seed := range []byte{11, 29} {
		key := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{seed}, 32)).Public().(ed25519.PublicKey)
		sum := sha256.Sum256(key)
		keys[hex.EncodeToString(sum[:])] = key
	}
	verify := &Verifier{Core: "SHA256:" + strings.Repeat("A", 64), Node: strings.Repeat("b", 64), Lookup: func(id string) (ed25519.PublicKey, error) {
		key, ok := keys[id]
		if !ok {
			return nil, errors.New("unknown device")
		}
		return key, nil
	}}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	ready, _ := json.Marshal(map[string]any{"port": listener.Addr().(*net.TCPAddr).Port, "volume": c.ID})
	fmt.Println("DRIVE_FIXTURE " + string(ready))
	var mu sync.Mutex
	active := map[net.Conn]bool{}
	var pending sync.WaitGroup
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			mu.Lock()
			active[conn] = true
			mu.Unlock()
			pending.Add(1)
			go func() {
				defer pending.Done()
				defer func() { mu.Lock(); delete(active, conn); mu.Unlock() }()
				ServeConnection(conn, s, verify)
			}()
		}
	}()
	_, _ = io.Copy(io.Discard, os.Stdin)
	listener.Close()
	<-done
	mu.Lock()
	for conn := range active {
		conn.Close()
	}
	mu.Unlock()
	pending.Wait()
}
func fixture(t *testing.T, quota int64) (*Store, VolumeConfig) {
	t.Helper()
	c := VolumeConfig{ID: strings.Repeat("1", 32), Name: "Cloud", Path: t.TempDir(), Quota: quota}
	if err := PrepareVolume(c); err != nil {
		t.Fatal(err)
	}
	s, err := Open([]VolumeConfig{c})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	return s, c
}
func uploadCommand(c VolumeConfig, name, value string) Command {
	sum := sha256.Sum256([]byte(value))
	return Command{Op: "upload", Volume: c.ID, Path: name, Size: int64(len(value)), SHA256: hex.EncodeToString(sum[:])}
}
func TestAtomicUploadsQuotaReservationsAndRestart(t *testing.T) {
	s, c := fixture(t, 10)
	command := uploadCommand(c, "keep.txt", "123456")
	first, err := s.Begin(command)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.Begin(uploadCommand(c, "other.txt", "12345")); err == nil {
		t.Fatal("concurrent reservations exceeded capacity")
	}
	if _, err = os.Stat(filepath.Join(c.Path, "keep.txt")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("partial upload was published")
	}
	if got := s.Volumes()[0]; got.Used != 0 || got.Reserved != 6 {
		t.Fatal("incorrect reservation", got)
	}
	first.Abort()
	for _, content := range []string{"12", "wrong!"} {
		u, err := s.Begin(command)
		if err != nil {
			t.Fatal(err)
		}
		if err = u.Receive(strings.NewReader(content)); err == nil {
			t.Fatal("incomplete or corrupt upload accepted")
		}
	}
	if got := s.Volumes()[0]; got.Used != 0 || got.Reserved != 0 {
		t.Fatal("failed upload retained capacity", got)
	}
	u, err := s.Begin(command)
	if err != nil {
		t.Fatal(err)
	}
	if err = u.Receive(strings.NewReader("123456")); err != nil {
		t.Fatal(err)
	}
	if _, err = s.Begin(command); err == nil {
		t.Fatal("existing cloud data can be overwritten silently")
	}
	restarted, err := Open([]VolumeConfig{c})
	if err != nil {
		t.Fatal(err)
	}
	defer restarted.Close()
	if got := restarted.Volumes()[0]; got.Used != 6 || got.Reserved != 0 {
		t.Fatal("restart lost usage", got)
	}
	data, err := os.ReadFile(filepath.Join(c.Path, "keep.txt"))
	if err != nil || string(data) != "123456" {
		t.Fatal("uploaded bytes were not retained")
	}
	if err = s.Change(Command{Op: "delete", Volume: c.ID, Path: "keep.txt"}); err != nil {
		t.Fatal(err)
	}
	if got := s.Volumes()[0]; got.Used != 0 {
		t.Fatal("deletion did not free allocated capacity")
	}
}
func TestVolumePreparationIsRetryableAndStagingCleanupIsConfined(t *testing.T) {
	s, c := fixture(t, 100)
	id, err := StoredVolumeID(c.Path)
	if err != nil || id != c.ID {
		t.Fatal("volume identity was not retained", err)
	}
	if err = PrepareVolume(c); err != nil {
		t.Fatal("retry damaged an existing volume", err)
	}
	other := c
	other.ID = strings.Repeat("2", 32)
	if PrepareVolume(other) == nil {
		t.Fatal("existing identity was overwritten")
	}
	userFile := filepath.Join(c.Path, "keep.txt")
	os.WriteFile(userFile, []byte("keep"), 0600)
	orphan := filepath.Join(c.Path, controlDir, "uploads", Token()+".part")
	os.WriteFile(orphan, []byte("partial"), 0600)
	if err = s.CleanUploads(); err != nil {
		t.Fatal(err)
	}
	if _, err = os.Stat(orphan); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("orphaned staging was retained")
	}
	if data, _ := os.ReadFile(userFile); string(data) != "keep" {
		t.Fatal("cleanup removed user content")
	}
}
func TestStorageConfinementMissingMountAndPagination(t *testing.T) {
	s, c := fixture(t, 1<<20)
	for _, name := range []string{"../escape", "/absolute", "a//b", ".easyprivacy-drive/volume-id", "a\\b", "NUL.txt", "a\x7fb"} {
		if ValidPath(name, false) {
			t.Fatal("invalid path accepted", name)
		}
	}
	outside := t.TempDir()
	os.WriteFile(filepath.Join(outside, "private"), []byte("keep"), 0600)
	if err := os.Symlink(outside, filepath.Join(c.Path, "link")); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.Download(Command{Op: "download", Volume: c.ID, Path: "link/private"}); err == nil {
		t.Fatal("linked download escaped storage")
	}
	if err := s.Change(Command{Op: "delete", Volume: c.ID, Path: "link"}); err == nil {
		t.Fatal("linked item accepted")
	}
	os.Remove(filepath.Join(c.Path, "link"))
	for i := range 130 {
		os.WriteFile(filepath.Join(c.Path, fmt.Sprintf("file-%03d", i)), []byte("x"), 0600)
	}
	entries, cursor, err := s.List(Command{Op: "list", Volume: c.ID})
	if err != nil || len(entries) != 128 || cursor == "" {
		t.Fatal("first page", len(entries), cursor, err)
	}
	last, next, err := s.List(Command{Op: "list", Volume: c.ID, Cursor: cursor})
	if err != nil || len(last) != 2 || next != "" || last[0].Name <= entries[127].Name {
		t.Fatal("metadata pagination failed", last, err)
	}
	moved := c.Path + "-moved"
	if err = os.Rename(c.Path, moved); err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(moved)
	if err = os.Mkdir(c.Path, 0700); err != nil {
		t.Fatal(err)
	}
	if err = PrepareVolume(c); err != nil {
		t.Fatal(err)
	}
	if _, _, err = s.List(Command{Op: "list", Volume: c.ID}); err == nil {
		t.Fatal("replacement mount was treated as original volume")
	}
	data, _ := os.ReadFile(filepath.Join(moved, "file-000"))
	if string(data) != "x" {
		t.Fatal("old storage was modified")
	}
}
func TestRevocationBeforeUploadPublicationPreservesData(t *testing.T) {
	s, c := fixture(t, 20)
	u, err := s.Begin(uploadCommand(c, "new.txt", "hello"))
	if err != nil {
		t.Fatal(err)
	}
	if err = u.ReceiveChecked(strings.NewReader("hello"), func() error { return errors.New("revoked") }); err == nil {
		t.Fatal("revoked upload published")
	}
	if got := s.Volumes()[0]; got.Used != 0 || got.Reserved != 0 {
		t.Fatal("revoked upload retained bytes or quota", got)
	}
}
func signed(t *testing.T, c Command, node string) (Authorization, ed25519.PublicKey) {
	t.Helper()
	public, private, _ := ed25519.GenerateKey(rand.Reader)
	sum := sha256.Sum256(public)
	a := Authorization{Command: c, Core: "SHA256:" + strings.Repeat("A", 64), Device: hex.EncodeToString(sum[:]), Node: node, Nonce: strings.Repeat("a", 64), Expires: time.Now().Add(time.Minute).Unix(), Identity: public}
	claim, err := a.Claim()
	if err != nil {
		t.Fatal(err)
	}
	a.Signature = ed25519.Sign(private, []byte(claim))
	return a, public
}
func TestScopedSignatureExpiryRevocationAndReplay(t *testing.T) {
	a, key := signed(t, Command{Op: "volumes"}, strings.Repeat("b", 64))
	active := true
	v := &Verifier{Core: a.Core, Node: a.Node, Lookup: func(string) (ed25519.PublicKey, error) {
		if !active {
			return nil, errors.New("revoked")
		}
		return key, nil
	}}
	for _, tamper := range []func(*Authorization){func(a *Authorization) { a.Node = strings.Repeat("c", 64) }, func(a *Authorization) { a.Command.Op = "delete" }, func(a *Authorization) { a.Expires = time.Now().Add(-time.Minute).Unix() }, func(a *Authorization) { a.Signature = bytes.Repeat([]byte{0}, 64) }} {
		changed := a
		tamper(&changed)
		if v.Verify(changed) == nil {
			t.Fatal("tampered request accepted")
		}
	}
	active = false
	if v.Verify(a) == nil {
		t.Fatal("revoked device accepted")
	}
	active = true
	if err := v.Verify(a); err != nil {
		t.Fatal(err)
	}
	if v.Verify(a) == nil {
		t.Fatal("request replay accepted")
	}
}
func TestClaimInteroperabilityVector(t *testing.T) {
	a := Authorization{Core: "SHA256:" + strings.Repeat("A", 64), Device: strings.Repeat("a", 64), Node: strings.Repeat("b", 64), Nonce: strings.Repeat("c", 64), Expires: 1900000000, Command: Command{Op: "download", Volume: strings.Repeat("1", 32), Path: "café/notes.md"}}
	claim, err := a.Claim()
	if err != nil {
		t.Fatal(err)
	}
	expected := "EasyPrivacy Drive request v1\n" + a.Core + "\n" + a.Device + "\n" + a.Node + "\ndownload\n" + a.Command.Volume + "\nY2Fmw6kvbm90ZXMubWQ=\n\n\n0\n\n" + a.Nonce + "\n1900000000"
	if claim != expected {
		t.Fatalf("claim bytes changed: %q", claim)
	}
}
func TestWireUploadAndExplicitDownload(t *testing.T) {
	s, c := fixture(t, 1024)
	node := strings.Repeat("b", 64)
	command := uploadCommand(c, "sample.md", "hello cloud")
	request, key := signed(t, command, node)
	verify := &Verifier{Core: request.Core, Node: node, Lookup: func(string) (ed25519.PublicKey, error) { return key, nil }}
	client, server := net.Pipe()
	defer client.Close()
	client.SetDeadline(time.Now().Add(5 * time.Second))
	go ServeConnection(server, s, verify)
	if err := WriteFrame(client, request); err != nil {
		t.Fatal(err)
	}
	var frame map[string]any
	if err := ReadFrame(client, &frame, 65536); err != nil || frame["status"] != "ready" {
		t.Fatal(frame, err)
	}
	if _, err := client.Write([]byte("hello cloud")); err != nil {
		t.Fatal(err)
	}
	if err := ReadFrame(client, &frame, 65536); err != nil || frame["status"] != "ok" || frame["sha256"] != command.SHA256 {
		t.Fatal(frame, err)
	}
	// A fresh authorization and connection are required to retrieve any bytes.
	next, nextKey := signed(t, Command{Op: "download", Volume: c.ID, Path: "sample.md"}, node)
	verify = &Verifier{Core: next.Core, Node: node, Lookup: func(string) (ed25519.PublicKey, error) { return nextKey, nil }}
	download, peer := net.Pipe()
	defer download.Close()
	download.SetDeadline(time.Now().Add(5 * time.Second))
	go ServeConnection(peer, s, verify)
	WriteFrame(download, next)
	if err := ReadFrame(download, &frame, 65536); err != nil || frame["status"] != "ok" {
		t.Fatal(frame, err)
	}
	data := make([]byte, 11)
	if _, err := io.ReadFull(download, data); err != nil || string(data) != "hello cloud" {
		t.Fatal(string(data), err)
	}
	if err := ReadFrame(download, &frame, 65536); err != nil || frame["sha256"] != command.SHA256 {
		t.Fatal(frame, err)
	}
}
