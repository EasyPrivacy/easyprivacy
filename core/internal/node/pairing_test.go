package node

import (
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/easyprivacy/easyprivacy/core/internal/pake"
)

func jsonBody(value any) string { raw, _ := json.Marshal(value); return string(raw) }
func decodeBytes(t *testing.T, value any) []byte {
	t.Helper()
	b, err := base64.StdEncoding.DecodeString(value.(string))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func pairAttempt(t *testing.T, s *Server, ts *httptest.Server, client *http.Client, code string, public []byte, alter string) (int, map[string]any) {
	t.Helper()
	target, name := "127.0.0.1:7444", "My phone"
	status, start := request(t, client, ts.URL, "POST", "/api/v1/pairing/start", jsonBody(map[string]any{"target": target, "device_name": name, "public_key": public}), "")
	if status != 200 {
		return status, start
	}
	id := start["exchange_id"].(string)
	pin := start["core_fingerprint"].(string)
	if alter == "pin" {
		pin = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
	}
	if alter == "key" {
		public = make([]byte, 32)
	}
	context := pairingContext(id, target, name, public, pin)
	app, err := pake.Start(0, code, context)
	if err != nil {
		t.Fatal(err)
	}
	defer app.Close()
	key, err := app.Finish(decodeBytes(t, start["message"]))
	if err != nil {
		t.Fatal(err)
	}
	defer clear(key)
	device := deviceID(public)
	body := jsonBody(map[string]any{"exchange_id": id, "message": app.Message, "proof": pairingMAC(key, "app", context, device)})
	status, result := request(t, client, ts.URL, "POST", "/api/v1/pairing/finish", body, "")
	if status == 200 {
		if result["device_id"] != device || !hmac.Equal(decodeBytes(t, result["proof"]), pairingMAC(key, "core", context, device)) {
			t.Fatal("core mutual confirmation failed")
		}
		if _, ok := result["access_token"]; ok {
			t.Fatal("pairing released a bearer token on the provisional connection")
		}
		if pin != s.state.Fingerprint() {
			t.Fatal("unverified core identity accepted")
		}
		if _, authorized := s.devices.Active(device); authorized {
			t.Fatal("code confirmation alone authorized a device")
		}
		result["exchange_id"] = id
		result["enrollment_proof"] = pairingMAC(key, "enroll", context, device)
	}
	if alter == "replay" {
		status, _ = request(t, client, ts.URL, "POST", "/api/v1/pairing/finish", body, "")
		if status != 401 {
			t.Fatalf("pairing replay returned %d", status)
		}
		status = 200
	}
	if status == 200 && alter != "verify" {
		return enrollAttempt(t, client, ts.URL, result, "owner", testPassword)
	}
	return status, result
}

func enrollAttempt(t *testing.T, client *http.Client, url string, verification map[string]any, username, password string) (int, map[string]any) {
	t.Helper()
	return request(t, client, url, "POST", "/api/v1/pairing/enroll", jsonBody(map[string]any{
		"exchange_id": verification["exchange_id"], "proof": verification["enrollment_proof"], "username": username, "password": password,
	}), "")
}

func TestEnrollmentRequiresBothCodeProofAndAccountPassword(t *testing.T) {
	s, ts, client := runningServer(t)
	public, _, _ := ed25519.GenerateKey(rand.Reader)
	code, _ := s.CreatePairingCode()
	status, verified := pairAttempt(t, s, ts, client, code.Code, public, "verify")
	if status != 200 || len(s.devices.List()) != 0 {
		t.Fatal("verification enrolled a device")
	}
	status, _ = request(t, client, ts.URL, "POST", "/api/v1/device/challenge", jsonBody(map[string]string{"device_id": deviceID(public)}), "")
	if status != 401 {
		t.Fatal("verified but unauthenticated key could log in")
	}
	status, _ = enrollAttempt(t, client, ts.URL, map[string]any{"exchange_id": verified["exchange_id"]}, "owner", testPassword)
	if status != 410 {
		t.Fatal("password without the code-derived proof enrolled a device")
	}
	for _, credentials := range [][2]string{{"owner", "wrong password"}, {"wrong owner", testPassword}} {
		status, _ = enrollAttempt(t, client, ts.URL, verified, credentials[0], credentials[1])
		if status != 401 || len(s.devices.List()) != 0 {
			t.Fatal("incorrect credentials enrolled a device")
		}
	}
	status, _ = enrollAttempt(t, client, ts.URL, verified, "owner", testPassword)
	if status != 200 || len(s.devices.List()) != 1 {
		t.Fatal("verified account could not enroll")
	}
	status, _ = enrollAttempt(t, client, ts.URL, verified, "owner", testPassword)
	if status != 410 {
		t.Fatal("enrollment proof replay accepted")
	}
}

func TestEnrollmentPasswordAttemptsAreBounded(t *testing.T) {
	s, ts, client := runningServer(t)
	public, _, _ := ed25519.GenerateKey(rand.Reader)
	code, _ := s.CreatePairingCode()
	_, verified := pairAttempt(t, s, ts, client, code.Code, public, "verify")
	for range 5 {
		status, _ := enrollAttempt(t, client, ts.URL, verified, "owner", "wrong password")
		if status != 401 {
			t.Fatal("unexpected password attempt result", status)
		}
	}
	status, _ := enrollAttempt(t, client, ts.URL, verified, "owner", testPassword)
	if status != 410 || len(s.devices.List()) != 0 {
		t.Fatal("exhausted verification remained usable")
	}
}

func TestStaleCoreVerificationCannotEnroll(t *testing.T) {
	for _, reason := range []string{"expired", "replaced", "revoked creator"} {
		t.Run(reason, func(t *testing.T) {
			s, ts, client := runningServer(t)
			creatorPublic, _, _ := ed25519.GenerateKey(rand.Reader)
			creator, _ := s.devices.Add("Existing owner device", creatorPublic)
			code, _ := s.newPairingCodeLocked(creator.ID)
			public, _, _ := ed25519.GenerateKey(rand.Reader)
			_, verified := pairAttempt(t, s, ts, client, code.Code, public, "verify")
			s.mu.Lock()
			switch reason {
			case "expired":
				s.enrollments[verified["exchange_id"].(string)].ExpiresAt = time.Now().Add(-time.Second)
			case "replaced":
				s.lastCode = time.Time{}
				_, _ = s.newPairingCodeLocked("")
			case "revoked creator":
				_ = s.revokeLocked(creator.ID)
			}
			s.mu.Unlock()
			status, _ := enrollAttempt(t, client, ts.URL, verified, "owner", testPassword)
			if status != 410 || len(s.devices.List()) != 1 {
				t.Fatal("stale verification enrolled a device")
			}
		})
	}
}

func TestConcurrentAccountEnrollmentConsumesCodeOnce(t *testing.T) {
	s, ts, client := runningServer(t)
	code, _ := s.CreatePairingCode()
	verifications := make([]map[string]any, 2)
	for i := range verifications {
		public, _, _ := ed25519.GenerateKey(rand.Reader)
		status, verified := pairAttempt(t, s, ts, client, code.Code, public, "verify")
		if status != 200 {
			t.Fatal(status)
		}
		verifications[i] = verified
	}
	var successes atomic.Int32
	var group sync.WaitGroup
	for _, verified := range verifications {
		group.Go(func() {
			status, _ := enrollAttempt(t, client, ts.URL, verified, "owner", testPassword)
			if status == 200 {
				successes.Add(1)
			} else if status != 410 {
				t.Errorf("unexpected status %d", status)
			}
		})
	}
	group.Wait()
	if successes.Load() != 1 || len(s.devices.List()) != 1 {
		t.Fatal("one code enrolled multiple devices")
	}
}

func deviceSession(t *testing.T, s *Server, ts *httptest.Server, client *http.Client, private ed25519.PrivateKey) string {
	t.Helper()
	id := deviceID(private.Public().(ed25519.PublicKey))
	status, challenge := request(t, client, ts.URL, "POST", "/api/v1/device/challenge", jsonBody(map[string]string{"device_id": id}), "")
	if status != 200 {
		t.Fatalf("device challenge: %d %v", status, challenge)
	}
	challengeID := challenge["challenge_id"].(string)
	body := jsonBody(map[string]any{"device_id": id, "challenge_id": challengeID, "signature": ed25519.Sign(private, deviceLoginMessage(s.state.Fingerprint(), id, challengeID))})
	status, result := request(t, client, ts.URL, "POST", "/api/v1/device/login", body, "")
	if status != 200 {
		t.Fatalf("device login: %d %v", status, result)
	}
	status, _ = request(t, client, ts.URL, "POST", "/api/v1/device/login", body, "")
	if status != 401 {
		t.Fatal("device challenge replay accepted")
	}
	return result["access_token"].(string)
}

func TestPairingDeviceLoginCodeCreationAndImmediateRevocation(t *testing.T) {
	s, ts, client := runningServer(t)
	public, private, _ := ed25519.GenerateKey(rand.Reader)
	code, err := s.CreatePairingCode()
	if err != nil {
		t.Fatal(err)
	}
	status, _ := pairAttempt(t, s, ts, client, code.Code, public, "replay")
	if status != 200 {
		t.Fatalf("pairing: %d", status)
	}
	status, _ = request(t, client, ts.URL, "POST", "/api/v1/pairing/start", jsonBody(map[string]any{"target": "core:7444", "device_name": "second", "public_key": public}), "")
	if status != 401 {
		t.Fatal("successful pairing did not consume code")
	}
	token := deviceSession(t, s, ts, client, private)
	status, _ = request(t, client, ts.URL, "GET", "/api/v1/status", "", token)
	if status != 200 {
		t.Fatal("device status failed")
	}
	s.mu.Lock()
	s.lastCode = time.Time{}
	s.mu.Unlock()
	status, _ = request(t, client, ts.URL, "POST", "/api/v1/pairing/code", "", token)
	if status != 200 {
		t.Fatalf("paired session could not create code without password: %d", status)
	}
	status, _ = request(t, client, ts.URL, "POST", "/api/v1/devices/"+deviceID(public)+"/revoke", "", token)
	if status != 200 {
		t.Fatal("revoke failed")
	}
	status, _ = request(t, client, ts.URL, "GET", "/api/v1/status", "", token)
	if status != 401 {
		t.Fatal("revoked device's existing session survived")
	}
	status, _ = request(t, client, ts.URL, "POST", "/api/v1/pairing/code", "", token)
	if status != 403 {
		t.Fatal("revoked session could create a code")
	}
	if s.code != nil {
		t.Fatal("code minted by a revoked device survived revocation")
	}
}

func TestPairingRejectsWrongCodeAndSubstitutedIdentity(t *testing.T) {
	for _, alter := range []string{"wrong", "pin", "key"} {
		t.Run(alter, func(t *testing.T) {
			s, ts, client := runningServer(t)
			public, _, _ := ed25519.GenerateKey(rand.Reader)
			code, _ := s.CreatePairingCode()
			password := code.Code
			if alter == "wrong" {
				password = "00000000"
				if password == code.Code {
					password = "11111111"
				}
			}
			status, _ := pairAttempt(t, s, ts, client, password, public, alter)
			if status != 401 || len(s.devices.List()) != 0 {
				t.Fatalf("tampered pairing was accepted: %d", status)
			}
		})
	}
}

func TestPairingAttemptsAreReservedAcrossConcurrentBegins(t *testing.T) {
	s, ts, client := runningServer(t)
	_, _ = s.CreatePairingCode()
	public, _, _ := ed25519.GenerateKey(rand.Reader)
	body := jsonBody(map[string]any{"target": "core:7444", "device_name": "phone", "public_key": public})
	var successes atomic.Int32
	var group sync.WaitGroup
	for range 8 {
		group.Go(func() {
			status, _ := request(t, client, ts.URL, "POST", "/api/v1/pairing/start", body, "")
			if status == 200 {
				successes.Add(1)
			} else if status != 401 {
				t.Errorf("unexpected status %d", status)
			}
		})
	}
	group.Wait()
	if successes.Load() != 5 {
		t.Fatalf("reserved %d guesses, want 5", successes.Load())
	}
	if len(s.pairings) != 5 {
		t.Fatal("pending pairing work was not bounded")
	}
	s.mu.Lock()
	for _, p := range s.pairings {
		p.PAKE.Close()
	}
	s.mu.Unlock()
}

func TestExpiredAndReplacedCodesInvalidatePendingExchanges(t *testing.T) {
	for _, replace := range []bool{false, true} {
		t.Run(map[bool]string{false: "expired", true: "replaced"}[replace], func(t *testing.T) {
			s, ts, client := runningServer(t)
			code, _ := s.CreatePairingCode()
			public, _, _ := ed25519.GenerateKey(rand.Reader)
			status, start := request(t, client, ts.URL, "POST", "/api/v1/pairing/start", jsonBody(map[string]any{"target": "core:7444", "device_name": "phone", "public_key": public}), "")
			if status != 200 {
				t.Fatal(status)
			}
			id := start["exchange_id"].(string)
			context := pairingContext(id, "core:7444", "phone", public, s.state.Fingerprint())
			app, _ := pake.Start(0, code.Code, context)
			defer app.Close()
			key, _ := app.Finish(decodeBytes(t, start["message"]))
			defer clear(key)
			s.mu.Lock()
			if replace {
				s.lastCode = time.Time{}
				_, _ = s.newPairingCodeLocked("")
			} else {
				s.code.ExpiresAt = time.Now().Add(-time.Second)
			}
			s.mu.Unlock()
			status, _ = request(t, client, ts.URL, "POST", "/api/v1/pairing/finish", jsonBody(map[string]any{"exchange_id": id, "message": app.Message, "proof": pairingMAC(key, "app", context, deviceID(public))}), "")
			if status != 401 || len(s.devices.List()) != 0 {
				t.Fatal("stale pairing survived")
			}
		})
	}
}

func TestLegacyPasswordSessionCannotMintPairingCodes(t *testing.T) {
	_, ts, client := runningServer(t)
	_, value := login(t, client, ts.URL, testPassword)
	status, _ := request(t, client, ts.URL, "POST", "/api/v1/pairing/code", "", value["access_token"].(string))
	if status != 403 {
		t.Fatal("unpaired password session could mint device enrollment codes")
	}
	status, _ = request(t, client, ts.URL, "POST", "/api/v1/pairing/code", "", "")
	if status != 403 {
		t.Fatal("unauthenticated code creation")
	}
}

func TestDeviceRecordsPersistAndCorruptionIsNotReplaced(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "devices")
	store, err := OpenDeviceStore(directory)
	if err != nil {
		t.Fatal(err)
	}
	public, _, _ := ed25519.GenerateKey(rand.Reader)
	d, err := store.Add("My phone", public)
	if err != nil {
		t.Fatal(err)
	}
	reopened, err := OpenDeviceStore(directory)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := reopened.Active(d.ID); !ok {
		t.Fatal("device did not survive restart")
	}
	if err := reopened.Revoke(d.ID); err != nil {
		t.Fatal(err)
	}
	reopened, err = OpenDeviceStore(directory)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := reopened.Active(d.ID); ok {
		t.Fatal("revocation did not survive restart")
	}
	path := filepath.Join(directory, "devices.json")
	before, _ := os.ReadFile(path)
	if err := os.Chmod(path, 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := OpenDeviceStore(directory); err == nil {
		t.Fatal("public device records accepted")
	}
	_ = os.Chmod(path, 0600)
	corrupt := []byte("invalid")
	_ = os.WriteFile(path, corrupt, 0600)
	if _, err := OpenDeviceStore(directory); err == nil {
		t.Fatal("corrupt records accepted")
	}
	after, _ := os.ReadFile(path)
	if string(after) != string(corrupt) || sha256.Sum256(before) == sha256.Sum256(after) {
		t.Fatal("corrupt records were replaced")
	}
}
