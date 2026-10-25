package drive

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

const controlDir = ".easyprivacy-drive"

type VolumeConfig struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Path  string `json:"path"`
	Quota int64  `json:"quota"`
}
type Entry struct {
	Name      string `json:"name"`
	Directory bool   `json:"directory"`
	Size      int64  `json:"size"`
	Modified  string `json:"modified"`
}
type VolumeInfo struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Quota     int64  `json:"quota"`
	Used      int64  `json:"used"`
	Reserved  int64  `json:"reserved"`
	Available bool   `json:"available"`
}
type volume struct {
	config   VolumeConfig
	root     *os.Root
	original fs.FileInfo
	reserved int64
}
type Store struct {
	mu      sync.Mutex
	volumes map[string]*volume
}

func Token() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b[:])
}

// Reuse a marker only when an administrator explicitly selects its directory.
func StoredVolumeID(path string) (string, error) {
	root, err := os.OpenRoot(path)
	if err != nil {
		return "", err
	}
	defer root.Close()
	info, err := root.Lstat(controlDir + "/volume-id")
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() || info.Size() != 32 {
		return "", errors.New("invalid existing Drive volume marker")
	}
	data, err := root.ReadFile(controlDir + "/volume-id")
	if err != nil || !idPattern.Match(data) {
		return "", errors.New("invalid existing Drive volume marker")
	}
	return string(data), nil
}
func PrepareVolume(c VolumeConfig) error {
	if !idPattern.MatchString(c.ID) || !ValidPath(c.Name, false) || strings.Contains(c.Name, "/") || c.Quota < 1 || !filepath.IsAbs(c.Path) || filepath.Dir(c.Path) == c.Path {
		return errors.New("invalid volume configuration")
	}
	info, err := os.Lstat(c.Path)
	if err != nil || !info.IsDir() {
		return errors.New("choose an existing regular storage directory")
	}
	root, err := os.OpenRoot(c.Path)
	if err != nil {
		return err
	}
	defer root.Close()
	if err = root.Mkdir(controlDir, 0700); err != nil && !errors.Is(err, os.ErrExist) {
		return err
	}
	if info, err := root.Lstat(controlDir); err != nil || !info.IsDir() {
		return errors.New("invalid Drive metadata directory")
	}
	marker := controlDir + "/volume-id"
	f, err := root.OpenFile(marker, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if errors.Is(err, os.ErrExist) {
		b, e := root.ReadFile(marker)
		if e != nil || string(b) != c.ID {
			return errors.New("this location already belongs to another Drive volume")
		}
	} else if err != nil {
		return err
	} else {
		_, err = f.WriteString(c.ID)
		if err == nil {
			err = f.Sync()
		}
		f.Close()
		if err != nil {
			return err
		}
	}
	if err = root.Mkdir(controlDir+"/uploads", 0700); err != nil && !errors.Is(err, os.ErrExist) {
		return err
	}
	// Test publication support during setup, before accepting user uploads.
	probe := controlDir + "/uploads/" + Token() + ".part"
	link := controlDir + "/uploads/" + Token() + ".part"
	f, err = root.OpenFile(probe, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	f.Close()
	defer root.Remove(probe)
	defer root.Remove(link)
	if err = root.Link(probe, link); err != nil {
		return errors.New("this storage filesystem does not support atomic Drive uploads; use a filesystem with hard links")
	}
	return nil
}
func Open(configs []VolumeConfig) (*Store, error) {
	if len(configs) == 0 || len(configs) > 8 {
		return nil, errors.New("configure one to eight storage locations")
	}
	s := &Store{volumes: map[string]*volume{}}
	fail := func(err error) (*Store, error) { s.Close(); return nil, err }
	for _, c := range configs {
		if !idPattern.MatchString(c.ID) || c.Quota < 1 || !filepath.IsAbs(c.Path) || !ValidPath(c.Name, false) || strings.Contains(c.Name, "/") {
			return fail(errors.New("invalid storage configuration"))
		}
		canonical, err := filepath.EvalSymlinks(c.Path)
		if err != nil || canonical != filepath.Clean(c.Path) {
			return fail(errors.New("storage root is missing or has changed"))
		}
		c.Path = canonical
		for _, v := range s.volumes {
			if c.ID == v.config.ID || c.Path == v.config.Path || strings.HasPrefix(c.Path, v.config.Path+"/") || strings.HasPrefix(v.config.Path, c.Path+"/") {
				return fail(errors.New("storage locations overlap"))
			}
		}
		root, err := os.OpenRoot(c.Path)
		if err != nil {
			return fail(err)
		}
		info, err := root.Stat(".")
		if err != nil {
			root.Close()
			return fail(err)
		}
		marker, err := root.ReadFile(controlDir + "/volume-id")
		if err != nil || string(marker) != c.ID {
			root.Close()
			return fail(errors.New("storage volume marker is unavailable"))
		}
		s.volumes[c.ID] = &volume{config: c, root: root, original: info}
	}
	return s, nil
}
func (s *Store) Close() {
	for _, v := range s.volumes {
		v.root.Close()
	}
}
func (v *volume) available() error {
	current, err := os.Stat(v.config.Path)
	if err != nil || !os.SameFile(v.original, current) {
		return errors.New("storage location is unavailable or has moved")
	}
	for _, p := range []string{controlDir, controlDir + "/uploads"} {
		if info, e := v.root.Lstat(p); e != nil || !info.IsDir() {
			return errors.New("Drive metadata directory is unavailable")
		}
	}
	if info, e := v.root.Lstat(controlDir + "/volume-id"); e != nil || !info.Mode().IsRegular() || info.Size() != 32 {
		return errors.New("storage marker is unavailable")
	}
	marker, err := v.root.ReadFile(controlDir + "/volume-id")
	if err != nil || string(marker) != v.config.ID {
		return errors.New("storage marker is unavailable")
	}
	return nil
}
func (v *volume) checked(name string, allowRoot bool) (string, error) {
	if !ValidPath(name, allowRoot) {
		return "", errors.New("invalid Drive path")
	}
	if err := v.available(); err != nil {
		return "", err
	}
	if name == "" {
		return ".", nil
	}
	current := ""
	for _, part := range strings.Split(name, "/") {
		current = path.Join(current, part)
		info, err := v.root.Lstat(current)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return "", err
		}
		if !info.Mode().IsRegular() && !info.IsDir() {
			return "", errors.New("linked and special files are not supported")
		}
	}
	return name, nil
}
func (v *volume) usage() (int64, error) {
	if err := v.available(); err != nil {
		return 0, err
	}
	var used int64
	count := 0
	err := fs.WalkDir(v.root.FS(), ".", func(p string, d fs.DirEntry, e error) error {
		if e != nil {
			return e
		}
		if p == controlDir {
			return fs.SkipDir
		}
		count++
		if count > 100000 {
			return errors.New("storage entry limit exceeded")
		}
		if d.IsDir() {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return errors.New("remove linked or special files from the storage location")
		}
		if info.Size() > (1<<63)-1-used {
			return errors.New("storage usage is too large")
		}
		used += info.Size()
		return nil
	})
	return used, err
}
func (s *Store) Volumes() []VolumeInfo {
	s.mu.Lock()
	defer s.mu.Unlock()
	result := []VolumeInfo{}
	for _, v := range s.volumes {
		used, err := v.usage()
		result = append(result, VolumeInfo{v.config.ID, v.config.Name, v.config.Quota, used, v.reserved, err == nil})
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Name < result[j].Name })
	return result
}
func (s *Store) get(c Command) (*volume, string, error) {
	v := s.volumes[c.Volume]
	if v == nil {
		return nil, "", errors.New("storage location was not found")
	}
	p, err := v.checked(c.Path, c.Op == "list")
	return v, p, err
}
func entry(info fs.FileInfo) Entry {
	return Entry{info.Name(), info.IsDir(), info.Size(), info.ModTime().UTC().Format(time.RFC3339Nano)}
}
func (s *Store) List(c Command) ([]Entry, string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	v, p, err := s.get(c)
	if err != nil {
		return nil, "", err
	}
	directory, err := v.root.Open(p)
	if err != nil {
		return nil, "", err
	}
	defer directory.Close()
	all, err := directory.ReadDir(100001)
	if err != nil && err != io.EOF {
		return nil, "", err
	}
	if len(all) > 100000 {
		return nil, "", errors.New("directory entry limit exceeded")
	}
	sort.Slice(all, func(i, j int) bool { return all[i].Name() < all[j].Name() })
	result := []Entry{}
	next := ""
	for _, d := range all {
		if d.Name() <= c.Cursor || !ValidPath(d.Name(), false) || strings.Contains(d.Name(), "/") {
			continue
		}
		info, e := d.Info()
		if e != nil {
			return nil, "", e
		}
		if !info.Mode().IsRegular() && !info.IsDir() {
			continue
		}
		if len(result) == 128 {
			next = result[len(result)-1].Name
			break
		}
		result = append(result, entry(info))
	}
	return result, next, nil
}
func (s *Store) Download(c Command) (*os.File, Entry, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	v, p, err := s.get(c)
	if err != nil {
		return nil, Entry{}, err
	}
	f, err := v.root.OpenFile(p, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, Entry{}, err
	}
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > MaxFileBytes {
		f.Close()
		return nil, Entry{}, errors.New("the selected file cannot be downloaded")
	}
	return f, entry(info), nil
}
func (s *Store) Change(c Command) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	v, p, err := s.get(c)
	if err != nil {
		return err
	}
	switch c.Op {
	case "mkdir":
		return v.root.Mkdir(p, 0700)
	case "delete":
		if _, err := v.root.Lstat(p); err != nil {
			return err
		}
		// Inspect descendants before recursive removal; never follow links.
		if err := fs.WalkDir(v.root.FS(), p, func(_ string, d fs.DirEntry, e error) error {
			if e != nil {
				return e
			}
			if d.Type()&os.ModeSymlink != 0 {
				return errors.New("linked files cannot be deleted through Drive")
			}
			return nil
		}); err != nil {
			return err
		}
		return v.root.RemoveAll(p)
	case "move":
		to, err := v.checked(c.Target, false)
		if err != nil {
			return err
		}
		if to == p || strings.HasPrefix(to, p+"/") {
			return errors.New("choose a different destination")
		}
		if _, err = v.root.Lstat(to); !errors.Is(err, os.ErrNotExist) {
			return errors.New("the destination already exists or is unavailable")
		}
		return v.root.Rename(p, to)
	}
	return errors.New("unsupported change")
}

