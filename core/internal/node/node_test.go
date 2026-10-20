package node

import (
	"bytes"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

const testPassword = "a testing passphrase only"

func fixture(t *testing.T) *State {
	t.Helper()
	state, err := NewState("Test Core", 17444, "owner", testPassword)
	if err != nil {
		t.Fatal(err)
	}
	return state
}

func TestInstallationIdentitySurvivesReloadAndCannotBeOverwritten(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "private")
	state := fixture(t)
	if err := SaveNew(dir, state, -1); err != nil {
		t.Fatal(err)
	}
	loaded, err := Load(dir)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.Fingerprint() != state.Fingerprint() {
		t.Fatal("identity changed")
	}
	before, _ := os.ReadFile(StatePath(dir))
	if bytes.Contains(before, []byte(testPassword)) {
		t.Fatal("plain-text password was persisted")
	}
	if err := SaveNew(dir, fixture(t), -1); err == nil {
		t.Fatal("setup replaced an existing core")
	}
	after, _ := os.ReadFile(StatePath(dir))
	if !bytes.Equal(before, after) {
		t.Fatal("existing installation changed")
	}
}

func TestUnsafeOrCorruptStateIsRejected(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "private")
	if _, err := Load(dir); err == nil {
		t.Fatal("missing state accepted")
	}
	if err := SaveNew(dir, fixture(t), -1); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(StatePath(dir), 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(dir); err == nil {
		t.Fatal("world-readable state accepted")
	}
	_ = os.Chmod(StatePath(dir), 0600)
	_ = os.WriteFile(StatePath(dir), []byte("{}"), 0600)
	if _, err := Load(dir); err == nil {
		t.Fatal("corrupt state accepted")
	}
	linkDir := filepath.Join(t.TempDir(), "state")
	if err := os.Symlink(dir, linkDir); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(linkDir); err == nil {
		t.Fatal("symlinked state accepted")
	}
}

func runningServer(t *testing.T) (*Server, *httptest.Server, *http.Client) {
	t.Helper()
	state := fixture(t)
	server := NewServer(state, "test")
	cert, err := state.Certificate()
	if err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewUnstartedServer(server.Handler())
	httpServer.TLS = &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{cert}}
	httpServer.StartTLS()
	t.Cleanup(httpServer.Close)
	roots := x509.NewCertPool()
	roots.AddCert(cert.Leaf)
	transport := &http.Transport{TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS13, RootCAs: roots, ServerName: "core.easyprivacy.invalid"}}
	t.Cleanup(transport.CloseIdleConnections)
	return server, httpServer, &http.Client{Transport: transport, Timeout: 5 * time.Second}
}

func request(t *testing.T, client *http.Client, url, method, path, body, token string) (int, map[string]any) {
	t.Helper()
	req, err := http.NewRequest(method, url+path, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	res, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.TLS == nil || res.TLS.Version != tls.VersionTLS13 {
		t.Fatal("connection did not use TLS 1.3")
	}
	if res.Header.Get("Cache-Control") != "no-store" {
		t.Fatal("authentication response may be cached")
	}
	var value map[string]any
	if err := json.NewDecoder(res.Body).Decode(&value); err != nil {
		t.Fatal(err)
	}
	return res.StatusCode, value
}

func login(t *testing.T, client *http.Client, url, password string) (int, map[string]any) {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"username": "owner", "password": password})
	return request(t, client, url, "POST", "/api/v1/login", string(body), "")
}

func TestAuthenticatedConnectionLogoutAndExpiry(t *testing.T) {
	server, httpServer, client := runningServer(t)
	code, _ := request(t, client, httpServer.URL, "GET", "/api/v1/status", "", "")
	if code != 401 {
		t.Fatalf("unauthenticated status: %d", code)
	}
	code, _ = login(t, client, httpServer.URL, "incorrect password")
	if code != 401 {
		t.Fatalf("bad password: %d", code)
	}
	code, value := login(t, client, httpServer.URL, testPassword)
	if code != 200 {
		t.Fatalf("sign-in: %d", code)
	}
	token := value["access_token"].(string)
	code, value = request(t, client, httpServer.URL, "GET", "/api/v1/status", "", token)
	if code != 200 || value["core_name"] != "Test Core" {
		t.Fatalf("authenticated status: %d", code)
	}
	code, _ = request(t, client, httpServer.URL, "POST", "/api/v1/logout", "", token)
	if code != 200 {
		t.Fatalf("logout: %d", code)
	}
	code, _ = request(t, client, httpServer.URL, "GET", "/api/v1/status", "", token)
	if code != 401 {
		t.Fatal("signed-out token still works")
	}
	_, value = login(t, client, httpServer.URL, testPassword)
	token = value["access_token"].(string)
	server.mu.Lock()
	server.sessions[sha256.Sum256([]byte(token))] = session{Expires: time.Now().Add(-time.Second)}
	server.mu.Unlock()
	code, _ = request(t, client, httpServer.URL, "GET", "/api/v1/status", "", token)
	if code != 401 {
		t.Fatal("expired session still works")
	}
}

func TestMalformedRequestsAndBruteForceAreBounded(t *testing.T) {
	_, httpServer, client := runningServer(t)
	for _, body := range []string{`{}`, `{"username":"owner","password":"x","extra":1}`, `{} {}`, strings.Repeat("x", 5000)} {
		code, _ := request(t, client, httpServer.URL, "POST", "/api/v1/login", body, "")
		if code != 400 && code != 401 {
			t.Fatalf("malformed sign-in: %d", code)
		}
	}
	for range 6 {
		_, _ = login(t, client, httpServer.URL, "incorrect")
	}
	code, _ := login(t, client, httpServer.URL, testPassword)
	if code != 429 {
		t.Fatalf("sign-in attempts not limited: %d", code)
	}
}

func TestSessionAccessIsRaceSafe(t *testing.T) {
	_, httpServer, client := runningServer(t)
	_, value := login(t, client, httpServer.URL, testPassword)
	token := value["access_token"].(string)
	var group sync.WaitGroup
	for range 8 {
		group.Go(func() {
			code, _ := request(t, client, httpServer.URL, "GET", "/api/v1/status", "", token)
			if code != 200 {
				t.Errorf("concurrent status: %d", code)
			}
		})
	}
	group.Wait()
}

func TestHTTPAndUnknownServerCertificateAreRejected(t *testing.T) {
	_, httpServer, client := runningServer(t)
	req := httptest.NewRequest("POST", "http://localhost/api/v1/login", strings.NewReader(`{}`))
	response := httptest.NewRecorder()
	NewServer(fixture(t), "test").Handler().ServeHTTP(response, req)
	if response.Code != 400 {
		t.Fatal("plain HTTP accepted")
	}
	transport := client.Transport.(*http.Transport).Clone()
	transport.TLSClientConfig.RootCAs = x509.NewCertPool()
	badClient := &http.Client{Transport: transport, Timeout: time.Second}
	if res, err := badClient.Get(httpServer.URL + "/healthz"); err == nil {
		res.Body.Close()
		t.Fatal("unknown server identity accepted")
	}
	transport.CloseIdleConnections()
	res, err := client.Get(httpServer.URL + "/healthz")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	_, _ = io.Copy(io.Discard, res.Body)
	if res.StatusCode != 200 {
		t.Fatal("health check failed")
	}
}
