// Package drive implements the private, explicitly transferred cloud volume.
package drive

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
)

const MaxFileBytes int64 = 1 << 30

var idPattern = regexp.MustCompile(`^[0-9a-f]{32}$`)
var hashPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)
var pinPattern = regexp.MustCompile(`^SHA256:[0-9A-F]{64}$`)
var reservedName = regexp.MustCompile(`^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$`)

type Command struct {
	Op     string `json:"op"`
	Volume string `json:"volume"`
	Path   string `json:"path"`
	Target string `json:"target"`
	Cursor string `json:"cursor"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
}

func ValidPath(value string, root bool) bool {
	if value == "" {
		return root
	}
	if !utf8.ValidString(value) || len(value) > 2048 {
		return false
	}
	parts := strings.Split(value, "/")
	if len(parts) > 64 {
		return false
	}
	for _, part := range parts {
		if part == "" || part == "." || part == ".." || len(part) > 180 || strings.TrimSpace(part) != part || strings.HasSuffix(part, ".") || strings.EqualFold(part, ".easyprivacy-drive") || strings.ContainsAny(part, `\:<>"|?*`) || strings.ContainsFunc(part, unicode.IsControl) || reservedName.MatchString(strings.ToUpper(strings.Split(part, ".")[0])) {
			return false
		}
	}
	return true
}
func (c Command) Validate() error {
	switch c.Op {
	case "volumes", "list", "download", "upload", "mkdir", "move", "delete":
	default:
		return errors.New("unsupported Drive operation")
	}
	if (c.Op == "volumes" && (c.Volume != "" || c.Path != "")) || (c.Op != "volumes" && !idPattern.MatchString(c.Volume)) || !ValidPath(c.Path, c.Op == "list" || c.Op == "volumes") {
		return errors.New("invalid Drive location")
	}
	if c.Op == "move" {
		if !ValidPath(c.Target, false) {
			return errors.New("invalid destination")
		}
	} else if c.Target != "" {
		return errors.New("unexpected destination")
	}
	if c.Op == "list" {
		if c.Cursor != "" && (!ValidPath(c.Cursor, false) || strings.Contains(c.Cursor, "/")) {
			return errors.New("invalid cursor")
		}
	} else if c.Cursor != "" {
		return errors.New("unexpected cursor")
	}
	if c.Op == "upload" {
		if c.Size < 0 || c.Size > MaxFileBytes || !hashPattern.MatchString(c.SHA256) {
			return errors.New("invalid upload")
		}
	} else if c.Size != 0 || c.SHA256 != "" {
		return errors.New("unexpected payload")
	}
	return nil
}

type Authorization struct {
	Command   Command `json:"command"`
	Core      string  `json:"core"`
	Device    string  `json:"device"`
	Node      string  `json:"node"`
	Nonce     string  `json:"nonce"`
	Expires   int64   `json:"expires"`
	Identity  []byte  `json:"identity"`
	Signature []byte  `json:"signature"`
}

func (a Authorization) Claim() (string, error) {
	if err := a.Command.Validate(); err != nil {
		return "", err
	}
	if !pinPattern.MatchString(a.Core) || !hashPattern.MatchString(a.Device) || !hashPattern.MatchString(a.Node) || a.Device == a.Node || !hashPattern.MatchString(a.Nonce) || a.Expires < 1 {
		return "", errors.New("invalid authorization")
	}
	field := func(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }
	c := a.Command
	return fmt.Sprintf("EasyPrivacy Drive request v1\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%d\n%s\n%s\n%d", a.Core, a.Device, a.Node, c.Op, c.Volume, field(c.Path), field(c.Target), field(c.Cursor), c.Size, c.SHA256, a.Nonce, a.Expires), nil
}

// Lookup must fetch current device authorization through the pinned Core.
type Verifier struct {
	Core, Node string
	Lookup     func(string) (ed25519.PublicKey, error)
	mu         sync.Mutex
	nonces     map[string]int64
}

func (v *Verifier) Verify(a Authorization) error {
	claim, err := a.Claim()
	now := time.Now().Unix()
	sum := sha256.Sum256(a.Identity)
	if err != nil || a.Core != v.Core || a.Node != v.Node || a.Expires <= now || a.Expires > now+150 || len(a.Identity) != ed25519.PublicKeySize || hex.EncodeToString(sum[:]) != a.Device || !ed25519.Verify(a.Identity, []byte(claim), a.Signature) {
		return errors.New("Drive authorization is invalid or expired")
	}
	key, err := v.Lookup(a.Device)
	if err != nil || !ed25519.PublicKey(a.Identity).Equal(key) {
		return errors.New("paired device authorization is unavailable or revoked")
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	if v.nonces == nil {
		v.nonces = map[string]int64{}
	}
	for k, expires := range v.nonces {
		if expires <= now {
			delete(v.nonces, k)
		}
	}
	id := a.Device + ":" + a.Nonce
	if _, exists := v.nonces[id]; exists || len(v.nonces) >= 4096 {
		return errors.New("Drive authorization was already used or is busy")
	}
	v.nonces[id] = a.Expires
	return nil
}
func ReadFrame(r io.Reader, value any, max uint32) error {
	var size [4]byte
	if _, err := io.ReadFull(r, size[:]); err != nil {
		return err
	}
	n := binary.BigEndian.Uint32(size[:])
	if n == 0 || n > max {
		return errors.New("invalid Drive frame")
	}
	raw := make([]byte, n)
	if _, err := io.ReadFull(r, raw); err != nil {
		return err
	}
	d := json.NewDecoder(strings.NewReader(string(raw)))
	d.DisallowUnknownFields()
	if err := d.Decode(value); err != nil {
		return err
	}
	var extra any
	if d.Decode(&extra) != io.EOF {
		return errors.New("invalid Drive frame")
	}
	return nil
}
func WriteFrame(w io.Writer, value any) error {
	raw, err := json.Marshal(value)
	if err != nil {
		return err
	}
	if len(raw) > 65536 {
		return errors.New("Drive metadata limit exceeded")
	}
	var size [4]byte
	binary.BigEndian.PutUint32(size[:], uint32(len(raw)))
	if _, err = w.Write(size[:]); err != nil {
		return err
	}
	_, err = w.Write(raw)
	return err
}
