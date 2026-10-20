package main

import (
	"bytes"
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	winio "github.com/Microsoft/go-winio"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
	"golang.zx2c4.com/wireguard/windows/conf"
	"golang.zx2c4.com/wireguard/windows/driver"
	"golang.zx2c4.com/wireguard/windows/tunnel"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unsafe"
)

//go:embed runtime/wireguard.dll
var driverDLL []byte

const supervisorName = "EasyPrivacyVPN"
const tunnelName = "WireGuardTunnel$EasyPrivacy"
const pipeName = `\\.\pipe\EasyPrivacyVPN-v1`
const privateSDDL = "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"

type state struct {
	Protocol  int    `json:"helper_protocol"`
	Installed bool   `json:"installed"`
	Active    bool   `json:"active"`
	Handshake int64  `json:"last_handshake"`
	Received  uint64 `json:"received"`
	Sent      uint64 `json:"sent"`
}
type supervisor struct {
	mu   sync.Mutex
	data string
}

func paths() (string, string, error) {
	p, e := windows.KnownFolderPath(windows.FOLDERID_ProgramFiles, 0)
	if e != nil {
		return "", "", e
	}
	d, e := windows.KnownFolderPath(windows.FOLDERID_ProgramData, 0)
	return filepath.Join(p, "EasyPrivacyVPN"), filepath.Join(d, "EasyPrivacyVPN"), e
}
func privateDirectory(path string) error {
	sd, e := windows.SecurityDescriptorFromString(privateSDDL)
	if e != nil {
		return e
	}
	p, e := windows.UTF16PtrFromString(path)
	if e != nil {
		return e
	}
	e = windows.CreateDirectory(p, &windows.SecurityAttributes{Length: uint32(unsafe.Sizeof(windows.SecurityAttributes{})), SecurityDescriptor: sd})
	if e == windows.ERROR_ALREADY_EXISTS {
		attrs, err := windows.GetFileAttributes(p)
		if err != nil || attrs&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
			return errors.New("refusing an unsafe VPN installation directory")
		}
		actual, err := windows.GetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.GROUP_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
		if err != nil || strings.ReplaceAll(actual.String(), "D:PAI", "D:P") != sd.String() {
			return errors.New("VPN installation directory does not have the required private permissions")
		}
		return nil
	}
	return e
}
func writePrivate(path string, data []byte) error {
	// The parent is protected from non-administrators before any file is written.
	if info, e := os.Lstat(path); e == nil && (info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular()) {
		return errors.New("unsafe VPN file")
	}
	return os.WriteFile(path, data, 0600)
}
func install(owner string) error {
	if !windows.GetCurrentProcessToken().IsElevated() {
		return errors.New("Windows administrator approval is required")
	}
	sid, e := windows.StringToSid(owner)
	if e != nil || sid.String() != owner {
		return errors.New("invalid installation owner")
	}
	bin, data, e := paths()
	if e != nil {
		return e
	}
	if e = privateDirectory(bin); e != nil {
		return e
	}
	if e = privateDirectory(data); e != nil {
		return e
	}
	self, e := os.Executable()
	if e != nil {
		return e
	}
	raw, e := os.ReadFile(self)
	if e != nil {
		return e
	}
	dest := filepath.Join(bin, "easyprivacy-vpn.exe")
	m, e := mgr.Connect()
	if e != nil {
		return e
	}
	defer m.Disconnect()
	if old, e := m.OpenService(supervisorName); e == nil {
		_, _ = old.Control(svc.Stop)
		for range 30 {
			v, _ := old.Query()
			if v.State == svc.Stopped {
				break
			}
			time.Sleep(100 * time.Millisecond)
		}
		old.Close()
	}
	if e = writePrivate(dest, raw); e != nil {
		return e
	}
	if e = writePrivate(filepath.Join(bin, "wireguard.dll"), driverDLL); e != nil {
		return e
	}
	if e = writePrivate(filepath.Join(data, "owner.sid"), []byte(owner)); e != nil {
		return e
	}
	service, e := m.OpenService(supervisorName)
	if e != nil {
		service, e = m.CreateService(supervisorName, dest, mgr.Config{DisplayName: "EasyPrivacy VPN", StartType: mgr.StartAutomatic}, "--service")
	}
	if e != nil {
		return e
	}
	defer service.Close()
	if e = service.Start(); e != nil && e != windows.ERROR_SERVICE_ALREADY_RUNNING {
		return e
	}
	return nil
}
func (s *supervisor) stopTunnel() error {
	m, e := mgr.Connect()
	if e != nil {
		return e
	}
	defer m.Disconnect()
	t, e := m.OpenService(tunnelName)
	if e != nil {
		if e == windows.ERROR_SERVICE_DOES_NOT_EXIST {
			return nil
		}
		return e
	}
	defer t.Close()
	v, e := t.Query()
	if e != nil {
		return e
	}
	if v.State != svc.Stopped {
		if _, e = t.Control(svc.Stop); e != nil && e != windows.ERROR_SERVICE_NOT_ACTIVE {
			return e
		}
		for range 80 {
			v, e = t.Query()
			if e != nil {
				return e
			}
			if v.State == svc.Stopped {
				break
			}
			time.Sleep(100 * time.Millisecond)
		}
		if v.State != svc.Stopped {
			return errors.New("VPN service did not stop")
		}
	}
	return nil
}
func (s *supervisor) connect(c Config) error {
	text, e := c.Text()
	if e != nil {
		return e
	}
	if e = s.stopTunnel(); e != nil {
		return e
	}
	file := filepath.Join(s.data, "EasyPrivacy.conf")
	if e = writePrivate(file, []byte(text)); e != nil {
		return e
	}
	bin, _, e := paths()
	if e != nil {
		return e
	}
	m, e := mgr.Connect()
	if e != nil {
		return e
	}
	defer m.Disconnect()
	t, e := m.OpenService(tunnelName)
	if e != nil {
		t, e = m.CreateService(tunnelName, filepath.Join(bin, "easyprivacy-vpn.exe"), mgr.Config{DisplayName: "EasyPrivacy tunnel", StartType: mgr.StartManual, Dependencies: []string{"Nsi", "TcpIp"}, SidType: windows.SERVICE_SID_TYPE_UNRESTRICTED}, "--tunnel", file)
	}
	if e != nil {
		return e
	}
	defer t.Close()
	if e = t.Start(); e != nil {
		return e
	}
	for range 100 {
		v, e := t.Query()
		if e != nil {
			return e
		}
		if v.State == svc.Running {
			return nil
		}
		if v.State == svc.Stopped {
			return errors.New("WireGuard tunnel failed to start")
		}
		time.Sleep(100 * time.Millisecond)
	}
	return errors.New("WireGuard tunnel startup timed out")
}
func localStatus() state {
	result := state{Installed: true, Protocol: 2}
	adapter, e := driver.OpenAdapter("EasyPrivacy")
	if e != nil {
		return result
	}
	defer adapter.Close()
	v, e := adapter.AdapterState()
	if e != nil || v != driver.AdapterStateUp {
		return result
	}
	result.Active = true
	c, e := adapter.Configuration()
	if e != nil || c.PeerCount == 0 {
		return result
	}
	p := c.FirstPeer()
	result.Received = p.RxBytes
	result.Sent = p.TxBytes
	if p.LastHandshake >= 116444736000000000 {
		result.Handshake = int64((p.LastHandshake - 116444736000000000) / 10000000)
	}
	return result
}
func (s *supervisor) handler() http.Handler {
	mux := http.NewServeMux()
	respond := func(w http.ResponseWriter, value any, e error) {
		w.Header().Set("Content-Type", "application/json")
		if e != nil {
			w.WriteHeader(400)
			value = map[string]string{"error": e.Error()}
		}
		_ = json.NewEncoder(w).Encode(value)
	}
	mux.HandleFunc("GET /status", func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		defer s.mu.Unlock()
		respond(w, localStatus(), nil)
	})
	mux.HandleFunc("POST /connect", func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, 4096)
		defer r.Body.Close()
		d := json.NewDecoder(r.Body)
		d.DisallowUnknownFields()
		var c Config
		var extra any
		if d.Decode(&c) != nil || d.Decode(&extra) != io.EOF {
			respond(w, nil, errors.New("invalid tunnel configuration"))
			return
		}
		s.mu.Lock()
		defer s.mu.Unlock()
		e := s.connect(c)
		respond(w, localStatus(), e)
	})
	mux.HandleFunc("POST /disconnect", func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		defer s.mu.Unlock()
		e := s.stopTunnel()
		if e == nil {
			_ = os.Remove(filepath.Join(s.data, "EasyPrivacy.conf"))
		}
		respond(w, localStatus(), e)
	})
	return mux
}
func (s *supervisor) Execute(_ []string, requests <-chan svc.ChangeRequest, changes chan<- svc.Status) (bool, uint32) {
	changes <- svc.Status{State: svc.StartPending}
	_, data, e := paths()
	if e != nil {
		return false, 1
	}
	s.data = data
	owner, e := os.ReadFile(filepath.Join(data, "owner.sid"))
	if e != nil {
		return false, 2
	}
	sid, e := windows.StringToSid(string(owner))
	if e != nil || sid.String() != string(owner) {
		return false, 3
	}
	listener, e := winio.ListenPipe(pipeName, &winio.PipeConfig{SecurityDescriptor: "D:P(A;;GA;;;SY)(A;;GA;;;" + string(owner) + ")", InputBufferSize: 8192, OutputBufferSize: 8192})
	if e != nil {
		return false, 4
	}
	defer listener.Close()
	server := &http.Server{Handler: s.handler(), ReadHeaderTimeout: 3 * time.Second, ReadTimeout: 5 * time.Second, WriteTimeout: 20 * time.Second, IdleTimeout: 10 * time.Second, MaxHeaderBytes: 4096}
	done := make(chan error, 1)
	go func() { done <- server.Serve(listener) }()
	changes <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	for {
		select {
		case r := <-requests:
			switch r.Cmd {
			case svc.Interrogate:
				changes <- r.CurrentStatus
			case svc.Stop, svc.Shutdown:
				changes <- svc.Status{State: svc.StopPending}
				_ = server.Close()
				s.mu.Lock()
				_ = s.stopTunnel()
				s.mu.Unlock()
				return false, 0
			}
		case <-done:
			return false, 5
		}
	}
}
func request(method, path string, raw []byte) (json.RawMessage, error) {
	tr := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		conn, e := winio.DialPipeContext(ctx, pipeName)
		if e != nil {
			return nil, e
		}
		if e = verifyServicePipe(conn, supervisorName); e != nil {
			conn.Close()
			return nil, e
		}
		return conn, nil
	}}
	defer tr.CloseIdleConnections()
	r, e := http.NewRequest(method, "http://local"+path, bytes.NewReader(raw))
	if e != nil {
		return nil, e
	}
	r.Header.Set("Content-Type", "application/json")
	res, e := (&http.Client{Transport: tr, Timeout: 25 * time.Second}).Do(r)
	if e != nil {
		return nil, errors.New("Install the EasyPrivacy VPN helper first")
	}
	defer res.Body.Close()
	b, e := io.ReadAll(io.LimitReader(res.Body, 4097))
	if e != nil || len(b) > 4096 {
		return nil, errors.New("invalid VPN helper response")
	}
	if res.StatusCode != 200 {
		var msg struct {
			Error string `json:"error"`
		}
		_ = json.Unmarshal(b, &msg)
		return nil, errors.New(msg.Error)
	}
	return b, nil
}

