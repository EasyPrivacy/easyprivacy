//go:build linux

package system

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"runtime"
	"strconv"
	"strings"
	"syscall"
)

type linuxCollector struct {
	version     string
	storageRoot string
}

func NewCollector(version, storageRoot string) Collector {
	return &linuxCollector{version: version, storageRoot: storageRoot}
}

func (c *linuxCollector) Collect(_ context.Context) (Status, error) {
	hostname, err := os.Hostname()
	if err != nil {
		return Status{}, fmt.Errorf("hostname: %w", err)
	}
	uptime, err := linuxUptime()
	if err != nil {
		return Status{}, err
	}
	memory, err := linuxMemory()
	if err != nil {
		return Status{}, err
	}
	storage, err := linuxStorage(c.storageRoot)
	if err != nil {
		return Status{}, err
	}
	return Status{
		AgentVersion:    c.version,
		Hostname:        hostname,
		OperatingSystem: runtime.GOOS,
		Architecture:    runtime.GOARCH,
		UptimeSeconds:   uptime,
		Memory:          memory,
		Storage:         storage,
		Services:        emptyServices(),
		Backups:         emptyBackups(),
	}, nil
}

func linuxUptime() (uint64, error) {
	contents, err := os.ReadFile("/proc/uptime")
	if err != nil {
		return 0, fmt.Errorf("read uptime: %w", err)
	}
	fields := strings.Fields(string(contents))
	if len(fields) == 0 {
		return 0, fmt.Errorf("read uptime: unexpected /proc/uptime format")
	}
	seconds, err := strconv.ParseFloat(fields[0], 64)
	if err != nil || seconds < 0 {
		return 0, fmt.Errorf("read uptime: invalid value")
	}
	return uint64(seconds), nil
}

func linuxMemory() (Capacity, error) {
	file, err := os.Open("/proc/meminfo")
	if err != nil {
		return Capacity{}, fmt.Errorf("read memory: %w", err)
	}
	defer file.Close()

	var totalKB uint64
	var availableKB uint64
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 2 {
			continue
		}
		value, parseErr := strconv.ParseUint(fields[1], 10, 64)
		if parseErr != nil {
			continue
		}
		switch fields[0] {
		case "MemTotal:":
			totalKB = value
		case "MemAvailable:":
			availableKB = value
		}
	}
	if err := scanner.Err(); err != nil {
		return Capacity{}, fmt.Errorf("read memory: %w", err)
	}
	if totalKB == 0 {
		return Capacity{}, fmt.Errorf("read memory: MemTotal is missing")
	}
	return Capacity{
		TotalBytes:     totalKB * 1024,
		AvailableBytes: availableKB * 1024,
	}, nil
}

func linuxStorage(path string) (Capacity, error) {
	var stats syscall.Statfs_t
	if err := syscall.Statfs(path, &stats); err != nil {
		return Capacity{}, fmt.Errorf("read storage for %s: %w", path, err)
	}
	return Capacity{
		TotalBytes:     stats.Blocks * uint64(stats.Bsize),
		AvailableBytes: stats.Bavail * uint64(stats.Bsize),
	}, nil
}
