package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"os/signal"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	runtime "github.com/easyprivacy/easyprivacy/core-runtime"
	"github.com/easyprivacy/easyprivacy/core/internal/drive"
	"github.com/easyprivacy/easyprivacy/core/internal/link"
	"github.com/easyprivacy/easyprivacy/core/internal/vpn"
	"golang.org/x/term"
)

const driveDir = "/var/lib/easyprivacy-drive"

type driveConfig struct {
	Schema     int                  `json:"schema"`
	Name       string               `json:"name"`
	Identity   link.Identity        `json:"identity"`
	PrivateKey string               `json:"private_key"`
	Volumes    []drive.VolumeConfig `json:"volumes"`
}

func loadDrive() (driveConfig, error) {
	var c driveConfig
	path := filepath.Join(driveDir, "drive.json")
	info, err := os.Lstat(path)
	if err != nil {
		return c, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0600 {
		return c, errors.New("Drive settings must be a private regular file")
	}
	f, err := os.Open(path)
	if err != nil {
		return c, err
	}
	defer f.Close()
	decoder := json.NewDecoder(io.LimitReader(f, 16385))
	decoder.DisallowUnknownFields()
	if err = decoder.Decode(&c); err != nil {
		return c, err
	}
	var extra any
	if decoder.Decode(&extra) != io.EOF {
		return c, errors.New("invalid Drive settings")
	}
	if c.Schema != 1 || !drive.ValidPath(c.Name, false) || strings.Contains(c.Name, "/") {
		return c, errors.New("invalid Drive configuration")
	}
	private, err := c.Identity.PrivateKey()
	clear(private)
	if err != nil {
		return c, err
	}
	if _, err = vpn.Key(c.PrivateKey); err != nil {
		return c, err
	}
	return c, nil
}
func driveAccount() (int, int, error) {
	u, err := user.Lookup("easyprivacy-drive")
	if err != nil {
		return 0, 0, errors.New("install the updated node package before configuring Drive")
	}
	uid, e1 := strconv.Atoi(u.Uid)
	gid, e2 := strconv.Atoi(u.Gid)
	if e1 != nil || e2 != nil || uid == 0 || gid == 0 || u.HomeDir != driveDir {
		return 0, 0, errors.New("invalid Drive service account")
	}
	return uid, gid, nil
}
func saveDrive(c driveConfig) error {
	uid, gid, err := driveAccount()
	if err != nil {
		return err
	}
	if err = os.MkdirAll(driveDir, 0700); err != nil {
		return err
	}
	if info, err := os.Lstat(driveDir); err != nil || !info.IsDir() {
		return errors.New("invalid Drive settings directory")
	}
	if err = os.Chown(driveDir, uid, gid); err != nil {
		return err
	}
	if err = vpn.SavePrivate(filepath.Join(driveDir, "drive.json"), c); err != nil {
		return err
	}
	if err = os.Chown(filepath.Join(driveDir, "drive.json"), uid, gid); err != nil {
		return err
	}
	dropin := "/etc/systemd/system/easyprivacy-drive.service.d"
	if info, e := os.Lstat(dropin); e == nil && !info.IsDir() {
		return errors.New("invalid Drive service drop-in directory")
	}
	if err = os.MkdirAll(dropin, 0755); err != nil {
		return err
	}
	var unit strings.Builder
	unit.WriteString("[Service]\nReadWritePaths=" + driveDir)
	for _, v := range c.Volumes {
		unit.WriteString(" " + strconv.Quote(strings.ReplaceAll(v.Path, "%", "%%")))
	}
	unit.WriteString("\n")
	if err = os.WriteFile(filepath.Join(dropin, "storage.conf.tmp"), []byte(unit.String()), 0600); err != nil {
		return err
	}
	if err = os.Rename(filepath.Join(dropin, "storage.conf.tmp"), filepath.Join(dropin, "storage.conf")); err != nil {
		return err
	}
	return exec.Command("systemctl", "daemon-reload").Run()
}
func addDriveVolume(c *driveConfig, name, path string, quota int64) error {
	uid, gid, err := driveAccount()
	if err != nil {
		return err
	}
	if !filepath.IsAbs(path) || strings.ContainsAny(path, "\r\n\x00") || filepath.Dir(filepath.Clean(path)) == filepath.Clean(path) || quota < 1 || quota > (1<<60) || len(c.Volumes) >= 8 {
		return errors.New("choose an absolute data directory and positive capacity; at most eight locations")
	}
	path = filepath.Clean(path)
	if _, err = os.Lstat(path); errors.Is(err, os.ErrNotExist) {
		if err = os.Mkdir(path, 0700); err != nil {
			return err
		}
		if err = os.Chown(path, uid, gid); err != nil {
			return err
		}
	}
	canonical, err := filepath.EvalSymlinks(path)
	if err != nil || canonical != path {
		return errors.New("storage must be a regular directory at its resolved location")
	}
	if path == driveDir || strings.HasPrefix(path, driveDir+"/") || strings.HasPrefix(driveDir, path+"/") {
		return errors.New("choose data storage outside the Drive configuration directory")
	}
	for _, other := range c.Volumes {
		if path == other.Path || strings.HasPrefix(path, other.Path+"/") || strings.HasPrefix(other.Path, path+"/") {
			return errors.New("storage locations must not overlap")
		}
	}
	// Existing directories are never recursively re-owned or formatted.
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || int(stat.Uid) != uid || info.Mode().Perm()&0200 == 0 {
		return errors.New("give easyprivacy-drive ownership/write access to this storage directory first; existing data was not changed")
	}
	id := drive.Token()
	if saved, e := drive.StoredVolumeID(path); e == nil {
		id = saved
	} else if !errors.Is(e, os.ErrNotExist) {
		return e
	}
	v := drive.VolumeConfig{ID: id, Name: name, Path: path, Quota: quota}
	// Prepare with the eventual unprivileged service identity, not root-owned metadata.
	payload, err := json.Marshal(v)
	if err != nil {
		return err
	}
	process := exec.Command("/usr/bin/setpriv", "--reuid", strconv.Itoa(uid), "--regid", strconv.Itoa(gid), "--clear-groups", "/usr/bin/easyprivacy-node", "drive-prepare")
	process.Stdin = strings.NewReader(string(payload))
	process.Stdout = os.Stdout
	process.Stderr = os.Stderr
	if err = process.Run(); err != nil {
		return errors.New("could not initialize Drive storage; check service access permissions")
	}
	c.Volumes = append(c.Volumes, v)
	return saveDrive(*c)
}
func runDrive(action string, args []string) error {
	if action == "drive-prepare" {
		var c drive.VolumeConfig
		d := json.NewDecoder(io.LimitReader(os.Stdin, 4096))
		d.DisallowUnknownFields()
		if err := d.Decode(&c); err != nil {
			return err
		}
		return drive.PrepareVolume(c)
	}
	if action == "drive-serve" {
		return serveDrive()
	}
	if os.Geteuid() != 0 {
		return errors.New("run Drive setup/administration with sudo")
	}
	switch action {
	case "drive-setup":
		if len(args) != 0 {
			return errors.New("unexpected arguments")
		}
		return setupDrive()
	case "drive-volume-add":
		flags := flag.NewFlagSet(action, flag.ContinueOnError)
		name := flags.String("name", "Storage", "display name")
		path := flags.String("path", "", "existing mounted drive/directory or new folder")
		quota := flags.Int64("quota-gib", 0, "maximum GiB for this location")
		if err := flags.Parse(args); err != nil {
			return err
		}
		if flags.NArg() != 0 || *quota < 1 || *quota > 1<<30 {
			return errors.New("specify --path, --name and a positive --quota-gib")
		}
		c, err := loadDrive()
		if err != nil {
			return err
		}
		if err = addDriveVolume(&c, *name, *path, *quota*(1<<30)); err != nil {
			return err
		}
		if err = exec.Command("systemctl", "enable", "easyprivacy-drive.service").Run(); err != nil {
			return err
		}
		return exec.Command("systemctl", "restart", "easyprivacy-drive.service").Run()
	case "drive-start", "drive-stop":
		if len(args) != 0 {
			return errors.New("unexpected arguments")
		}
		verb := "start"
		if action == "drive-stop" {
			verb = "stop"
		}
		return exec.Command("systemctl", verb, "easyprivacy-drive.service").Run()
	case "drive-status":
		if len(args) != 0 {
			return errors.New("unexpected arguments")
		}
		c, err := loadDrive()
		if err != nil {
			return err
		}
		store, err := drive.Open(c.Volumes)
		if err != nil {
			return err
		}
		defer store.Close()
		active := exec.Command("systemctl", "is-active", "--quiet", "easyprivacy-drive.service").Run() == nil
		return json.NewEncoder(os.Stdout).Encode(map[string]any{"configured": true, "active": active, "name": c.Name, "volumes": store.Volumes()})
	}
	return errors.New("use drive-setup, drive-volume-add, drive-start, drive-stop, or drive-status")
}
func setupDrive() error {
	if !term.IsTerminal(int(os.Stdin.Fd())) {
		return errors.New("Drive setup needs an interactive terminal")
	}
	if c, err := loadDrive(); err == nil {
		if len(c.Volumes) == 0 {
			return resumeDriveStorage(c)
		}
		if err = saveDrive(c); err != nil {
			return err
		}
		return exec.Command("systemctl", "enable", "--now", "easyprivacy-drive.service").Run()
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	reader := bufio.NewReader(os.Stdin)
	ask := func(label, fallback string) (string, error) {
		fmt.Printf("%s [%s]: ", label, fallback)
		s, e := reader.ReadString('\n')
		s = strings.TrimSpace(s)
		if s == "" {
			s = fallback
		}
		return s, e
	}
	fmt.Println("Private Drive setup. Files stay on this server until you explicitly download them.")
	address, err := ask("Core address (management port)", "")
	if err != nil {
		return err
	}
	name, err := ask("Drive node name", "My Drive")
	if err != nil {
		return err
	}
	code, err := ask("Pairing code from Core", "")
	if err != nil {
		return err
	}
	username, err := ask("Core username", "")
	if err != nil {
		return err
	}
	path, err := ask("Storage directory (existing mount/folder, or new folder)", "/srv/easyprivacy-drive")
	if err != nil {
		return err
	}
	capacity, err := ask("Maximum capacity in GiB", "100")
	if err != nil {
		return err
	}
	gib, err := strconv.ParseInt(capacity, 10, 64)
	if err != nil || gib < 1 || gib > 1<<30 {
		return errors.New("invalid storage capacity")
	}
	fmt.Print("Core password: ")
	password, err := term.ReadPassword(int(os.Stdin.Fd()))
	fmt.Println()
	if err != nil {
		return err
	}
	defer clear(password)
	identity, err := link.Enroll(address, strings.ReplaceAll(code, " ", ""), name, username, string(password))
	if err != nil {
		return err
	}
	key, err := vpn.GenerateKey()
	if err != nil {
		return err
	}
	c := driveConfig{Schema: 1, Name: name, Identity: identity, PrivateKey: key}
	// Retain enrollment even if a mount or its permissions need correction.
	if err = saveDrive(c); err != nil {
		return err
	}
	if err = addDriveVolume(&c, "Cloud files", path, gib*(1<<30)); err != nil {
		return err
	}
	if err = exec.Command("systemctl", "enable", "--now", "easyprivacy-drive.service").Run(); err != nil {
		return err
	}
	fmt.Println("Drive configured. Open Files > Drive and refresh. Additional locations use drive-volume-add.")
	return nil
}
func resumeDriveStorage(c driveConfig) error {
	fmt.Println("Reusing the saved Drive enrollment. Configure its initial storage location.")
	reader := bufio.NewReader(os.Stdin)
	fmt.Print("Storage directory: ")
	path, err := reader.ReadString('\n')
	if err != nil {
		return err
	}
	fmt.Print("Maximum capacity in GiB: ")
	value, err := reader.ReadString('\n')
	if err != nil {
		return err
	}
	gib, err := strconv.ParseInt(strings.TrimSpace(value), 10, 64)
	if err != nil || gib < 1 || gib > 1<<30 {
		return errors.New("invalid storage capacity")
	}
	if err = addDriveVolume(&c, "Cloud files", strings.TrimSpace(path), gib*(1<<30)); err != nil {
		return err
	}
	return exec.Command("systemctl", "enable", "--now", "easyprivacy-drive.service").Run()
}
func driveLogin(c driveConfig, client *link.SessionClient) (vpn.PrivateProfile, vpn.PrivateTarget, error) {
	var profile vpn.PrivateProfile
	var target vpn.PrivateTarget
	public := vpn.Config{PrivateKey: c.PrivateKey}.PublicKey()
	if err := client.Request("POST", "/api/v2/network/private/peer", map[string]string{"public_key": public}, &profile); err != nil {
		return profile, target, err
	}
	err := client.Request("POST", "/api/v2/network/private/receiver", map[string]string{"capability": "drive", "name": c.Name}, &target)
	return profile, target, err
}
func serveDrive() error {
	c, err := loadDrive()
	if err != nil {
		return err
	}
	lock, err := os.OpenFile(filepath.Join(driveDir, "service.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return errors.New("Drive is already running")
	}
	store, err := drive.Open(c.Volumes)
	if err != nil {
		return err
	}
	defer store.Close()
	if err = store.CleanUploads(); err != nil {
		return err
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	client := link.NewSessionClient(c.Identity)
	defer client.Close()
	verifier := &drive.Verifier{Core: c.Identity.Fingerprint, Node: c.Identity.DeviceID, Lookup: client.DeviceKey}
	for ctx.Err() == nil {
		if err = driveSession(ctx, c, client, store, verifier); err != nil {
			fmt.Fprintln(os.Stderr, "Drive private connection unavailable; retrying.")
		}
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(10 * time.Second):
		}
	}
	return nil
}
func driveSession(ctx context.Context, c driveConfig, client *link.SessionClient, store *drive.Store, verifier *drive.Verifier) error {
	profile, lease, err := driveLogin(c, client)
	if err != nil {
		return err
	}
	address, err := netip.ParsePrefix(profile.Address)
	if err != nil {
		return err
	}
	prefix, err := netip.ParsePrefix(profile.Subnet)
	if err != nil {
		return err
	}
	endpoint, err := net.ResolveUDPAddr("udp", profile.Endpoint)
	if err != nil {
		return err
	}
	if lease.Kind != "drive" || lease.DeviceID != c.Identity.DeviceID || lease.Port != vpn.FilesReceiverPort || lease.Address != address.Addr().String() || !strings.HasPrefix(lease.ID, "receiver.") || len(lease.ID) != 41 || lease.ExpiresAt == nil {
		return errors.New("invalid Drive lease")
	}
	transport, err := runtime.New(runtime.Config{PrivateKey: c.PrivateKey, Address: address.Addr(), PeerPublicKey: profile.PublicKey, Endpoint: endpoint.String(), AllowedPrefix: prefix})
	if err != nil {
		return err
	}
	defer transport.Close()
	listener, err := transport.Listen(vpn.FilesReceiverPort)
	if err != nil {
		return err
	}
	defer listener.Close()
	sessionCtx, stop := context.WithCancel(ctx)
	defer stop()
	var pending sync.WaitGroup
	acceptDone := make(chan struct{})
	defer func() { stop(); transport.Close(); <-acceptDone; pending.Wait() }()
	go func() { <-sessionCtx.Done(); transport.Close() }()
	serveErrors := make(chan error, 1)
	go func() {
		defer close(acceptDone)
		slots := make(chan struct{}, 8)
		for {
			conn, err := listener.Accept()
			if err != nil {
				serveErrors <- err
				return
			}
			select {
			case slots <- struct{}{}:
				pending.Add(1)
				go func() {
					defer pending.Done()
					defer func() { <-slots }()
					conn.SetDeadline(time.Now().Add(10 * time.Second))
					var preface [37]byte
					if _, err := io.ReadFull(conn, preface[:]); err != nil || string(preface[:]) != "EPPR1"+strings.TrimPrefix(lease.ID, "receiver.") {
						conn.Close()
						return
					}
					drive.ServeConnection(conn, store, verifier)
				}()
			default:
				conn.Close()
			}
		}
	}()
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			stop()
			transport.Close()
			return nil
		case err := <-serveErrors:
			stop()
			transport.Close()
			return err
		case <-ticker.C:
			next, nextLease, err := driveLogin(c, client)
			if err != nil || next.Address != profile.Address || next.PublicKey != profile.PublicKey || next.Endpoint != profile.Endpoint || nextLease.ID != lease.ID {
				stop()
				transport.Close()
				return errors.New("Drive lease changed or could not renew")
			}
		}
	}
}
