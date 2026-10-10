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

	MemoryBytes func() (uint64, error)
	WSLPath     func() (string, error)
	FileExists  func(path string) bool
	Getenv      func(key string) string
	Environ     func() []string

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
