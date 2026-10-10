package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func waitForFile(t *testing.T, path string) {
	t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); err == nil {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("%s did not appear", path)
}

// startWaiting starts the shim with a fake wsl.exe that blocks until it is
// interrupted, and returns once the fake is ready.
func startWaiting(t *testing.T, prepare func(*exec.Cmd)) (*exec.Cmd, string) {
	t.Helper()
	dir := t.TempDir()
	ready := filepath.Join(dir, "ready")
	record := filepath.Join(dir, "rec.jsonl")
	cmd := shimCommand(t, []string{"FAKE_WSL_MODE=wait-signal", "FAKE_WSL_READY=" + ready, "FAKE_WSL_RECORD=" + record}, "up")
	if prepare != nil {
		prepare(cmd)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { cmd.Process.Kill() })
	waitForFile(t, ready)
	return cmd, record
}

func finishInterrupted(t *testing.T, cmd *exec.Cmd, record string) {
	t.Helper()
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		code := 0
		if ee, ok := err.(*exec.ExitError); ok {
			code = ee.ExitCode()
		}
		if code != 130 {
			t.Errorf("shim exit %d, want the fake's 130", code)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("shim did not exit")
	}
	seen := false
	for _, ev := range readEvents(t, record) {
		if ev.Event == "signal" {
			seen = true
		}
	}
	if !seen {
		t.Error("the fake did not record an interrupt")
	}
}
