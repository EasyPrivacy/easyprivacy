package node

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
)

type Device struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	PublicKey []byte    `json:"public_key"`
	CreatedAt time.Time `json:"created_at"`
	Revoked   bool      `json:"revoked"`
}

type DeviceStore struct {
	mu      sync.Mutex
	path    string
	devices map[string]Device
}

func validDeviceName(name string) bool {
	return strings.TrimSpace(name) != "" && len(name) <= 80 && utf8.ValidString(name) && !strings.ContainsFunc(name, unicode.IsControl)
}

func deviceID(key []byte) string { sum := sha256.Sum256(key); return hex.EncodeToString(sum[:]) }

func OpenDeviceStore(directory string) (*DeviceStore, error) {
	s := &DeviceStore{devices: make(map[string]Device)}
	if directory == "" {
		return s, nil
	}
	if err := os.MkdirAll(directory, 0700); err != nil {
		return nil, err
	}
	info, err := os.Lstat(directory)
	if err != nil || !info.IsDir() || info.Mode().Perm() != 0700 {
		return nil, errors.New("device directory must be a private regular directory with mode 0700")
	}
	s.path = filepath.Join(directory, "devices.json")
	info, err = os.Lstat(s.path)
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0600 {
		return nil, errors.New("device records must be a regular file with mode 0600")
	}
	f, err := os.Open(s.path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	decoder := json.NewDecoder(io.LimitReader(f, 131073))
	decoder.DisallowUnknownFields()
	var record struct {
		Schema  int      `json:"schema"`
		Devices []Device `json:"devices"`
	}
	if err := decoder.Decode(&record); err != nil {
		return nil, err
	}
	var extra any
	if decoder.Decode(&extra) != io.EOF || record.Schema != 1 || len(record.Devices) > 128 {
		return nil, errors.New("invalid device records")
	}
	for _, d := range record.Devices {
		if len(d.PublicKey) != ed25519.PublicKeySize || d.ID != deviceID(d.PublicKey) || !validDeviceName(d.Name) || d.CreatedAt.IsZero() {
			return nil, errors.New("invalid device identity")
		}
		if _, exists := s.devices[d.ID]; exists {
			return nil, errors.New("duplicate device identity")
		}
		s.devices[d.ID] = d
	}
	return s, nil
}

func (s *DeviceStore) saveLocked() error {
	if s.path == "" {
		return nil
	}
	record := struct {
		Schema  int      `json:"schema"`
		Devices []Device `json:"devices"`
	}{Schema: 1, Devices: s.listLocked()}
	raw, err := json.Marshal(record)
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(s.path), ".devices-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	defer f.Close()
	if _, err := f.Write(raw); err != nil {
		return err
	}
	if err := f.Sync(); err != nil {
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := os.Rename(f.Name(), s.path); err != nil {
		return err
	}
	if dir, err := os.Open(filepath.Dir(s.path)); err == nil {
		defer dir.Close()
		_ = dir.Sync()
	}
	return nil
}

func (s *DeviceStore) Add(name string, publicKey []byte) (Device, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !validDeviceName(name) || len(publicKey) != ed25519.PublicKeySize {
		return Device{}, errors.New("invalid device")
	}
	d := Device{ID: deviceID(publicKey), Name: strings.TrimSpace(name), PublicKey: append([]byte(nil), publicKey...), CreatedAt: time.Now().UTC()}
	if _, exists := s.devices[d.ID]; exists {
		return Device{}, errors.New("device key is already registered; generate a fresh device key")
	}
	if len(s.devices) >= 128 {
		return Device{}, errors.New("device record limit reached")
	}
	s.devices[d.ID] = d
	if err := s.saveLocked(); err != nil {
		delete(s.devices, d.ID)
		return Device{}, err
	}
	return d, nil
}

func (s *DeviceStore) Active(id string) (Device, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, ok := s.devices[id]
	return d, ok && !d.Revoked
}
func (s *DeviceStore) listLocked() []Device {
	list := make([]Device, 0, len(s.devices))
	for _, d := range s.devices {
		list = append(list, d)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].CreatedAt.Before(list[j].CreatedAt) })
	return list
}
func (s *DeviceStore) List() []Device { s.mu.Lock(); defer s.mu.Unlock(); return s.listLocked() }
func (s *DeviceStore) Revoke(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, ok := s.devices[id]
	if !ok {
		return errors.New("device not found")
	}
	if d.Revoked {
		return nil
	}
	before := d
	d.Revoked = true
	s.devices[id] = d
	if err := s.saveLocked(); err != nil {
		s.devices[id] = before
		return err
	}
	return nil
}
