//go:build !windows

package main

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"
	"syscall"
)

var errNotWindows = errors.New("not supported on this platform")

type unsupported struct{}

func (unsupported) Distros() ([]Distro, error) { return nil, errNotWindows }
func (unsupported) User() (PathValue, error)   { return PathValue{}, errNotWindows }
func (unsupported) SetUser(string, bool) error { return errNotWindows }
func (unsupported) Machine() (string, error)   { return "", errNotWindows }
func (unsupported) EnvironmentChanged() error  { return errNotWindows }

func osServices() (DistroSource, PathStore, Broadcaster) {
	return unsupported{}, unsupported{}, unsupported{}
}

func hostMemory() (uint64, error) { return 0, errNotWindows }

func isTerminal(f *os.File) bool {
	st, err := f.Stat()
	return err == nil && st.Mode()&os.ModeCharDevice != 0
}

// relayInterrupt passes Ctrl+C to the child.
func relayInterrupt(p *os.Process) { p.Signal(os.Interrupt) }

func attachKillOnClose(pid int) func() { return func() {} }

type procControl struct{}

func (procControl) Alive(pid int) bool {
	p, err := os.FindProcess(pid)
	return err == nil && p.Signal(syscall.Signal(0)) == nil
}

func (procControl) Image(pid int) (string, error) {
	return os.Readlink(fmt.Sprintf("/proc/%d/exe", pid))
}

func (procControl) Terminate(pid int) error {
	p, err := os.FindProcess(pid)
	if err != nil {
		return err
	}
	return p.Kill()
}

func (procControl) Created(pid int) (uint64, error) {
	data, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return 0, err
	}
	// the start time is field 22; the command name in field 2 may hold spaces
	s := string(data)
	f := strings.Fields(s[strings.LastIndex(s, ")")+1:])
	if len(f) < 20 {
		return 0, errors.New("short /proc stat")
	}
	return strconv.ParseUint(f[19], 10, 64)
}

// mutexLocks is per process here; only Windows has a real named mutex.
type mutexLocks struct{}

var (
	heldMu sync.Mutex
	held   = map[string]bool{}
)

func (mutexLocks) TryLock(name string) (func(), bool, error) {
	heldMu.Lock()
	defer heldMu.Unlock()
	if held[name] {
		return nil, false, nil
	}
	held[name] = true
	return func() { heldMu.Lock(); delete(held, name); heldMu.Unlock() }, true, nil
}
