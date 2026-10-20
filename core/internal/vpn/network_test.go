package vpn

import (
	"context"
	"encoding/binary"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestVPNInternetFixture(t *testing.T) {
	if os.Getenv("EPVPN_INTERNET_FIXTURE") != "1" {
		t.Skip("private network fixture")
	}
	socket, e := net.ListenPacket("udp", "203.0.113.8:53")
	if e != nil {
		t.Fatal(e)
	}
	defer socket.Close()
	go func() {
		b := make([]byte, 512)
		for {
			n, from, e := socket.ReadFrom(b)
			if e != nil {
				return
			}
			if n < 12 {
				continue
			}
			reply := append([]byte{}, b[:n]...)
			reply[2] = 0x81
			reply[3] = 0x80
			binary.BigEndian.PutUint16(reply[6:8], 1)
			reply = append(reply, 0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 30, 0, 4, 203, 0, 113, 8)
			expected := os.Getenv("EPVPN_EXPECTED_SOURCE")
			if expected == "" {
				expected = "10.201.0.1"
			}
			if !strings.HasPrefix(from.String(), expected+":") {
				reply[len(reply)-1] = 0
			}
			_, _ = socket.WriteTo(reply, from)
		}
	}()
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		host, _, _ := net.SplitHostPort(r.RemoteAddr)
		fmt.Fprint(w, host)
	})
	if e = http.ListenAndServe(":18080", nil); e != nil {
		t.Fatal(e)
	}
}
func TestLinuxWireGuardInternetDNSIPv6AndRevocation(t *testing.T) {
	if os.Getenv("EPVPN_NETWORK_TEST") != "1" {
		t.Skip("run scripts/test-vpn-network.sh as root")
	}
	current, _ := os.Readlink("/proc/self/ns/net")
	initial, _ := os.Readlink("/proc/1/ns/net")
	if os.Geteuid() != 0 || current == initial {
		t.Fatal("network tests require a private root network namespace")
	}
	run := func(input string, args ...string) string {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, args[0], args[1:]...)
		cmd.Stdin = strings.NewReader(input)
		b, e := cmd.CombinedOutput()
		if e != nil {
			t.Fatalf("network fixture command %s failed: %v: %s", args[0], e, b)
		}
		return strings.TrimSpace(string(b))
	}
	ip := func(args ...string) { run("", append([]string{"ip"}, args...)...) }
	ip("link", "set", "lo", "up")
	ip("netns", "add", "client")
	ip("netns", "add", "internet")
	for _, pair := range [][3]string{{"c0", "client", "10.200.0."}, {"wan0", "internet", "10.201.0."}} {
		host, namespace, prefix := pair[0], pair[1], pair[2]
		ip("link", "add", host, "type", "veth", "peer", "name", "remote")
		ip("link", "set", "remote", "netns", namespace)
		ip("-n", namespace, "link", "set", "remote", "name", "eth0")
		ip("addr", "add", prefix+"1/24", "dev", host)
		ip("link", "set", host, "up")
		ip("-n", namespace, "link", "set", "lo", "up")
		ip("-n", namespace, "addr", "add", prefix+"2/24", "dev", "eth0")
		ip("-n", namespace, "link", "set", "eth0", "up")
		ip("-n", namespace, "route", "add", "default", "via", prefix+"1")
		v6 := "2001:db8:201::"
		if namespace == "client" {
			v6 = "2001:db8:200::"
		}
		ip("-6", "addr", "add", v6+"1/64", "dev", host, "nodad")
		ip("-n", namespace, "-6", "addr", "add", v6+"2/64", "dev", "eth0", "nodad")
		ip("-n", namespace, "-6", "route", "add", "default", "via", v6+"1")
	}
	ip("route", "add", "default", "via", "10.201.0.2")
	ip("-6", "route", "add", "default", "via", "2001:db8:201::2")
	ip("-n", "internet", "addr", "add", "203.0.113.8/32", "dev", "lo")
	ip("-n", "internet", "-6", "addr", "add", "2001:db8::8/128", "dev", "lo")
	run("", "sysctl", "-w", "net.ipv4.ip_forward=1")
	run("", "sysctl", "-w", "net.ipv6.conf.all.forwarding=1")
	run("", "iptables", "-P", "FORWARD", "DROP")
	fixture := exec.Command("ip", "netns", "exec", "internet", os.Args[0], "-test.run", "^TestVPNInternetFixture$")
	fixture.Env = append(os.Environ(), "EPVPN_INTERNET_FIXTURE=1")
	if e := fixture.Start(); e != nil {
		t.Fatal(e)
	}
	defer func() { _ = fixture.Process.Kill(); _ = fixture.Wait() }()
	for range 50 {
		conn, e := net.DialTimeout("tcp", "203.0.113.8:18080", 100*time.Millisecond)
		if e == nil {
			conn.Close()
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	v6curl := []string{"ip", "netns", "exec", "client", "curl", "--noproxy", "*", "--silent", "--show-error", "--max-time", "5", "http://[2001:db8::8]:18080"}
	if got := run("", v6curl...); got != "2001:db8:200::2" {
		t.Fatal("IPv6 underlay fixture is not working", got)
	}
	config := fixtureConfig(t)
	config.Uplink = "wan0"
	config.Endpoint = "10.200.0.1:51821"
	config.DNS = []string{"203.0.113.8"}
	backend := &Linux{}
	if e := backend.Up(config); e != nil {
		t.Fatal(e)
	}
	defer backend.Down()
	id := strings.Repeat("a", 64)
	authorized := true
	m, e := NewManager(config, t.TempDir(), backend, func() (map[string]bool, error) { return map[string]bool{id: authorized}, nil })
	if e != nil {
		t.Fatal(e)
	}
	clientKey, e := GenerateKey()
	if e != nil {
		t.Fatal(e)
	}
	clientConfig := config
	clientConfig.PrivateKey = clientKey
	clientPublic := clientConfig.PublicKey()
	profile, e := m.Register(id, clientPublic)
	if e != nil {
		t.Fatal(e)
	}
	ip("-n", "client", "link", "add", "epclient", "type", "wireguard")
	text := fmt.Sprintf("[Interface]\nPrivateKey = %s\n[Peer]\nPublicKey = %s\nEndpoint = %s\nAllowedIPs = 0.0.0.0/0, ::/0\nPersistentKeepalive = 1\n", clientKey, config.PublicKey(), config.Endpoint)
	run(text, "ip", "netns", "exec", "client", "wg", "setconf", "epclient", "/dev/stdin")
	ip("-n", "client", "address", "add", profile.Address, "dev", "epclient")
	ip("-n", "client", "-6", "address", "add", profile.AddressV6, "dev", "epclient", "nodad")
	ip("-n", "client", "link", "set", "epclient", "mtu", "1280", "up")
	ip("-n", "client", "route", "replace", "default", "dev", "epclient")
	ip("-n", "client", "-6", "route", "replace", "default", "dev", "epclient")
	curl := []string{"ip", "netns", "exec", "client", "curl", "--noproxy", "*", "--silent", "--show-error", "--max-time", "5", "http://203.0.113.8:18080"}
	if got := run("", curl...); got != "10.201.0.1" {
		t.Fatal("traffic did not leave through the exit's NAT address", got)
	}
	dns := `import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.settimeout(3);s.sendto(bytes.fromhex('1234010000010000000000000376706e04746573740000010001'),('203.0.113.8',53));r=s.recv(512);assert r[-4:]==bytes([203,0,113,8])`
	run("", "ip", "netns", "exec", "client", "python3", "-c", dns)
	stats, e := backend.PeerStatus(clientPublic)
	if e != nil || stats.LastHandshake == 0 || stats.Received == 0 || stats.Sent == 0 {
		t.Fatal("real WireGuard handshake or traffic counters missing", stats, e)
	}
	blocked := exec.Command("ip", "netns", "exec", "client", "curl", "--noproxy", "*", "--silent", "--max-time", "2", "http://[2001:db8::8]:18080")
	if blocked.Run() == nil {
		t.Fatal("IPv6 traffic bypassed protection")
	}
	dropped := false
	for _, line := range strings.Split(run("", "ip6tables", "-L", "FORWARD", "-n", "-v", "-x"), "\n") {
		fields := strings.Fields(line)
		if len(fields) > 6 && strings.Contains(line, Interface) && fields[2] == "DROP" {
			packets, _ := strconv.ParseUint(fields[0], 10, 64)
			dropped = dropped || packets > 0
		}
	}
	if !dropped {
		t.Fatal("IPv6 blocking was not enforced by the managed firewall rule")
	}
	authorized = false
	m.mu.Lock()
	e = m.reconcile()
	m.mu.Unlock()
	if e != nil {
		t.Fatal(e)
	}
	if exec.Command(curl[0], curl[1:]...).Run() == nil {
		t.Fatal("revoked peer retained Internet access")
	}
	ip("-n", "client", "link", "delete", "epclient")
	ip("-n", "client", "route", "replace", "default", "via", "10.200.0.1")
	ip("-n", "client", "-6", "route", "replace", "default", "via", "2001:db8:200::1")
	run("", "iptables", "-P", "FORWARD", "ACCEPT")
	if got := run("", curl...); got != "10.200.0.2" {
		t.Fatal("ordinary networking was not restored", got)
	}
	if got := run("", v6curl...); got != "2001:db8:200::2" {
		t.Fatal("ordinary IPv6 networking was not restored", got)
	}
	if e = backend.Down(); e != nil {
		t.Fatal(e)
	}
	if strings.Contains(run("", "iptables-save"), "easyprivacy-vpn-v1") {
		t.Fatal("managed firewall rules survived cleanup")
	}
	t.Log("real kernel WireGuard handshake, NAT, DNS, IPv6 protection, revocation and route restoration passed")
}