type Upload struct {
	s         *Store
	v         *volume
	c         Command
	file      *os.File
	temporary string
	done      bool
}

func (s *Store) Begin(c Command) (*Upload, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := c.Validate(); err != nil || c.Op != "upload" {
		return nil, errors.New("invalid upload")
	}
	v, p, err := s.get(c)
	if err != nil {
		return nil, err
	}
	used, err := v.usage()
	if err != nil {
		return nil, err
	}
	if c.Size > v.config.Quota-used-v.reserved {
		return nil, errors.New("this storage location has insufficient allocated capacity")
	}
	if _, err = v.root.Lstat(p); !errors.Is(err, os.ErrNotExist) {
		return nil, errors.New("a file or folder already exists at that location")
	}
	parent, err := v.root.Stat(path.Dir(p))
	if err != nil || !parent.IsDir() {
		return nil, errors.New("the receiving folder is unavailable")
	}
	temporary := controlDir + "/uploads/" + Token() + ".part"
	file, err := v.root.OpenFile(temporary, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return nil, err
	}
	v.reserved += c.Size
	return &Upload{s: s, v: v, c: c, file: file, temporary: temporary}, nil
}
func (u *Upload) Abort() {
	u.s.mu.Lock()
	defer u.s.mu.Unlock()
	if u.done {
		return
	}
	u.done = true
	u.file.Close()
	u.v.root.Remove(u.temporary)
	u.v.reserved -= u.c.Size
}
func (u *Upload) Receive(r io.Reader) error { return u.ReceiveChecked(r, nil) }
func (u *Upload) ReceiveChecked(r io.Reader, authorize func() error) error {
	defer u.Abort()
	h := sha256.New()
	if _, err := io.CopyN(io.MultiWriter(u.file, h), r, u.c.Size); err != nil {
		return errors.New("upload was interrupted")
	}
	if hex.EncodeToString(h.Sum(nil)) != u.c.SHA256 {
		return errors.New("upload content did not match its checksum")
	}
	if err := u.file.Sync(); err != nil {
		return err
	}
	if err := u.file.Close(); err != nil {
		return err
	}
	if authorize != nil {
		if err := authorize(); err != nil {
			return err
		}
	}
	u.s.mu.Lock()
	defer u.s.mu.Unlock()
	if _, err := u.v.checked(u.c.Path, false); err != nil {
		return err
	}
	// Recount on commit: administrative writes must not make an upload exceed quota.
	used, err := u.v.usage()
	if err != nil {
		return err
	}
	if u.c.Size > u.v.config.Quota-used {
		return errors.New("storage capacity was exhausted during upload")
	}
	// Hard-link publication is atomic and refuses to overwrite an existing name.
	if err = u.v.root.Link(u.temporary, u.c.Path); err != nil {
		return fmt.Errorf("could not publish upload: %w", err)
	}
	if parent, err := u.v.root.Open(path.Dir(u.c.Path)); err == nil {
		parent.Sync()
		parent.Close()
	}
	return nil
}

// Called only after acquiring the node's exclusive service lock.
func (s *Store) CleanUploads() error {
	for _, v := range s.volumes {
		if err := v.available(); err != nil {
			return err
		}
		f, err := v.root.Open(controlDir + "/uploads")
		if err != nil {
			return err
		}
		names, err := f.ReadDir(-1)
		f.Close()
		if err != nil {
			return err
		}
		for _, d := range names {
			if !d.Type().IsRegular() || !regexpUpload(d.Name()) {
				return errors.New("unexpected item in Drive staging")
			}
			if err := v.root.Remove(controlDir + "/uploads/" + d.Name()); err != nil {
				return err
			}
		}
	}
	return nil
}
func regexpUpload(name string) bool {
	return len(name) == 37 && strings.HasSuffix(name, ".part") && idPattern.MatchString(strings.TrimSuffix(name, ".part"))
}
