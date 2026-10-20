// Package link implements the same code-then-password enrollment and signed
// device login used by the desktop app, for unattended Linux service nodes.
package link

import (
	"bytes"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/easyprivacy/easyprivacy/core/internal/pake"
	"github.com/easyprivacy/easyprivacy/core/internal/vpn"
)

type Identity struct {
	Address     string `json:"address"`
	Username    string `json:"username"`
	Fingerprint string `json:"fingerprint"`
	DeviceSeed  string `json:"device_seed"`
	DeviceID    string `json:"device_id"`
}
type Client struct{ Identity Identity }
type HTTPError struct {
	Code    int
	Message string
}

func (e *HTTPError) Error() string { return e.Message }
func Authority(address string) (string, error) {
	if !strings.Contains(address, "://") {
		address = "https://" + address
	}
	u, err := url.Parse(address)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.Path != "" || u.RawQuery != "" || u.Fragment != "" || strings.ContainsAny(u.Host, "\r\n\x00 /\\") {
		return "", errors.New("enter a core hostname or IP with its management port")
	}
	if u.Port() == "" {
		return net.JoinHostPort(u.Hostname(), "7444"), nil
	}
	if _, err := net.ResolveTCPAddr("tcp", u.Host); err != nil {
		return "", errors.New("invalid core address")
	}
	return u.Host, nil
}
func validPin(pin string) bool {
	if !strings.HasPrefix(pin, "SHA256:") {
		return false
	}
	b, err := hex.DecodeString(strings.TrimPrefix(pin, "SHA256:"))
	return err == nil && len(b) == 32 && pin == strings.ToUpper(pin)
}
func (i Identity) PrivateKey() (ed25519.PrivateKey, error) {
	seed, err := base64.StdEncoding.DecodeString(i.DeviceSeed)
	if err != nil || len(seed) != ed25519.SeedSize {
		return nil, errors.New("invalid saved device identity")
	}
	defer clear(seed)
	key := ed25519.NewKeyFromSeed(seed)
	hash := sha256.Sum256(key.Public().(ed25519.PublicKey))
	if hex.EncodeToString(hash[:]) != i.DeviceID || !validPin(i.Fingerprint) {
		clear(key)
		return nil, errors.New("device identity does not match its saved ID")
	}
	return key, nil
}

