//go:build !windows

package main

import (
	"os"
	"strings"
	"syscall"
	"testing"
	"time"
)

// The shim passes SIGINT on to wsl.exe and exits with its code.
func TestInterruptIsRelayed(t *testing.T) {
	cmd, record := startWaiting(t, nil)
	if err := cmd.Process.Signal(os.Interrupt); err != nil {
		t.Fatal(err)
	}
	finishInterrupted(t, cmd, record)
}

// startedElevator is an elevated program that never ends by itself; started
// is closed when Windows would have shown the prompt.
type startedElevator struct {
	fakeElevator
	started chan struct{}
}

func (f *startedElevator) Start(string, []string) (ElevatedProc, error) {
	close(f.started)
	return slowProc{release: make(chan struct{})}, nil
}

// An interrupt while the elevated install runs ends sys.Ctx, so the shim
// stops waiting, says the install keeps running and writes the restart marker.
func TestInterruptEndsTheWaitForTheElevatedInstall(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.script(rule("--status", 1, ""))
	el := &startedElevator{started: make(chan struct{})}
	e.Elevate = el
	done := make(chan int, 1)
	go func() { done <- e.run("setup", "run", "wsl_enable", "--jsonl") }()
	select {
	case <-el.started:
	case <-time.After(15 * time.Second):
		t.Fatal("the elevated install did not start")
	}
	if err := syscall.Kill(syscall.Getpid(), syscall.SIGINT); err != nil {
		t.Fatal(err)
	}
	select {
	case code := <-done:
		d := lastEvent(jsonLines(t, e.stdout()))
		if code != 0 || !d.RebootRequired || strings.Join(d.NextActions, ",") != "reboot" || !strings.Contains(e.stdout(), "keeps running in Windows") {
			t.Errorf("code %d %+v\n%s", code, d, e.stdout())
		}
	case <-time.After(15 * time.Second):
		t.Fatal("the shim kept waiting after the interrupt")
	}
	if !rebootMarkerPending(e.System) {
		t.Error("no restart marker")
	}
	if e.System.Ctx.Err() != nil {
		t.Error("the context was not put back")
	}
}
