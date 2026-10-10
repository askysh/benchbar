package main

import (
	"context"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"time"
)

func newSystem() *System {
	exe, _ := os.Executable()
	name := ""
	if u, err := user.Current(); err == nil {
		name = u.Username
	}
	configDir := ""
	if local := os.Getenv("LOCALAPPDATA"); local != "" {
		configDir = filepath.Join(local, "BenchBar")
	}
	sys := &System{
		Tasks:       schtasksRunner{},
		WSLPath:     defaultWSLPath,
		FileExists:  fileExists,
		Getenv:      os.Getenv,
		Environ:     os.Environ,
		ConfigDir:   configDir,
		ProfileDir:  os.Getenv("USERPROFILE"),
		ExePath:     exe,
		Pid:         os.Getpid(),
		User:        name,
		Stdin:       os.Stdin,
		Stdout:      os.Stdout,
		Stderr:      os.Stderr,
		Ctx:         context.Background(),
		Sleep:       sleepContext,
		Now:         time.Now,
		MemoryBytes: hostMemory,
	}
	sys.Distros, sys.Paths, sys.Broadcast = osServices()
	sys.Procs = procControl{}
	sys.StdinIsTerminal = isTerminal(os.Stdin)
	return sys
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func sleepContext(ctx context.Context, d time.Duration) {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
	case <-ctx.Done():
	}
}

// defaultWSLPath prefers System32, so a wsl.exe earlier on PATH (an old
// copy, a wrapper) is not picked by accident.
func defaultWSLPath() (string, error) {
	if root := os.Getenv("SystemRoot"); root != "" {
		p := filepath.Join(root, "System32", "wsl.exe")
		if fileExists(p) {
			return p, nil
		}
	}
	return exec.LookPath("wsl.exe")
}

type schtasksRunner struct{}

func (schtasksRunner) Schtasks(args ...string) (string, int, error) {
	path := "schtasks.exe"
	if root := os.Getenv("SystemRoot"); root != "" {
		if p := filepath.Join(root, "System32", "schtasks.exe"); fileExists(p) {
			path = p
		}
	}
	out, err := exec.Command(path, args...).CombinedOutput()
	if err == nil {
		return string(out), 0, nil
	}
	if ee, ok := err.(*exec.ExitError); ok {
		return string(out), ee.ExitCode(), nil
	}
	return string(out), -1, err
}
