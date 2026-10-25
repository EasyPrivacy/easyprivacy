package link

import (
	"crypto/ed25519"
	"errors"
	"sync"
	"time"

	"github.com/easyprivacy/easyprivacy/core/internal/vpn"
)

// SessionClient retains only this node's in-memory Core session. DeviceKey still
// fetches authoritative paired-device records on every call; no authorization
// record is cached. A single synchronized login also bounds concurrent retries.
type SessionClient struct {
	client  Client
	mu      sync.Mutex
	token   string
	closed  bool
	retryAt time.Time
	lastErr error
}

func NewSessionClient(identity Identity) *SessionClient {
	return &SessionClient{client: Client{Identity: identity}}
}

func (c *SessionClient) session() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return "", errors.New("Core session is closed")
	}
	if c.token != "" {
		return c.token, nil
	}
	if c.lastErr != nil && time.Now().Before(c.retryAt) {
		return "", c.lastErr
	}
	token, err := c.client.Login()
	if err != nil {
		// Failed sign-ins share Core's finite per-IP budget. Concurrent file
		// operations and lease renewal must not repeatedly consume that budget.
		c.retryAt, c.lastErr = time.Now().Add(time.Minute), err
		return "", err
	}
	c.token, c.lastErr = token, nil
	return token, nil
}

func (c *SessionClient) Request(method, path string, input, output any) error {
	token, err := c.session()
	if err != nil {
		return err
	}
	err = c.client.Request(method, path, token, input, output)
	var response *HTTPError
	if !errors.As(err, &response) || (response.Code != 401 && response.Code != 403) {
		return err
	}
	// Core uses 401 or 403 for an expired/revoked paired-device session. Retry
	// once after renewing; do not invalidate another goroutine's newer session.
	c.mu.Lock()
	if c.token == token {
		c.token = ""
	}
	c.mu.Unlock()
	token, err = c.session()
	if err != nil {
		return err
	}
	return c.client.Request(method, path, token, input, output)
}

func (c *SessionClient) DeviceKey(id string) (ed25519.PublicKey, error) {
	if !vpn.ValidID(id) {
		return nil, errors.New("invalid paired device")
	}
	var response struct {
		Devices []struct {
			ID        string `json:"id"`
			PublicKey []byte `json:"public_key"`
			Revoked   bool   `json:"revoked"`
		} `json:"devices"`
	}
	if err := c.Request("GET", "/api/v1/devices", nil, &response); err != nil {
		return nil, err
	}
	for _, device := range response.Devices {
		if device.ID == id && !device.Revoked && len(device.PublicKey) == ed25519.PublicKeySize {
			return ed25519.PublicKey(device.PublicKey), nil
		}
	}
	return nil, errors.New("device is revoked or unknown")
}

func (c *SessionClient) Close() {
	c.mu.Lock()
	token := c.token
	c.closed, c.token = true, ""
	c.mu.Unlock()
	if token != "" {
		_ = c.client.Request("POST", "/api/v1/logout", token, nil, nil)
	}
}
