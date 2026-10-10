//go:build !windows

package main

import (
	"os"
	"testing"
)

// The shim passes SIGINT on to wsl.exe and exits with its code.
func TestInterruptIsRelayed(t *testing.T) {
	cmd, record := startWaiting(t, nil)
	if err := cmd.Process.Signal(os.Interrupt); err != nil {
		t.Fatal(err)
	}
	finishInterrupted(t, cmd, record)
}