// Authenticate the server before HTTP writes a private VPN key. A different
// Windows account must not be able to squat on our public pipe name.
func verifyServicePipe(conn net.Conn, serviceName string) error {
	file, ok := conn.(interface{ Fd() uintptr })
	if !ok {
		return errors.New("cannot verify VPN helper endpoint")
	}
	var pid uint32
	if e := windows.GetNamedPipeServerProcessId(windows.Handle(file.Fd()), &pid); e != nil {
		return e
	}
	manager, e := windows.OpenSCManager(nil, nil, windows.SC_MANAGER_CONNECT)
	if e != nil {
		return e
	}
	defer windows.CloseServiceHandle(manager)
	name, e := windows.UTF16PtrFromString(serviceName)
	if e != nil {
		return e
	}
	service, e := windows.OpenService(manager, name, windows.SERVICE_QUERY_STATUS)
	if e != nil {
		return e
	}
	defer windows.CloseServiceHandle(service)
	var status windows.SERVICE_STATUS_PROCESS
	var needed uint32
	if e = windows.QueryServiceStatusEx(service, windows.SC_STATUS_PROCESS_INFO, (*byte)(unsafe.Pointer(&status)), uint32(unsafe.Sizeof(status)), &needed); e != nil {
		return e
	}
	if status.CurrentState != windows.SERVICE_RUNNING || pid == 0 || status.ProcessId != pid {
		return errors.New("VPN pipe is not owned by the installed EasyPrivacy service")
	}
	return nil
}

