package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

var fakeWSL string

// TestMain builds the fake wsl.exe once. With BENCHBAR_SHIM_TEST_MAIN=1 the
// test binary is the shim itself, run against fakes described by the
// environment, so tests can start it as a subprocess.
func TestMain(m *testing.M) {
	if os.Getenv("BENCHBAR_SHIM_TEST_MAIN") == "1" {
		os.Exit(run(subprocessSystem(), os.Args[1:]))
	}
	if prebuilt := os.Getenv("FAKEWSL_BIN"); prebuilt != "" {
		fakeWSL = prebuilt
		os.Exit(m.Run())
	}
	dir, err := os.MkdirTemp("", "shim-fakewsl-")
	if err != nil {
		panic(err)
	}
	name := "wsl"
	if runtime.GOOS == "windows" {
		name = "wsl.exe"
	}
	fakeWSL = filepath.Join(dir, name)
	if out, err := exec.Command("go", "build", "-o", fakeWSL, "./internal/fakewsl").CombinedOutput(); err != nil {
		os.Stderr.Write(out)
		os.RemoveAll(dir)
		os.Exit(1)
	}
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

// registrySpec is what the subprocess shim reads from BENCHBAR_TEST_REGISTRY.
type registrySpec struct {
	Unreadable bool
	Distros    []Distro
}

func subprocessSystem() *System {
	sys := newFakeSystem()
	sys.WSLPath = func() (string, error) { return os.Getenv("BENCHBAR_TEST_WSL"), nil }
	sys.Stdin, sys.Stdout, sys.Stderr = os.Stdin, os.Stdout, os.Stderr
	if local := os.Getenv("LOCALAPPDATA"); local != "" {
		sys.ConfigDir = filepath.Join(local, "BenchBar")
	}
	var spec registrySpec
	if raw := os.Getenv("BENCHBAR_TEST_REGISTRY"); raw != "" {
		json.Unmarshal([]byte(raw), &spec)
	}
	d := &fakeDistros{list: spec.Distros}
	if spec.Unreadable {
		d.err = errors.New("registry unreadable")
	}
	sys.Distros = d
	return sys
}

func newFakeSystem() *System {
	return &System{
		Distros:     &fakeDistros{},
		Paths:       &fakePaths{},
		Broadcast:   &fakeBroadcast{},
		Tasks:       &fakeTasks{},
		Procs:       newFakeProcs(),
		Pid:         4242,
		MemoryBytes: func() (uint64, error) { return 16 << 30, nil },
		WSLPath:     func() (string, error) { return fakeWSL, nil },
		FileExists:  func(string) bool { return false },
		Getenv:      os.Getenv,
		Environ:     os.Environ,
		ExePath:     `C:\tools\benchbar\benchbar.exe`,
		User:        `PC\tester`,
		Stdin:       strings.NewReader(""),
		Stdout:      &bytes.Buffer{},
		Stderr:      &bytes.Buffer{},
		Ctx:         context.Background(),
		Sleep:       sleepContext,
		Now:         func() time.Time { return time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC) },
	}
}
