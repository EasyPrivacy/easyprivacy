package node

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"testing"

	"github.com/easyprivacy/easyprivacy/core/internal/link"
)

func TestHeadlessCodeThenPasswordEnrollmentAndRevocation(t *testing.T) {
	s, ts, _ := runningServer(t)
	code, err := s.CreatePairingCode()
	if err != nil {
		t.Fatal(err)
	}
	identity, err := link.Enroll(ts.URL, code.Code, "Home VM", s.state.Username, testPassword)
	if err != nil {
		t.Fatal(err)
	}
	pin := sha256.Sum256(ts.Certificate().Raw)
	if identity.Fingerprint != "SHA256:"+strings.ToUpper(hex.EncodeToString(pin[:])) {
		t.Fatal("wrong certificate pinned")
	}
	client := link.Client{Identity: identity}
	if _, err = client.Login(); err != nil {
		t.Fatal(err)
	}
	bad := identity
	bad.Fingerprint = "SHA256:" + strings.Repeat("0", 64)
	if _, err = (link.Client{Identity: bad}).Login(); err == nil {
		t.Fatal("changed core identity accepted")
	}
	if err = s.devices.Revoke(identity.DeviceID); err != nil {
		t.Fatal(err)
	}
	if _, err = client.Login(); err == nil {
		t.Fatal("revoked headless identity logged in")
	}
}
func TestHeadlessWrongCodeDoesNotEnroll(t *testing.T) {
	s, ts, _ := runningServer(t)
	code, err := s.CreatePairingCode()
	if err != nil {
		t.Fatal(err)
	}
	wrong := "00000000"
	if code.Code == wrong {
		wrong = "11111111"
	}
	if _, err = link.Enroll(ts.URL, wrong, "Home", s.state.Username, testPassword); err == nil {
		t.Fatal("wrong pairing code enrolled")
	}
	if len(s.devices.List()) != 0 {
		t.Fatal("wrong code created an identity")
	}
}
