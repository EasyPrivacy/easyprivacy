package vpn

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"time"
)

type Control interface {
	Info() (Exit, error)
	Register(string, string) (Profile, error)
	Remove(string) error
	Status(string) (Status, error)
}

type ServiceControl interface {
	Control
	Exits() ([]Exit, error)
	RegisterExit(string, string, string) (Profile, error)
	RegisterService(string, string, string, ...string) (ServiceProfile, error)
}
type PrivateControl interface {
	RegisterPrivate(string, string) (PrivateProfile, error)
	RemovePrivate(string) error
	PrivateStatus(string) (Status, error)
}

type DeviceControl interface{ RemoveDevice(string) error }

type Client struct {
	SocketPath   string
	ConfigMarker string
}

func (c Client) request(method, path string, input, output any) error {
	var raw []byte
	var e error
	if input != nil {
		raw, e = json.Marshal(input)
		if e != nil {
			return e
		}
	}
	tr := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", c.SocketPath)
	}}
	defer tr.CloseIdleConnections()
	req, e := http.NewRequest(method, "http://local"+path, bytes.NewReader(raw))
	if e != nil {
		return e
	}
	if input != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	res, e := (&http.Client{Transport: tr, Timeout: 6 * time.Second}).Do(req)
	if e != nil {
		return errors.New("VPN service is unavailable; check easyprivacy-vpn.service")
	}
	defer res.Body.Close()
	b, e := io.ReadAll(io.LimitReader(res.Body, 16385))
	if e != nil || len(b) > 16384 {
		return errors.New("invalid VPN service response")
	}
	if res.StatusCode != 200 {
		var v struct {
			Error string `json:"error"`
		}
		_ = json.Unmarshal(b, &v)
		if v.Error != "" && len(v.Error) < 300 {
			return errors.New(v.Error)
		}
		return errors.New("VPN service rejected the request")
	}
	if output != nil {
		return json.Unmarshal(b, output)
	}
	return nil
}
func (c Client) Info() (Exit, error) {
	var v Exit
	e := c.request("GET", "/exit", nil, &v)
	return v, e
}
func (c Client) Register(id, key string) (Profile, error) {
	return c.RegisterExit(id, key, "vps")
}
func (c Client) RegisterExit(id, key, exit string) (Profile, error) {
	var v Profile
	e := c.request("POST", "/peers", Peer{DeviceID: id, PublicKey: key, ExitID: exit}, &v)
	return v, e
}
func (c Client) Exits() ([]Exit, error) {
	var v []Exit
	e := c.request("GET", "/exits", nil, &v)
	return v, e
}
func (c Client) RegisterService(id, key, name string, addresses ...string) (ServiceProfile, error) {
	var v ServiceProfile
	management := ""
	if len(addresses) > 0 {
		management = addresses[0]
	}
	e := c.request("POST", "/service", Peer{DeviceID: id, PublicKey: key, Name: name, Management: management}, &v)
	return v, e
}
func (c Client) Remove(id string) error {
	if !ValidID(id) {
		return errors.New("invalid device")
	}
	err := c.request("DELETE", "/peers/"+id, nil, nil)
	if err != nil && c.ConfigMarker != "" {
		if _, e := os.Stat(c.ConfigMarker); errors.Is(e, os.ErrNotExist) {
			return nil
		}
	}
	return err
}
func (c Client) Status(id string) (Status, error) {
	var v Status
	if !ValidID(id) {
		return v, errors.New("invalid device")
	}
	e := c.request("GET", "/peers/"+id, nil, &v)
	return v, e
}
