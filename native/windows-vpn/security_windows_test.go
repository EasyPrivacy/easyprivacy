package main

import (
	"context"
	"fmt"
	winio "github.com/Microsoft/go-winio"
	"os"
	"testing"
	"time"
)

func TestLocalServiceAuthentication(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	trusted, e := winio.DialPipeContext(ctx, pipeName)
	if e != nil {
		t.Skip("installed helper not available")
	}
	defer trusted.Close()
	if e = verifyServicePipe(trusted, supervisorName); e != nil {
		t.Fatal("installed helper was not authenticated", e)
	}
	fake := fmt.Sprintf(`\\.\pipe\EasyPrivacyVPN-test-%d`, os.Getpid())
	listener, e := winio.ListenPipe(fake, nil)
	if e != nil {
		t.Fatal(e)
	}
	defer listener.Close()
	accepted := make(chan struct{})
	go func() {
		conn, e := listener.Accept()
		if e == nil {
			defer conn.Close()
			<-accepted
		}
	}()
	conn, e := winio.DialPipeContext(ctx, fake)
	if e != nil {
		close(accepted)
		t.Fatal(e)
	}
	defer conn.Close()
	defer close(accepted)
	if verifyServicePipe(conn, supervisorName) == nil {
		t.Fatal("a pipe belonging to a different process was accepted")
	}
}
