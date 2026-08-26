package device

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

const (
	schemaVersion  = 1
	credentialType = "epd1"
	maxDeviceName  = 128
)

var ErrDeviceNotFound = errors.New("device not found")

type Store struct {
	root       string
	activeDir  string
	revokedDir string
	now        func() time.Time
}

type Credential struct {
	Device Record
	Token  string
}

type Record struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	CreatedAt time.Time `json:"createdAt"`
	Revoked   bool      `json:"revoked"`
}

type storedRecord struct {
	SchemaVersion int       `json:"schemaVersion"`
	ID            string    `json:"id"`
	Name          string    `json:"name"`
	CreatedAt     time.Time `json:"createdAt"`
	TokenSHA256   string    `json:"tokenSha256"`
}

func Open(stateDir string) (*Store, error) {
	if strings.TrimSpace(stateDir) == "" {
		return nil, errors.New("state directory is required")
	}
	root := filepath.Join(stateDir, "devices")
	store := &Store{
		root:       root,
		activeDir:  filepath.Join(root, "active"),
		revokedDir: filepath.Join(root, "revoked"),
		now:        time.Now,
	}
	for _, directory := range []string{store.root, store.activeDir, store.revokedDir} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			return nil, fmt.Errorf("create device state directory: %w", err)
		}
		if err := os.Chmod(directory, 0o700); err != nil {
			return nil, fmt.Errorf("secure device state directory: %w", err)
		}
	}
	return store, nil
}

func (s *Store) Enroll(name string) (Credential, error) {
	name, err := normalizeName(name)
	if err != nil {
		return Credential{}, err
	}
	for attempt := 0; attempt < 4; attempt++ {
		id, err := randomEncoded(16)
		if err != nil {
			return Credential{}, err
		}
		secret, err := randomEncoded(32)
		if err != nil {
			return Credential{}, err
		}
		token := strings.Join([]string{credentialType, id, secret}, ".")
		digest := sha256.Sum256([]byte(token))
		record := storedRecord{
			SchemaVersion: schemaVersion,
			ID:            id,
			Name:          name,
			CreatedAt:     s.now().UTC(),
			TokenSHA256:   base64.RawURLEncoding.EncodeToString(digest[:]),
		}
		err = writeNewRecord(filepath.Join(s.activeDir, id+".json"), record)
		if errors.Is(err, os.ErrExist) {
			continue
		}
		if err != nil {
			return Credential{}, err
		}
		return Credential{
			Device: publicRecord(record, false),
			Token:  token,
		}, nil
	}
	return Credential{}, errors.New("could not allocate a unique device identifier")
}

func (s *Store) Authenticate(ctx context.Context, token string) (bool, error) {
	select {
	case <-ctx.Done():
		return false, ctx.Err()
	default:
	}
	id, ok := credentialID(token)
	if !ok {
		return false, nil
	}
	record, err := readRecord(filepath.Join(s.activeDir, id+".json"), id)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("read device credential: %w", err)
	}
	expected, err := base64.RawURLEncoding.DecodeString(record.TokenSHA256)
	if err != nil || len(expected) != sha256.Size {
		return false, errors.New("device credential digest is invalid")
	}
	provided := sha256.Sum256([]byte(token))
	return subtle.ConstantTimeCompare(expected, provided[:]) == 1, nil
}

func (s *Store) Revoke(id string) error {
	if !validID(id) {
		return errors.New("invalid device identifier")
	}
	activePath := filepath.Join(s.activeDir, id+".json")
	revokedPath := filepath.Join(s.revokedDir, id+".json")
	if _, err := os.Stat(revokedPath); err == nil {
		return ErrDeviceNotFound
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("check revoked device: %w", err)
	}
	if err := os.Rename(activePath, revokedPath); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return ErrDeviceNotFound
		}
		return fmt.Errorf("revoke device: %w", err)
	}
	return nil
}

