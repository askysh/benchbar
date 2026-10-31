package main

import (
	"errors"
	"strings"
	"time"
)

// HostInfo is what setup reads from Windows itself. Every method is read
// only. An error means the answer is unknown, not "no".
type HostInfo interface {
	// WindowsBuild is the Windows build number (19041 is Windows 10 2004).
	WindowsBuild() (int, error)
	// VirtualizationEnabled is true when firmware virtualization is on
	// (IsProcessorFeaturePresent PF_VIRT_FIRMWARE_ENABLED).
	VirtualizationEnabled() (bool, error)
	// BootTime is when Windows last started.
	BootTime() (time.Time, error)
	// ProductName is the Windows edition, such as "Windows 11 Pro".
	ProductName() (string, error)
	// IsAdmin is true when this process runs elevated.
	IsAdmin() bool
}

// ErrElevationDeclined is returned by Elevator.Start when the user answers
// the UAC prompt with No (ERROR_CANCELLED, 1223).
var ErrElevationDeclined = errors.New("the Windows permission prompt was declined")

// Elevator starts a program through the UAC prompt. The shim only ever
// passes the system folder's wsl.exe.
type Elevator interface {
	Start(exe string, args []string) (ElevatedProc, error)
}

// ElevatedProc is a program started by an Elevator.
type ElevatedProc interface {
	// Wait waits up to d. done is false when the program still runs.
	Wait(d time.Duration) (done bool, exit int, err error)
	Close()
}

// fixProductName turns the registry's "Windows 10 Pro" into "Windows 11 Pro"
// on build 22000 and later, where Windows 11 keeps the old text.
func fixProductName(name string, build int) string {
	if build >= 22000 {
		return strings.Replace(name, "Windows 10", "Windows 11", 1)
	}
	return name
}
