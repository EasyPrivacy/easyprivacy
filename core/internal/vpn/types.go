package vpn

import (
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const Interface = "epwg0"
const Socket = "/run/easyprivacy-vpn/control.sock"
const Directory = "/var/lib/easyprivacy-vpn"
const IPv6Prefix = "fd6e:7072:6976::"

type Config struct {
	Schema      int      `json:"schema"`
	PrivateOnly bool     `json:"private_only,omitempty"`
	Name        string   `json:"name"`
	Endpoint    string   `json:"endpoint"`
	Port        int      `json:"port"`
	Subnet      string   `json:"subnet"`
	Uplink      string   `json:"uplink"`
	DNS         []string `json:"dns"`
	PrivateKey  string   `json:"private_key"`
}
type Exit struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Ready   bool   `json:"ready"`
	Message string `json:"message,omitempty"`
}
type Profile struct {
	ExitID           string   `json:"exit_id"`
	ExitName         string   `json:"exit_name"`
	PublicKey        string   `json:"public_key"`
	Endpoint         string   `json:"endpoint"`
	Address          string   `json:"address"`
	AddressV6        string   `json:"address_v6"`
	DNS              []string `json:"dns"`
	AllowedIPs       []string `json:"allowed_ips"`
	MTU              int      `json:"mtu"`
	Keepalive        int      `json:"keepalive"`
	ManagementRoutes []string `json:"management_routes,omitempty"`
}

const PrivatePurpose = "private-services"

type PrivateProfile struct {
	Protocol  int           `json:"protocol"`
	PublicKey string        `json:"public_key"`
	Endpoint  string        `json:"endpoint"`
	Address   string        `json:"address"`
	Subnet    string        `json:"subnet"`
	MTU       int           `json:"mtu"`
	Keepalive int           `json:"keepalive"`
	Probe     PrivateTarget `json:"probe"`
}

const PrivateProbePort = 41930
const FilesReceiverPort = 41931

type PrivateTarget struct {
	Kind      string     `json:"kind,omitempty"`
	ID        string     `json:"id"`
	Name      string     `json:"name"`
	DeviceID  string     `json:"device_id,omitempty"`
	Address   string     `json:"address"`
	Port      int        `json:"port"`
	ExpiresAt *time.Time `json:"expires_at,omitempty"`
}

type Peer struct {
	Purpose    string `json:"purpose,omitempty"`
	DeviceID   string `json:"device_id"`
	PublicKey  string `json:"public_key"`
	Host       int    `json:"host"`
	ExitID     string `json:"exit_id,omitempty"`
	Service    bool   `json:"service,omitempty"`
	Name       string `json:"name,omitempty"`
	Management string `json:"management_addresses,omitempty"`
}

func ManagementRoutes(addresses string) ([]string, error) {
	if addresses == "" {
		return nil, nil
	}
	parts := strings.Split(addresses, ",")
	if len(parts) > 16 {
		return nil, errors.New("choose at most sixteen management addresses")
	}
	seen := map[string]bool{}
	routes := make([]string, 0, len(parts))
	for _, value := range parts {
		addr, err := netip.ParseAddr(strings.TrimSpace(value))
		if err != nil || !addr.Is4() || !addr.IsPrivate() || seen[addr.String()] {
			return nil, errors.New("management destinations must be distinct private IPv4 addresses, without ports")
		}
		seen[addr.String()] = true
		routes = append(routes, addr.String()+"/32")
	}
	return routes, nil
}

// ServiceProfile deliberately routes only the overlay back to the VPS. The
// site's own Internet uplink (including its VPN transport) remains unchanged.
type ServiceProfile struct {
	Profile
	Subnet string `json:"subnet"`
}
type Status struct {
	Active        bool   `json:"active"`
	LastHandshake int64  `json:"last_handshake"`
	Received      uint64 `json:"received"`
	Sent          uint64 `json:"sent"`
}