func (s *Store) List() ([]Record, error) {
	var records []Record
	for _, group := range []struct {
		directory string
		revoked   bool
	}{
		{directory: s.activeDir},
		{directory: s.revokedDir, revoked: true},
	} {
		entries, err := os.ReadDir(group.directory)
		if err != nil {
			return nil, fmt.Errorf("list devices: %w", err)
		}
		for _, entry := range entries {
			if entry.IsDir() || filepath.Ext(entry.Name()) != ".json" {
				continue
			}
			id := strings.TrimSuffix(entry.Name(), ".json")
			record, err := readRecord(filepath.Join(group.directory, entry.Name()), id)
			if err != nil {
				return nil, fmt.Errorf("list device %s: %w", id, err)
			}
			records = append(records, publicRecord(record, group.revoked))
		}
	}
	sort.Slice(records, func(i, j int) bool {
		if records[i].CreatedAt.Equal(records[j].CreatedAt) {
			return records[i].ID < records[j].ID
		}
		return records[i].CreatedAt.Before(records[j].CreatedAt)
	})
	return records, nil
}

func writeNewRecord(path string, record storedRecord) error {
	contents, err := json.MarshalIndent(record, "", "  ")
	if err != nil {
		return fmt.Errorf("encode device record: %w", err)
	}
	contents = append(contents, '\n')
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	cleanup := true
	defer func() {
		_ = file.Close()
		if cleanup {
			_ = os.Remove(path)
		}
	}()
	if err := os.Chmod(path, 0o600); err != nil {
		return fmt.Errorf("secure device record: %w", err)
	}
	if _, err := file.Write(contents); err != nil {
		return fmt.Errorf("write device record: %w", err)
	}
	if err := file.Sync(); err != nil {
		return fmt.Errorf("sync device record: %w", err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("close device record: %w", err)
	}
	cleanup = false
	return nil
}

func readRecord(path, expectedID string) (storedRecord, error) {
	contents, err := os.ReadFile(path)
	if err != nil {
		return storedRecord{}, err
	}
	var record storedRecord
	if err := json.Unmarshal(contents, &record); err != nil {
		return storedRecord{}, fmt.Errorf("decode record: %w", err)
	}
	if record.SchemaVersion != schemaVersion || record.ID != expectedID || !validID(record.ID) {
		return storedRecord{}, errors.New("device record identity is invalid")
	}
	if _, err := normalizeName(record.Name); err != nil {
		return storedRecord{}, fmt.Errorf("device record name: %w", err)
	}
	if record.CreatedAt.IsZero() {
		return storedRecord{}, errors.New("device record creation time is missing")
	}
	digest, err := base64.RawURLEncoding.DecodeString(record.TokenSHA256)
	if err != nil || len(digest) != sha256.Size {
		return storedRecord{}, errors.New("device record digest is invalid")
	}
	return record, nil
}

func publicRecord(record storedRecord, revoked bool) Record {
	return Record{
		ID:        record.ID,
		Name:      record.Name,
		CreatedAt: record.CreatedAt,
		Revoked:   revoked,
	}
}

func credentialID(token string) (string, bool) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 || parts[0] != credentialType || !validID(parts[1]) {
		return "", false
	}
	secret, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || len(secret) != 32 {
		return "", false
	}
	return parts[1], true
}

func validID(id string) bool {
	decoded, err := base64.RawURLEncoding.DecodeString(id)
	return err == nil && len(decoded) == 16 &&
		base64.RawURLEncoding.EncodeToString(decoded) == id
}

func normalizeName(name string) (string, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return "", errors.New("device name is required")
	}
	if !utf8.ValidString(name) || utf8.RuneCountInString(name) > maxDeviceName {
		return "", fmt.Errorf("device name must be at most %d characters", maxDeviceName)
	}
	for _, character := range name {
		if unicode.IsControl(character) || unicode.Is(unicode.Cf, character) {
			return "", errors.New("device name cannot contain control or formatting characters")
		}
	}
	return name, nil
}

func randomEncoded(size int) (string, error) {
	value := make([]byte, size)
	if _, err := rand.Read(value); err != nil {
		return "", fmt.Errorf("generate device credential: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(value), nil
}
