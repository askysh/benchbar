//go:build !windows

package main

import (
	"errors"
	"fmt"
	"os"
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
