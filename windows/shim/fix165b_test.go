package main

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestExitTwoNamesAVersionSkew(t *testing.T) {
	old := version
	version = "0.9.0"
	t.Cleanup(func() { version = old })
	e := newEnv(t)
	e.script(
		map[string]any{"match": "--version", "stdout": "benchbar 0.8.3\n"},
		map[string]any{"match": "--exec", "exit": 2, "stderr": "unknown option\n"},
	)
	if code := e.run("up", "--frobnicate"); code != 2 {
		t.Fatalf("exit %d", code)
	}
	if !strings.Contains(e.stderr(), "benchbar 0.8.3 in Ubuntu-24.04 is older than benchbar.exe 0.9.0. fix: benchbar.exe setup run cli_install --distro Ubuntu-24.04") {
		t.Errorf("stderr %q", e.stderr())
	}
}

func TestExit64NamesAVersionSkew(t *testing.T) {
	old := version
	version = "0.9.0"
	t.Cleanup(func() { version = old })
	e := newEnv(t)
	e.script(
		map[string]any{"match": "--version", "stdout": "benchbar 0.8.3\n"},
		map[string]any{"match": "--exec", "exit": 64, "stderr": "Unknown option\n"},
	)
	if code := e.run("up", "--frobnicate"); code != 64 {
		t.Fatalf("exit %d", code)
	}
	if !strings.Contains(e.stderr(), "benchbar 0.8.3 in Ubuntu-24.04 is older than benchbar.exe 0.9.0. fix: benchbar.exe setup run cli_install --distro Ubuntu-24.04") {
		t.Errorf("stderr %q", e.stderr())
	}
}

func TestExit64WithMatchingReleasesAddsNothing(t *testing.T) {
	old := version
	version = "0.9.0"
	t.Cleanup(func() { version = old })
	e := newEnv(t)
	e.script(
		map[string]any{"match": "--version", "stdout": "benchbar 0.9.0\n"},
		map[string]any{"match": "--exec", "exit": 64},
	)
	if code := e.run("up"); code != 64 || e.stderr() != "" {
		t.Errorf("exit %d stderr %q", code, e.stderr())
	}
}

func TestExitTwoWithMatchingReleasesAddsNothing(t *testing.T) {
	old := version
	version = "0.9.0"
	t.Cleanup(func() { version = old })
	e := newEnv(t)
	e.script(
		map[string]any{"match": "--version", "stdout": "benchbar 0.9.0\n"},
		map[string]any{"match": "--exec", "exit": 2},
	)
	if code := e.run("up"); code != 2 || e.stderr() != "" {
		t.Errorf("exit %d stderr %q", code, e.stderr())
	}
}

func TestPathChangesKeepABackupOfTheOldValue(t *testing.T) {
	e := newEnv(t)
	e.pathSetup(`C:\Windows`, `C:\tools\bb;%USERPROFILE%\bin`, testExe)
	e.paths.user = PathValue{Value: `C:\tools\bb;%USERPROFILE%\bin`, Expand: true, Exists: true}
	if code := e.run("path", "install"); code != 0 {
		t.Fatalf("exit %d: %s", code, e.stderr())
	}
	files, _ := filepath.Glob(filepath.Join(e.ConfigDir, "path-backup-*.txt"))
	if len(files) != 1 {
		t.Fatalf("backups %v", files)
	}
	b, _ := os.ReadFile(files[0])
	if !strings.Contains(string(b), "REG_EXPAND_SZ") || !strings.Contains(string(b), `C:\tools\bb;%USERPROFILE%\bin`) {
		t.Errorf("backup %q", b)
	}
	if !strings.Contains(e.stdout(), "The old user PATH is saved in ") {
		t.Errorf("stdout %q", e.stdout())
	}
	// remove makes its own, with a name that is not reused
	if code := e.run("path", "remove"); code != 0 {
		t.Fatalf("exit %d: %s", code, e.stderr())
	}
	if files, _ = filepath.Glob(filepath.Join(e.ConfigDir, "path-backup-*.txt")); len(files) != 2 {
		t.Errorf("backups %v", files)
	}
}

func TestPathNothingToChangeMakesNoBackup(t *testing.T) {
	e := newEnv(t)
	e.pathSetup(`C:\Windows`, `C:\tools\benchbar`, testExe)
	e.run("path", "install")
	if files, _ := filepath.Glob(filepath.Join(e.ConfigDir, "path-backup-*.txt")); len(files) != 0 {
		t.Errorf("backups %v", files)
	}
}

type failingWriter struct{ n int }

func (f *failingWriter) Write(p []byte) (int, error) { f.n++; return 0, errors.New("pipe closed") }

func TestEmitterStopsTheActionWhenNobodyReads(t *testing.T) {
	for _, jsonl := range []bool{true, false} {
		calls := 0
		em := &emitter{w: &failingWriter{}, jsonl: jsonl, onFail: func() { calls++ }}
		em.step("systemd", "running", "x")
		em.log("line")
		em.done(doneEvent{})
		if calls != 1 {
			t.Errorf("jsonl %v: onFail called %d times, want once", jsonl, calls)
		}
	}
	var ok bytes.Buffer
	em := &emitter{w: &ok, jsonl: true, onFail: func() { t.Error("onFail on a good writer") }}
	em.step("a", "running", "x")
}

func TestStreamEndsWithItsContext(t *testing.T) {
	e := newEnv(t)
	t.Setenv("FAKE_WSL_MODE", "sleep")
	ctx, cancel := context.WithCancel(context.Background())
	e.Ctx = ctx
	rc := &runCtx{sys: e.System, em: &emitter{w: &bytes.Buffer{}}}
	go func() { time.Sleep(300 * time.Millisecond); cancel() }()
	start := time.Now()
	code, _, _ := rc.stream("", "--status")
	if time.Since(start) > 20*time.Second {
		t.Errorf("stream did not stop with its context (%s)", time.Since(start))
	}
	if code == 0 {
		t.Error("a killed command reported success")
	}
}

func TestWslBytesEndsAtItsDeadline(t *testing.T) {
	e := newEnv(t)
	t.Setenv("FAKE_WSL_MODE", "sleep")
	start := time.Now()
	_, _, err := wslBytes(e.System, 300*time.Millisecond, 1024, "-d", "x", "--exec", "/bin/cat")
	if err == nil || !strings.Contains(err.Error(), "no answer within") {
		t.Errorf("err %v", err)
	}
	if time.Since(start) > 20*time.Second {
		t.Errorf("took %s", time.Since(start))
	}
}
