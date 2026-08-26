package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/easyprivacy/easyprivacy/agent/internal/device"
	"github.com/easyprivacy/easyprivacy/agent/internal/system"
)

type fakeCollector struct {
	status system.Status
	err    error
}

func (collector fakeCollector) Collect(context.Context) (system.Status, error) {
	return collector.status, collector.err
}

func TestHealthDoesNotExposeSystemDetails(t *testing.T) {
	handler := NewHandler(NewStaticAuthenticator("secret-token"), fakeCollector{})
	request := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("expected %d, got %d", http.StatusOK, response.Code)
	}
	if got := response.Body.String(); got != "{\"status\":\"ok\"}\n" {
		t.Fatalf("unexpected health response: %s", got)
	}
}

func TestStatusRequiresDeviceToken(t *testing.T) {
	handler := NewHandler(NewStaticAuthenticator("secret-token"), fakeCollector{})
	request := httptest.NewRequest(http.MethodGet, "/v1/status", nil)
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusUnauthorized {
		t.Fatalf("expected %d, got %d", http.StatusUnauthorized, response.Code)
	}
	if cacheControl := response.Header().Get("Cache-Control"); cacheControl != "no-store" {
		t.Fatalf("expected no-store response, got %q", cacheControl)
	}
}

func TestStatusReturnsCollectedDataForValidDevice(t *testing.T) {
	expected := system.Status{
		AgentVersion:    "0.1.0-test",
		Hostname:        "test-node",
		OperatingSystem: "linux",
		Architecture:    "amd64",
		UptimeSeconds:   42,
		Memory:          system.Capacity{TotalBytes: 100, AvailableBytes: 40},
		Storage:         system.Capacity{TotalBytes: 1000, AvailableBytes: 750},
		Services:        []system.ManagedService{},
		Backups:         []system.BackupLocation{},
	}
	handler := NewHandler(
		NewStaticAuthenticator("secret-token"),
		fakeCollector{status: expected},
	)
	request := httptest.NewRequest(http.MethodGet, "/v1/status", nil)
	request.Header.Set("Authorization", "Bearer secret-token")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("expected %d, got %d: %s", http.StatusOK, response.Code, response.Body)
	}
	if got := response.Body.String(); got == "" || !contains(got, `"hostname":"test-node"`) {
		t.Fatalf("status response did not contain hostname: %s", got)
	}
}

func TestDistinctDeviceCredentialAuthenticatesUntilRevoked(t *testing.T) {
	store, err := device.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	credential, err := store.Enroll("Owner laptop")
	if err != nil {
		t.Fatal(err)
	}
	handler := NewHandler(store, fakeCollector{status: system.Status{
		AgentVersion:    "0.1.0-test",
		Hostname:        "test-node",
		OperatingSystem: "linux",
		Architecture:    "amd64",
		Memory:          system.Capacity{},
		Storage:         system.Capacity{},
		Services:        []system.ManagedService{},
		Backups:         []system.BackupLocation{},
	}})

	request := httptest.NewRequest(http.MethodGet, "/v1/status", nil)
	request.Header.Set("Authorization", "Bearer "+credential.Token)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("device credential returned %d: %s", response.Code, response.Body)
	}

	if err := store.Revoke(credential.Device.ID); err != nil {
		t.Fatal(err)
	}
	request = httptest.NewRequest(http.MethodGet, "/v1/status", nil)
	request.Header.Set("Authorization", "Bearer "+credential.Token)
	response = httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("revoked credential returned %d, expected %d", response.Code, http.StatusUnauthorized)
	}
}

func contains(value, substring string) bool {
	for index := 0; index+len(substring) <= len(value); index++ {
		if value[index:index+len(substring)] == substring {
			return true
		}
	}
	return false
}