func (c Client) Request(method, path, token string, input, output any) error {
	authority, err := Authority(c.Identity.Address)
	if err != nil {
		return err
	}
	pin := c.Identity.Fingerprint
	if pin == "" && (method != "POST" || (path != "/api/v1/pairing/start" && path != "/api/v1/pairing/finish") || token != "") {
		return errors.New("verify the core before sending credentials")
	}
	if pin != "" && !validPin(pin) {
		return errors.New("invalid saved core fingerprint")
	}
	var body []byte
	if input != nil {
		body, err = json.Marshal(input)
		if err != nil {
			return err
		}
		defer clear(body)
	}
	transport := &http.Transport{TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS13, InsecureSkipVerify: true, VerifyConnection: func(state tls.ConnectionState) error {
		if pin == "" {
			return nil
		} // Only the public PAKE exchange is permitted above.
		if len(state.PeerCertificates) == 0 {
			return errors.New("core did not present its identity")
		}
		cert := state.PeerCertificates[0]
		hash := sha256.Sum256(cert.Raw)
		actual := "SHA256:" + strings.ToUpper(hex.EncodeToString(hash[:]))
		now := time.Now()
		if !hmac.Equal([]byte(pin), []byte(actual)) || now.Before(cert.NotBefore) || now.After(cert.NotAfter) {
			return errors.New("core identity verification failed")
		}
		return nil
	}}, DialContext: (&net.Dialer{Timeout: 6 * time.Second}).DialContext, TLSHandshakeTimeout: 6 * time.Second}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 12 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("core redirects are forbidden") }}
	request, err := http.NewRequest(method, "https://"+authority+path, bytes.NewReader(body))
	if err != nil {
		return err
	}
	if input != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	response, err := client.Do(request)
	if err != nil {
		return errors.New("could not reach or verify the core")
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(response.Body, 65537))
	if err != nil || len(raw) > 65536 {
		return errors.New("invalid core response")
	}
	defer clear(raw)
	if response.StatusCode != 200 {
		var message struct {
			Error string `json:"error"`
		}
		_ = json.Unmarshal(raw, &message)
		if message.Error == "" || len(message.Error) > 300 {
			message.Error = fmt.Sprintf("core rejected the request (%d)", response.StatusCode)
		}
		return &HTTPError{response.StatusCode, message.Error}
	}
	if output != nil {
		return json.Unmarshal(raw, output)
	}
	return nil
}
func proof(key []byte, role string, context [32]byte, id string) []byte {
	h := hmac.New(sha256.New, key)
	h.Write([]byte("easyprivacy.pairing.v2." + role + "\n"))
	h.Write(context[:])
	h.Write([]byte("\n" + id))
	return h.Sum(nil)
}
func Enroll(address, code, name, username, password string) (Identity, error) {
	var empty Identity
	address, err := Authority(address)
	if err != nil {
		return empty, err
	}
	if len(code) != 8 || strings.IndexFunc(code, func(r rune) bool { return r < '0' || r > '9' }) >= 0 {
		return empty, errors.New("enter the eight-digit pairing code")
	}
	pub, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return empty, err
	}
	defer clear(private)
	hash := sha256.Sum256(pub)
	identity := Identity{Address: address, Username: username, DeviceID: hex.EncodeToString(hash[:]), DeviceSeed: base64.StdEncoding.EncodeToString(private.Seed())}
	client := Client{Identity: identity}
	var begin struct {
		Protocol string `json:"protocol"`
		ID       string `json:"exchange_id"`
		Pin      string `json:"core_fingerprint"`
		Message  []byte `json:"message"`
	}
	if err = client.Request("POST", "/api/v1/pairing/start", "", map[string]any{"target": address, "device_name": name, "public_key": pub}, &begin); err != nil {
		return empty, err
	}
	if begin.Protocol != "easyprivacy.pairing.v2" || !vpn.ValidID(begin.ID) || !validPin(begin.Pin) {
		return empty, errors.New("invalid pairing response")
	}
	context := sha256.Sum256([]byte("easyprivacy.pairing.v2\n" + begin.ID + "\n" + address + "\n" + name + "\n" + base64.StdEncoding.EncodeToString(pub) + "\n" + begin.Pin))
	exchange, err := pake.Start(0, code, context)
	if err != nil {
		return empty, err
	}
	defer exchange.Close()
	key, err := exchange.Finish(begin.Message)
	if err != nil {
		return empty, err
	}
	defer clear(key)
	var finish struct {
		ID      string    `json:"device_id"`
		Proof   []byte    `json:"proof"`
		Expires time.Time `json:"expires_at"`
	}
	if err = client.Request("POST", "/api/v1/pairing/finish", "", map[string]any{"exchange_id": begin.ID, "message": exchange.Message, "proof": proof(key, "app", context, identity.DeviceID)}, &finish); err != nil {
		return empty, err
	}
	if finish.ID != identity.DeviceID || !hmac.Equal(finish.Proof, proof(key, "core", context, identity.DeviceID)) || !time.Now().Before(finish.Expires) {
		return empty, errors.New("pairing code did not verify this core")
	}
	identity.Fingerprint = begin.Pin
	client.Identity = identity // Passwords are sent only on a fresh pinned TLS connection.
	var enrolled struct {
		ID string `json:"device_id"`
	}
	if err = client.Request("POST", "/api/v1/pairing/enroll", "", map[string]any{"exchange_id": begin.ID, "proof": proof(key, "enroll", context, identity.DeviceID), "username": username, "password": password}, &enrolled); err != nil {
		return empty, err
	}
	if enrolled.ID != identity.DeviceID {
		return empty, errors.New("core returned another device identity")
	}
	return identity, nil
}
func (c Client) Login() (string, error) {
	private, err := c.Identity.PrivateKey()
	if err != nil {
		return "", err
	}
	defer clear(private)
	var challenge struct {
		ID string `json:"challenge_id"`
	}
	if err = c.Request("POST", "/api/v1/device/challenge", "", map[string]string{"device_id": c.Identity.DeviceID}, &challenge); err != nil {
		return "", err
	}
	if !vpn.ValidID(challenge.ID) {
		return "", errors.New("invalid core challenge")
	}
	signature := ed25519.Sign(private, []byte("easyprivacy.device-login.v1\n"+c.Identity.Fingerprint+"\n"+c.Identity.DeviceID+"\n"+challenge.ID))
	var session struct {
		Token string `json:"access_token"`
	}
	err = c.Request("POST", "/api/v1/device/login", "", map[string]any{"device_id": c.Identity.DeviceID, "challenge_id": challenge.ID, "signature": signature}, &session)
	if err == nil && !vpn.ValidID(session.Token) {
		return "", errors.New("invalid core session")
	}
	return session.Token, err
}
