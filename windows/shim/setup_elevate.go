package main

import (
	"errors"
	"time"
)

// The elevated part of wsl_enable.
//
// The UAC prompt elevates System32\wsl.exe itself, never benchbar.exe. The
// default install lives in a folder the user can write to, so a program
// running as the same user could replace benchbar.exe before the prompt is
// accepted and receive administrator rights. The system folder is writable
// by administrators only. wsl.exe runs with `--install --no-distribution`
// and a hidden window, so its output is not available; the result comes
// from its exit code and from asking wsl.exe --status afterwards.

const (
	elevatedPoll = 200 * time.Millisecond
	// wslEnableLock keeps a second elevation from starting while one runs.
	wslEnableLock = `Local\BenchBarWslEnable`
)

var wslEnableArgs = []string{"--install", "--no-distribution"}

// runWslEnableElevated is the unelevated side of wsl_enable: it skips the
// prompt when WSL already answers, asks Windows for permission to run
// wsl.exe, waits for it and ends with exactly one done event.
func runWslEnableElevated(rc *runCtx) int {
	sys, em := rc.sys, rc.em
	id := "wsl_enable"
	failed := func(msg string, cancelled bool) int {
		em.step(id, "failed", msg)
		em.done(doneEvent{Exit: 1, Cancelled: cancelled})
		return 1
	}
	if res, err := wslExec(sys, "", "--status"); err == nil && res.Code == 0 {
		em.step(id, "skipped", "WSL is already enabled")
		em.done(doneEvent{Exit: 0, NextActions: []string{"wsl_update"}})
		return 0
	}
	if sys.ElevatedWSLPath == nil {
		return failed("no trusted wsl.exe", false)
	}
	wsl, err := sys.ElevatedWSLPath()
	if err != nil {
		return failed("wsl.exe was not found in the system folder: "+err.Error(), false)
	}
	release, ok, err := sys.Locks.TryLock(wslEnableLock)
	if err != nil {
		return failed("cannot check for a running WSL install: "+err.Error(), false)
	}
	if !ok {
		return failed("a WSL install is already running; wait for it to finish, then check again", false)
	}
	defer release()

	em.step(id, "running", "Windows will ask for permission to turn on WSL")
	proc, err := sys.Elevate.Start(wsl, wslEnableArgs)
	if errors.Is(err, ErrElevationDeclined) {
		return failed("the Windows permission prompt was declined", true)
	}
	if err != nil {
		return failed("cannot ask Windows for permission: "+err.Error(), false)
	}
	defer proc.Close()

	code := 0
	for {
		done, c, werr := proc.Wait(elevatedPoll)
		if werr != nil {
			return failed("lost the elevated wsl.exe: "+werr.Error()+". It may still be running; wait a few minutes, restart Windows and check again", false)
		}
		if done {
			code = c
			break
		}
		if sys.Ctx.Err() != nil {
			return detachedWslEnable(rc)
		}
	}
	err = rc.wslEnableResult(code, nil)
	if err != nil {
		return failed(err.Error(), false)
	}
	return finishWslEnable(rc, "done")
}

// detachedWslEnable is the result when the caller stopped while the
// elevated wsl.exe still runs. The install cannot be undone, so it is not
// reported as a failure: the work goes on in Windows and ends with a restart.
func detachedWslEnable(rc *runCtx) int {
	rc.changed, rc.reboot = true, true
	rc.msg = "stopped waiting: the WSL install keeps running in Windows. Restart Windows when it finishes"
	return finishWslEnable(rc, "done")
}

// finishWslEnable sends the last step and the done event for the elevated
// path, and remembers a pending restart.
func finishWslEnable(rc *runCtx, status string) int {
	rc.em.step("wsl_enable", status, rc.msg)
	next := []string{"wsl_update"}
	if rc.reboot {
		next = []string{"reboot"}
		if err := writeRebootMarker(rc.sys, "wsl_enable"); err != nil {
			rc.warn("could not remember that a restart is pending: " + err.Error())
		}
	}
	rc.em.done(doneEvent{Exit: 0, Changed: rc.changed, RebootRequired: rc.reboot,
		Warnings: rc.warnings, NextActions: next})
	return 0
}