func elevate() error {
	u, e := windows.GetCurrentProcessToken().GetTokenUser()
	if e != nil {
		return e
	}
	self, e := os.Executable()
	if e != nil {
		return e
	}
	type shellInfo struct {
		Size                              uint32
		Mask                              uint32
		Window                            windows.Handle
		Verb, File, Parameters, Directory *uint16
		Show                              int32
		Instance                          windows.Handle
		IDList                            uintptr
		Class                             *uint16
		ClassKey                          windows.Handle
		HotKey                            uint32
		Icon                              windows.Handle
		Process                           windows.Handle
	}
	verb, _ := windows.UTF16PtrFromString("runas")
	file, _ := windows.UTF16PtrFromString(self)
	args, _ := windows.UTF16PtrFromString("--install-elevated " + u.User.Sid.String())
	info := shellInfo{Mask: 0x40 | 0x400, Verb: verb, File: file, Parameters: args, Show: 0}
	info.Size = uint32(unsafe.Sizeof(info))
	r, _, err := windows.NewLazySystemDLL("shell32.dll").NewProc("ShellExecuteExW").Call(uintptr(unsafe.Pointer(&info)))
	if r == 0 {
		return fmt.Errorf("Windows administrator approval was not completed: %w", err)
	}
	defer windows.CloseHandle(info.Process)
	result, e := windows.WaitForSingleObject(info.Process, 180000)
	if e != nil || result != windows.WAIT_OBJECT_0 {
		return errors.New("VPN helper installation did not finish")
	}
	var code uint32
	if e = windows.GetExitCodeProcess(info.Process, &code); e != nil {
		return e
	}
	if code != 0 {
		return errors.New("VPN helper installation failed; check installation permissions")
	}
	return nil
}
func run() error {
	if len(os.Args) < 2 {
		return errors.New("use --install, --connect, --disconnect or --status")
	}
	switch os.Args[1] {
	case "--service":
		return svc.Run(supervisorName, &supervisor{})
	case "--tunnel":
		_, data, e := paths()
		if e != nil {
			return e
		}
		if len(os.Args) != 3 || !strings.EqualFold(os.Args[2], filepath.Join(data, "EasyPrivacy.conf")) {
			return errors.New("invalid protected tunnel path")
		}
		conf.PresetRootDirectory(data)
		tunnel.UseFixedGUIDInsteadOfDeterministic = true
		return tunnel.Run(os.Args[2])
	case "--install-elevated":
		if len(os.Args) != 3 {
			return errors.New("missing installation owner")
		}
		return install(os.Args[2])
	case "--install":
		if e := elevate(); e != nil {
			return e
		}
		for range 30 {
			if b, e := request("GET", "/status", nil); e == nil {
				fmt.Println(string(b))
				return nil
			}
			time.Sleep(100 * time.Millisecond)
		}
		return errors.New("VPN helper did not become ready")
	case "--status":
		b, e := request("GET", "/status", nil)
		if e != nil {
			b = []byte(`{"installed":false,"active":false}`)
		} else {
			var status state
			if json.Unmarshal(b, &status) != nil {
				return errors.New("invalid VPN service status")
			}
			if status.Protocol != 2 {
				status.Installed = false
				b, _ = json.Marshal(status)
			}
		}
		fmt.Println(string(b))
		return nil
	case "--connect":
		b, e := io.ReadAll(io.LimitReader(os.Stdin, 4097))
		if e != nil || len(b) > 4096 {
			return errors.New("invalid tunnel input")
		}
		out, e := request("POST", "/connect", b)
		if e != nil {
			return e
		}
		fmt.Println(string(out))
		return nil
	case "--disconnect":
		out, e := request("POST", "/disconnect", nil)
		if e != nil {
			return e
		}
		fmt.Println(string(out))
		return nil
	}
	return errors.New("unknown VPN action")
}
func main() {
	if e := run(); e != nil {
		_ = json.NewEncoder(os.Stdout).Encode(map[string]string{"error": e.Error()})
		os.Exit(1)
	}
}
