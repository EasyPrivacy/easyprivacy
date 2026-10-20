package node

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const DefaultStateDir = "/var/lib/easyprivacy-node"
const PasswordIterations = 600000

var usernamePattern = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,64}$`)

type State struct {
	SchemaVersion  int    `json:"schema_version"`
	Name           string `json:"name"`
	Listen         string `json:"listen"`
	Username       string `json:"username"`
	Salt           []byte `json:"password_salt"`
	PasswordHash   []byte `json:"password_hash"`
	CertificatePEM string `json:"certificate_pem"`
	PrivateKeyPEM  string `json:"private_key_pem"`
}

func ValidUsername(value string) bool { return usernamePattern.MatchString(value) }

func ValidatePassword(value string) error {
	if !utf8.ValidString(value) || utf8.RuneCountInString(value) < 15 || len(value) > 1024 {
		return errors.New("use a password or passphrase of at least 15 characters (at most 1024 bytes)")
	}
	return nil
}

func NewState(name string, port int, username, password string) (*State, error) {
	if strings.TrimSpace(name) == "" || len(name) > 80 || strings.ContainsAny(name, "\r\n\x00") {
		return nil, errors.New("enter a core name between 1 and 80 characters")
	}
	if port < 1024 || port > 65535 {
		return nil, errors.New("choose a port between 1024 and 65535")
	}
	if !ValidUsername(username) {
		return nil, errors.New("username must contain 1–64 letters, numbers, underscores or hyphens")
	}
	if err := ValidatePassword(password); err != nil {
		return nil, err
	}
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return nil, err
	}
	hash, err := pbkdf2.Key(sha256.New, password, salt, PasswordIterations, 32)
	if err != nil {
		return nil, err
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	certificate := &x509.Certificate{
		SerialNumber: serial, Subject: pkix.Name{CommonName: "EasyPrivacy Core"},
		DNSNames: []string{"core.easyprivacy.invalid"}, NotBefore: now.Add(-5 * time.Minute),
		NotAfter: now.AddDate(2, 0, 0), KeyUsage: x509.KeyUsageDigitalSignature,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, certificate, certificate, &key.PublicKey, key)
	if err != nil {
		return nil, err
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return nil, err
	}
	return &State{SchemaVersion: 1, Name: strings.TrimSpace(name), Listen: net.JoinHostPort("", strconv.Itoa(port)),
		Username: username, Salt: salt, PasswordHash: hash,
		CertificatePEM: string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})),
		PrivateKeyPEM:  string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER})),
	}, nil
}

func (s *State) Certificate() (tls.Certificate, error) {
	cert, err := tls.X509KeyPair([]byte(s.CertificatePEM), []byte(s.PrivateKeyPEM))
	if err != nil {
		return tls.Certificate{}, errors.New("invalid core certificate or private key")
	}
	leaf, err := x509.ParseCertificate(cert.Certificate[0])
	if err != nil {
		return tls.Certificate{}, err
	}
	if time.Now().Before(leaf.NotBefore) || !time.Now().Before(leaf.NotAfter) {
		return tls.Certificate{}, errors.New("core certificate is outside its validity period; administrator action is required")
	}
	cert.Leaf = leaf
	return cert, nil
}

func (s *State) Fingerprint() string {
	block, _ := pem.Decode([]byte(s.CertificatePEM))
	if block == nil {
		return ""
	}
	sum := sha256.Sum256(block.Bytes)
	return "SHA256:" + strings.ToUpper(hex.EncodeToString(sum[:]))
}

func StatePath(dir string) string { return filepath.Join(dir, "core.json") }

// Setup creates a new installation only. It never replaces an existing identity.
// gid < 0 is for a private development directory; installed state is root-owned
// and readable only by the dedicated service group.
func SaveNew(dir string, state *State, gid int) error {
	if !filepath.IsAbs(dir) {
		return errors.New("state directory must be an absolute path")
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	info, err := os.Lstat(dir)
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0027 != 0 {
		return errors.New("state directory must be private and must not be a symbolic link")
	}
	if gid >= 0 {
		if err := os.Chown(dir, 0, gid); err != nil {
			return err
		}
		if err := os.Chmod(dir, 0750); err != nil {
			return err
		}
	}
	raw, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}
	temp, err := os.CreateTemp(dir, ".setup-*")
	if err != nil {
		return err
	}
	defer os.Remove(temp.Name())
	defer temp.Close()
	if _, err := temp.Write(append(raw, '\n')); err != nil {
		return err
	}
	if gid >= 0 {
		if err := temp.Chown(0, gid); err != nil {
			return err
		}
		if err := temp.Chmod(0640); err != nil {
			return err
		}
	}
	if err := temp.Sync(); err != nil {
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	// A hard link publishes the complete record atomically without overwriting.
	if err := os.Link(temp.Name(), StatePath(dir)); err != nil {
		return fmt.Errorf("publish core identity (existing installations are preserved): %w", err)
	}
	return nil
}

func Load(dir string) (*State, error) {
	for _, path := range []string{dir, StatePath(dir)} {
		info, err := os.Lstat(path)
		if err != nil {
			return nil, fmt.Errorf("core is not configured or state is inaccessible; run setup or restore your state: %w", err)
		}
		if info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0027 != 0 {
			return nil, errors.New("core state must not be symlinked, group-writable, or accessible to other users")
		}
	}
	file, err := os.Open(StatePath(dir))
	if err != nil {
		return nil, err
	}
	defer file.Close()
	decoder := json.NewDecoder(io.LimitReader(file, 16385))
	decoder.DisallowUnknownFields()
	var state State
	if err := decoder.Decode(&state); err != nil {
		return nil, fmt.Errorf("read core state: %w", err)
	}
	var extra any
	if decoder.Decode(&extra) != io.EOF {
		return nil, errors.New("unexpected trailing or excessive core state")
	}
	if state.SchemaVersion != 1 || !ValidUsername(state.Username) || len(state.Salt) != 16 || len(state.PasswordHash) != 32 || strings.TrimSpace(state.Name) == "" {
		return nil, errors.New("invalid core state")
	}
	host, textPort, err := net.SplitHostPort(state.Listen)
	port, portErr := strconv.Atoi(textPort)
	if err != nil || portErr != nil || host != "" || port < 1024 || port > 65535 {
		return nil, errors.New("invalid core listening port")
	}
	if _, err := state.Certificate(); err != nil {
		return nil, err
	}
	return &state, nil
}
