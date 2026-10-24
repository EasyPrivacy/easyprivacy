package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	runtime "github.com/easyprivacy/easyprivacy/core-runtime"
	"net/netip"
	"os"
	"sync"
	"time"
)

type request struct {
	ID        int             `json:"id"`
	Method    string          `json:"method"`
	Arguments json.RawMessage `json:"arguments"`
}

func main() {
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 4096), 16384)
	encoder := json.NewEncoder(os.Stdout)
	var output sync.Mutex
	reply := func(id int, result any, err error) {
		output.Lock()
		defer output.Unlock()
		response := map[string]any{"id": id, "result": result}
		if err != nil {
			response = map[string]any{"id": id, "error": "Private connection operation failed."}
		}
		_ = encoder.Encode(response)
	}
	var bridge *runtime.Bridge
	if !scanner.Scan() {
		return
	}
	var first request
	if json.Unmarshal(scanner.Bytes(), &first) != nil || first.Method != "start" {
		return
	}
	var config runtime.Config
	if json.Unmarshal(first.Arguments, &config) != nil {
		reply(first.ID, nil, fmt.Errorf("configuration"))
		return
	}
	transport, err := runtime.New(config)
	if err == nil {
		bridge, err = runtime.NewBridge(transport)
	}
	if err != nil {
		if transport != nil {
			transport.Close()
		}
		reply(first.ID, nil, err)
		return
	}
	defer bridge.Close()
	port, _ := transport.Port()
	reply(first.ID, map[string]any{"protocol": 1, "udp_port": port}, nil)
	slots := make(chan struct{}, 16)
	var pending sync.WaitGroup
	for scanner.Scan() {
		var call request
		if json.Unmarshal(scanner.Bytes(), &call) != nil {
			return
		}
		select {
		case slots <- struct{}{}:
		default:
			reply(call.ID, nil, fmt.Errorf("busy"))
			continue
		}
		pending.Add(1)
		go func(call request) {
			defer pending.Done()
			defer func() { <-slots }()
			var args struct {
				Capability string `json:"capability"`
				Service    string `json:"service"`
				Address    string `json:"address"`
				Port       uint16 `json:"port"`
				Receiver   string `json:"receiver"`
			}
			if json.Unmarshal(call.Arguments, &args) != nil {
				reply(call.ID, nil, fmt.Errorf("arguments"))
				return
			}
			var result any = map[string]bool{"ok": true}
			var err error
			switch call.Method {
			case "issue":
				address, e := netip.ParseAddr(args.Address)
				if e != nil {
					err = e
				} else {
					result, err = bridge.Issue(args.Capability, args.Service, netip.AddrPortFrom(address, args.Port))
				}
			case "receive":
				err = bridge.RegisterReceiver(args.Receiver)
			case "accept":
				ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
				result, err = bridge.AcceptReceiver(ctx, args.Receiver)
				cancel()
			case "closeReceiver":
				bridge.CloseReceiver(args.Receiver)
			case "revoke":
				bridge.Revoke(args.Capability)
			default:
				err = fmt.Errorf("unsupported operation")
			}
			reply(call.ID, result, err)
		}(call)
	}
	bridge.Close()
	pending.Wait()
}
