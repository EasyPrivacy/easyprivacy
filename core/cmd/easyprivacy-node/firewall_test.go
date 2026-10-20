package main

import (
	"bytes"
	"errors"
	"reflect"
	"strings"
	"testing"
)

func TestFirewallOnlyAddsSelectedTCPPortWhenUFWIsActive(t *testing.T) {
	for _, port := range []int{7444, 18443} {
		var calls [][]string
		run := func(args ...string) ([]byte, error) {
			calls = append(calls, args)
			if len(calls) == 1 {
				return []byte("Status: active\n\nTo  Action  From\n22/tcp ALLOW Anywhere\n"), nil
			}
			return []byte("Skipping adding existing rule\nSkipping adding existing rule (v6)\n"), nil
		}
		var output bytes.Buffer
		if err := configureUFW(port, true, run, &output); err != nil {
			t.Fatal(err)
		}
		expected := "7444/tcp"
		if port == 18443 {
			expected = "18443/tcp"
		}
		if !reflect.DeepEqual(calls, [][]string{{"status"}, {"allow", expected}}) {
			t.Fatalf("unexpected firewall commands: %v", calls)
		}
		if !strings.Contains(output.String(), "allow rule applied") {
			t.Fatal("success was not reported")
		}
	}
}

func TestFirewallLeavesAbsentInactiveAndUnknownFirewallsUnchanged(t *testing.T) {
	for _, tc := range []struct {
		name      string
		available bool
		status    string
		wantCalls int
		wantError bool
	}{
		{"absent", false, "", 0, false},
		{"inactive", true, "Status: inactive\n", 1, false},
		{"unknown", true, "unexpected output\nStatus: active\n", 1, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			calls := 0
			run := func(args ...string) ([]byte, error) {
				calls++
				if !reflect.DeepEqual(args, []string{"status"}) {
					t.Fatalf("attempted a firewall mutation: %v", args)
				}
				return []byte(tc.status), nil
			}
			var output bytes.Buffer
			err := configureUFW(7444, tc.available, run, &output)
			if (err != nil) != tc.wantError || calls != tc.wantCalls {
				t.Fatalf("err=%v, calls=%d", err, calls)
			}
		})
	}
}

func TestFirewallFailuresReportRecoveryAndDoNotClaimSuccess(t *testing.T) {
	for _, failAt := range []int{1, 2} {
		calls := 0
		run := func(args ...string) ([]byte, error) {
			calls++
			if calls == failAt {
				return []byte("fixture failure"), errors.New("exit status 1")
			}
			return []byte("Status: active\n"), nil
		}
		var output bytes.Buffer
		err := configureUFW(18443, true, run, &output)
		if err == nil || calls != failAt || strings.Contains(output.String(), "allow rule applied") {
			t.Fatalf("err=%v, calls=%d, output=%s", err, calls, &output)
		}
		if !strings.Contains(err.Error(), "fixture failure") || !strings.Contains(err.Error(), "sudo ufw") {
			t.Fatalf("missing actionable error: %v", err)
		}
	}
}

func TestFirewallRejectsInvalidPortsBeforeRunningCommands(t *testing.T) {
	for _, port := range []int{0, 22, 65536} {
		run := func(...string) ([]byte, error) {
			t.Fatal("ran UFW for an invalid port")
			return nil, nil
		}
		if err := configureUFW(port, true, run, &bytes.Buffer{}); err == nil {
			t.Fatal("accepted invalid port")
		}
	}
	if err := firewall(t.TempDir()); err == nil {
		t.Fatal("development state was allowed to change the host firewall")
	}
}
