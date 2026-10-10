//go:build windows

package main

import (
	"os/exec"
	"syscall"
	"testing"

	"golang.org/x/sys/windows"
)

// The console delivers Ctrl+Break to every process in the group. The shim
// ignores it and waits; the fake (standing for wsl.exe) sees it and exits.
func TestInterruptReachesChildAndShimWaits(t *testing.T) {
	cmd, record := startWaiting(t, func(c *exec.Cmd) {
		c.SysProcAttr = &syscall.SysProcAttr{CreationFlags: windows.CREATE_NEW_PROCESS_GROUP}
	})
	proc := windows.NewLazySystemDLL("kernel32.dll").NewProc("GenerateConsoleCtrlEvent")
	if r, _, err := proc.Call(uintptr(windows.CTRL_BREAK_EVENT), uintptr(cmd.Process.Pid)); r == 0 {
		t.Skipf("no console to send Ctrl+Break through: %v", err)
	}
	finishInterrupted(t, cmd, record)
}
