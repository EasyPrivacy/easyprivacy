package system

import "context"

type Status struct {
	AgentVersion    string           `json:"agentVersion"`
	Hostname        string           `json:"hostname"`
	OperatingSystem string           `json:"operatingSystem"`
	Architecture    string           `json:"architecture"`
	UptimeSeconds   uint64           `json:"uptimeSeconds"`
	Memory          Capacity         `json:"memory"`
	Storage         Capacity         `json:"storage"`
	Services        []ManagedService `json:"services"`
	Backups         []BackupLocation `json:"backups"`
}

type Capacity struct {
	TotalBytes     uint64 `json:"totalBytes"`
	AvailableBytes uint64 `json:"availableBytes"`
}

type ManagedService struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Health string `json:"health"`
}

type BackupLocation struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Health string `json:"health"`
}

type Collector interface {
	Collect(context.Context) (Status, error)
}

func emptyServices() []ManagedService {
	return make([]ManagedService, 0)
}

func emptyBackups() []BackupLocation {
	return make([]BackupLocation, 0)
}
