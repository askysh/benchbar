package main

import (
	"context"
	"io"
	"time"
)

// Distro is one registered WSL distribution.
type Distro struct {
	Name     string
	Version  int
	BasePath string
	Default  bool
}

// DistroSource reads the registered distros. An error means the registry is
// not readable; an empty list means WSL has no distro.
type DistroSource interface {
	Distros() ([]Distro, error)
}

// PathValue is a stored PATH value and its registry type.
type PathValue struct {
	Value  string
	Expand bool // REG_EXPAND_SZ
	Exists bool
}

// PathStore reads and writes the Windows PATH values.
type PathStore interface {
	User() (PathValue, error)
	SetUser(value string, expand bool) error
	Machine() (string, error)
}

// Broadcaster tells running programs that the environment changed.
type Broadcaster interface {
	EnvironmentChanged() error
}

// TaskRunner runs schtasks.exe. The output is stdout and stderr together.
type TaskRunner interface {
	Schtasks(args ...string) (out string, code int, err error)
}

// System is everything the shim takes from the operating system, so tests
// can replace it.
type System struct {
	Distros   DistroSource
	Paths     PathStore
	Broadcast Broadcaster
	Tasks     TaskRunner
	Procs     ProcessControl
	Locks     Locker
	Host      HostInfo

	// ElevatedWSLPath is the system folder wsl.exe, the only one the elevated
	// child runs.
	ElevatedWSLPath func() (string, error)

	Elevate Elevator

	// StartupApproved reads the binary value of a startup folder entry under
	// HKCU\...\Explorer\StartupApproved\StartupFolder. An error means there
	// is no value. Nil in tests that do not need it.
	StartupApproved func(name string) ([]byte, error)

	// Web makes the HTTPS requests of self-update (the GitHub releases
	// API). Launch starts the Windows programs self-update runs (the
	// installer in PowerShell, then the new benchbar.exe). Nil in tests that
	// do not need them.
	Web    WebClient
	Launch Launcher
	// PowerShellPath is Windows PowerShell 5.1 in the system folder.
	PowerShellPath func() (string, error)
	// MachineArch is the CPU of the PC (amd64 or arm64), not of this
	// process: an amd64 benchbar.exe can run emulated on an Arm PC.
	MachineArch func() string
	// ProcessImages are the running processes whose program file is named
	// name (such as BenchBarTray.exe): pid, full path and creation time.
	ProcessImages func(name string) []ProcessInfo

	MemoryBytes func() (uint64, error)
	WSLPath     func() (string, error)
	FileExists  func(path string) bool
	ListDir     func(path string) []string // entry names, nil when unreadable
	Getenv      func(key string) string
	Environ     func() []string

	// Getwd is the current folder of benchbar.exe. Nil in tests that do not
	// need it: the CLI then starts in the home folder.
	Getwd func() (string, error)

	ConfigDir  string // %LOCALAPPDATA%\BenchBar
	ProfileDir string // %USERPROFILE%
	ExePath    string
	Pid        int
	User       string // DOMAIN\user

	Stdin           io.Reader
	Stdout          io.Writer
	Stderr          io.Writer
	StdinIsTerminal bool

	Ctx   context.Context
	Sleep func(ctx context.Context, d time.Duration)
	Now   func() time.Time
}

// ProcessInfo is one running process. Pid and Created together name it,
// since a pid can be reused later by another process. Created is 0 when it
// could not be read.
type ProcessInfo struct {
	Pid     int
	Image   string
	Created uint64
}

// ProcessControl looks at and ends one process by its id.
type ProcessControl interface {
	Alive(pid int) bool
	// Image is the full path of the process's program.
	Image(pid int) (string, error)
	Terminate(pid int) error
	// Created is the process creation time, an opaque number that is
	// different for two processes that share a pid over time.
	Created(pid int) (uint64, error)
}

// Locker takes a machine wide name for as long as the process lives or
// release is called. ok is false when another process holds it.
type Locker interface {
	TryLock(name string) (release func(), ok bool, err error)
}