func ValidID(id string) bool {
	b, e := hex.DecodeString(id)
	return e == nil && len(b) == 32 && id == strings.ToLower(id)
}
func Key(value string) ([]byte, error) {
	b, e := base64.StdEncoding.DecodeString(value)
	if e != nil || len(b) != 32 || base64.StdEncoding.EncodeToString(b) != value {
		return nil, errors.New("invalid WireGuard key")
	}
	var nonzero byte
	for _, v := range b {
		nonzero |= v
	}
	if nonzero == 0 {
		return nil, errors.New("zero WireGuard key")
	}
	return b, nil
}
func GenerateKey() (string, error) {
	k, e := ecdh.X25519().GenerateKey(rand.Reader)
	if e != nil {
		return "", e
	}
	return base64.StdEncoding.EncodeToString(k.Bytes()), nil
}
func (c Config) PublicKey() string {
	b, _ := Key(c.PrivateKey)
	k, e := ecdh.X25519().NewPrivateKey(b)
	if e != nil {
		return ""
	}
	return base64.StdEncoding.EncodeToString(k.PublicKey().Bytes())
}
func (c Config) Validate() error {
	if (c.Schema != 1 && c.Schema != 2) || (c.PrivateOnly && c.Schema != 2) || strings.TrimSpace(c.Name) == "" || len(c.Name) > 80 || strings.ContainsAny(c.Name, "\r\n\x00") {
		return errors.New("invalid VPN name or schema")
	}
	h, p, e := net.SplitHostPort(c.Endpoint)
	if e != nil || h == "" || strings.ContainsAny(h, "\r\n\x00 /\\@") || p != fmt.Sprint(c.Port) || c.Port < 1024 || c.Port > 65535 {
		return errors.New("use a VPN endpoint host:port with a port from 1024 to 65535")
	}
	if _, err := netip.ParseAddr(h); err != nil {
		if len(h) > 253 || !regexp.MustCompile(`^[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?\.?$`).MatchString(h) || strings.Contains(h, "..") {
			return errors.New("enter only the public hostname or IP, without a port or URL")
		}
	}
	n, e := netip.ParsePrefix(c.Subnet)
	if e != nil || !n.Addr().Is4() || !n.Addr().IsPrivate() || n.Bits() != 24 || n != n.Masked() {
		return errors.New("choose a private IPv4 /24 network, for example 10.87.0.0/24")
	}
	if c.PrivateOnly {
		if c.Uplink != "" || len(c.DNS) != 0 {
			return errors.New("private-only networking cannot configure an Internet uplink or device DNS")
		}
		_, e = Key(c.PrivateKey)
		return e
	}
	if !regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,14}$`).MatchString(c.Uplink) || c.Uplink == Interface || strings.HasPrefix(c.Uplink, "wg") {
		return errors.New("select the physical Internet uplink interface")
	}
	if len(c.DNS) == 0 || len(c.DNS) > 3 {
		return errors.New("set one to three IPv4 DNS servers")
	}
	for _, d := range c.DNS {
		a, e := netip.ParseAddr(d)
		if e != nil || !a.Is4() || a.IsUnspecified() || a.IsMulticast() {
			return errors.New("invalid DNS address")
		}
	}
	_, e = Key(c.PrivateKey)
	return e
}
func (c Config) Address(host int) string {
	n, _ := netip.ParsePrefix(c.Subnet)
	a := n.Addr().As4()
	a[3] = byte(host)
	return netip.AddrFrom4(a).String() + "/32"
}
func (c Config) Profile(p Peer) Profile {
	return Profile{ExitID: "vps", ExitName: c.Name, PublicKey: c.PublicKey(), Endpoint: c.Endpoint, Address: c.Address(p.Host), AddressV6: fmt.Sprintf("%s%x/128", IPv6Prefix, p.Host), DNS: c.DNS, AllowedIPs: []string{"0.0.0.0/0", "::/0"}, MTU: 1280, Keepalive: 25}
}
func LoadConfig(dir string) (Config, error) {
	var c Config
	e := ReadPrivate(filepath.Join(dir, "vpn.json"), &c)
	if e == nil {
		e = c.Validate()
	}
	return c, e
}
func ReadPrivate(path string, value any) error {
	f, e := os.Lstat(path)
	if e != nil {
		return e
	}
	if !f.Mode().IsRegular() || f.Mode().Perm() != 0600 || f.Size() > 131072 {
		return errors.New("VPN state must be a private regular file")
	}
	b, e := os.ReadFile(path)
	if e != nil {
		return e
	}
	d := json.NewDecoder(strings.NewReader(string(b)))
	d.DisallowUnknownFields()
	if e = d.Decode(value); e != nil {
		return e
	}
	var extra any
	if d.Decode(&extra) == io.EOF {
		return nil
	}
	return errors.New("invalid VPN state")
}
func SavePrivate(path string, value any) error {
	raw, e := json.Marshal(value)
	if e != nil {
		return e
	}
	dir := filepath.Dir(path)
	f, e := os.CreateTemp(dir, ".vpn-*")
	if e != nil {
		return e
	}
	name := f.Name()
	defer os.Remove(name)
	if e = f.Chmod(0600); e == nil {
		_, e = f.Write(raw)
	}
	if e == nil {
		e = f.Sync()
	}
	closeErr := f.Close()
	if e == nil {
		e = closeErr
	}
	if e != nil {
		return e
	}
	if e = os.Rename(name, path); e != nil {
		return e
	}
	d, e := os.Open(dir)
	if e == nil {
		e = d.Sync()
		d.Close()
	}
	return e
}
