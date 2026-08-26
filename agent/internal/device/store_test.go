package device

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestEnrollAuthenticateListAndRevoke(t *testing.T) {
	stateDir := t.TempDir()
	store, err := Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}

	first, err := store.Enroll("Owner laptop")
	if err != nil {
		t.Fatal(err)
	}
	second, err := store.Enroll("Owner phone")
	if err != nil {
		t.Fatal(err)
	}
	if first.Device.ID == second.Device.ID || first.Token == second.Token {
		t.Fatal("two enrolled devices did not receive distinct credentials")
	}

	for _, credential := range []Credential{first, second} {
		authenticated, err := store.Authenticate(context.Background(), credential.Token)
		if err != nil {
			t.Fatal(err)
		}
		if !authenticated {
			t.Fatalf("device %s did not authenticate", credential.Device.ID)
		}
		contents, err := os.ReadFile(filepath.Join(store.activeDir, credential.Device.ID+".json"))
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(contents), credential.Token) {
			t.Fatal("plaintext device credential was written to agent state")
		}
	}

	records, err := store.List()
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 2 || records[0].Revoked || records[1].Revoked {
		t.Fatalf("unexpected active device list: %#v", records)
	}

	if err := store.Revoke(first.Device.ID); err != nil {
		t.Fatal(err)
	}
	authenticated, err := store.Authenticate(context.Background(), first.Token)
	if err != nil {
		t.Fatal(err)
	}
	if authenticated {
		t.Fatal("revoked device still authenticated")
	}
	authenticated, err = store.Authenticate(context.Background(), second.Token)
	if err != nil || !authenticated {
		t.Fatalf("unrelated device was affected by revocation: authenticated=%t err=%v", authenticated, err)
	}

	records, err = store.List()
	if err != nil {
		t.Fatal(err)
	}
	var revoked int
	for _, record := range records {
		if record.Revoked {
			revoked++
		}
	}
	if len(records) != 2 || revoked != 1 {
		t.Fatalf("unexpected device list after revocation: %#v", records)
	}

	reopened, err := Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	authenticated, err = reopened.Authenticate(context.Background(), second.Token)
	if err != nil || !authenticated {
		t.Fatalf("active credential did not survive store reopen: authenticated=%t err=%v", authenticated, err)
	}
}

func TestRejectsUnsafeMetadataAndCredentials(t *testing.T) {
	store, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"", "bad\nname", "reversed\u202ename", strings.Repeat("a", maxDeviceName+1)} {
		if _, err := store.Enroll(name); err == nil {
			t.Fatalf("unsafe device name %q was accepted", name)
		}
	}
	for _, token := range []string{"", "development-token", "epd1.bad.bad"} {
		authenticated, err := store.Authenticate(context.Background(), token)
		if err != nil {
			t.Fatalf("malformed credential returned an internal error: %v", err)
		}
		if authenticated {
			t.Fatalf("malformed credential %q authenticated", token)
		}
	}
	if err := store.Revoke("../escape"); err == nil {
		t.Fatal("unsafe device identifier was accepted")
	}
	if err := store.Revoke("AAAAAAAAAAAAAAAAAAAAAA"); !errors.Is(err, ErrDeviceNotFound) {
		t.Fatalf("missing device returned %v, expected ErrDeviceNotFound", err)
	}
}

func TestCorruptRecordFailsAuthenticationClosed(t *testing.T) {
	store, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	credential, err := store.Enroll("Owner laptop")
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(store.activeDir, credential.Device.ID+".json")
	if err := os.WriteFile(path, []byte("{not-json"), 0o600); err != nil {
		t.Fatal(err)
	}
	authenticated, err := store.Authenticate(context.Background(), credential.Token)
	if err == nil {
		t.Fatal("corrupt device record did not return an error")
	}
	if authenticated {
		t.Fatal("corrupt device record authenticated")
	}
}
