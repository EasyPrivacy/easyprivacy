//go:build !linux

package system

import (
	"context"
	"fmt"
	"os"
	"runtime"
)

type unsupportedCollector struct {
	version string
}

func NewCollector(version, _ string) Collector {
	return &unsupportedCollector{version: version}
}

func (c *unsupportedCollector) Collect(_ context.Context) (Status, error) {
	hostname, err := os.Hostname()
	if err != nil {
		return Status{}, fmt.Errorf("hostname: %w", err)
	}
	return Status{
		AgentVersion:    c.version,
		Hostname:        hostname,
		OperatingSystem: runtime.GOOS,
		Architecture:    runtime.GOARCH,
		Memory:          Capacity{},
		Storage:         Capacity{},
		Services:        emptyServices(),
		Backups:         emptyBackups(),
	}, nil
}
