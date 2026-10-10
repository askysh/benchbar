package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// assertFixLines checks the parse contract: a WARN or FAIL line is followed
// by an indented fix: line with something in it.
func assertFixLines(t *testing.T, name, out string) (problems int) {
	t.Helper()
	lines := strings.Split(out, "\n")
	for i, l := range lines {
		if !strings.HasPrefix(l, "  [WARN] ") && !strings.HasPrefix(l, "  [FAIL] ") {
			continue
		}
		problems++
		if i+1 >= len(lines) || !strings.HasPrefix(lines[i+1], "     fix: ") || strings.TrimSpace(strings.TrimPrefix(lines[i+1], "     fix:")) == "" {
			t.Errorf("%s: no fix line after %q", name, l)
		}
	}
	return problems
}

func TestEveryWarnAndFailHasAFixLine(t *testing.T) {
	healthy := func(e *env) { e.healthyWindows() }
	scenarios := []struct {
		name  string
		setup func(e *env)
		args  []string
	}{
		{"doctor: nothing set up", func(e *env) { e.pathSetup(`C:\Windows`, `C:\a`); e.taskNotInstalled() }, []string{"doctor"}},
		{"doctor: user PATH unreadable", func(e *env) { healthy(e); e.paths.userErr = errors.New("denied") }, []string{"doctor"}},
		{"doctor: machine PATH unreadable", func(e *env) { healthy(e); e.paths.machineErr = errors.New("denied") }, []string{"doctor"}},
		{"doctor: other copy first", func(e *env) {
			healthy(e)
			e.paths.machine = `C:\Other`
			e.FileExists = func(p string) bool { return p == `C:\Other\benchbar.exe` || p == testExe }
		}, []string{"doctor"}},
		{"doctor: registry unreadable", func(e *env) { healthy(e); e.distros.list, e.distros.err = nil, errors.New("denied") }, []string{"doctor"}},
		{"doctor: no distro", func(e *env) { healthy(e); e.distros.list = nil }, []string{"doctor"}},
		{"doctor: WSL 1", func(e *env) { healthy(e); e.distros.list = []Distro{{Name: "Ubuntu-24.04", Version: 1, Default: true}} }, []string{"doctor"}},
		{"doctor: wslconfig unreadable", func(e *env) {
			healthy(e)
			p := filepath.Join(e.ProfileDir, ".wslconfig")
			os.Remove(p)
			os.Mkdir(p, 0o755)
		}, []string{"doctor"}},
		{"doctor: idle timeouts", func(e *env) { healthy(e); os.Remove(filepath.Join(e.ProfileDir, ".wslconfig")) }, []string{"doctor"}},
		{"doctor: schtasks missing", func(e *env) {
			healthy(e)
			e.tasks.handler = func([]string) (string, int, error) { return "", -1, errors.New("not found") }
		}, []string{"doctor"}},
		{"doctor: exe missing", func(e *env) {
			healthy(e)
			e.FileExists = func(p string) bool { return false }
			e.taskHandler(taskXMLOutput(installedArgs()), statusCSV)
		}, []string{"doctor"}},
		{"doctor: foreign task action", func(e *env) { healthy(e); e.taskHandler(taskXMLOutput("something else"), statusCSV) }, []string{"doctor"}},
		{"path status: not found", func(e *env) { e.pathSetup(`C:\Windows`, `C:\a`) }, []string{"path", "status"}},
		{"keepalive status: not installed", func(e *env) { e.taskNotInstalled() }, []string{"keepalive", "status"}},
		{"adopt: no systemd", func(e *env) { e.useProbe(probeText("", "init", "u", "/b", "yes")) }, []string{"adopt-distro"}},
		{"adopt: boot section without systemd", func(e *env) { e.useProbe(probeText("[boot]\nx=1\n", "init", "u", "/b", "yes")) }, []string{"adopt-distro"}},
		{"adopt: restart needed", func(e *env) { e.useProbe(probeText(goodConf, "init", "u", "/b", "yes")) }, []string{"adopt-distro"}},
		{"adopt: no benchbar", func(e *env) { e.useProbe(probeText(goodConf, "systemd", "u", "", "yes")) }, []string{"adopt-distro"}},
		{"adopt: linger off", func(e *env) { e.useProbe(probeText(goodConf, "systemd", "u", "/b", "no")) }, []string{"adopt-distro"}},
		{"adopt: linger unknown", func(e *env) { e.useProbe(probeText(goodConf, "systemd", "u", "/b", "")) }, []string{"adopt-distro"}},
		{"adopt: WSL 1", func(e *env) {
			e.distros.list = []Distro{{Name: "Ubuntu-24.04", Version: 1, Default: true}}
			e.useProbe(goodProbe())
		}, []string{"adopt-distro"}},
		{"adopt: registry unreadable", func(e *env) {
			e.distros.list, e.distros.err = nil, errors.New("denied")
			e.useProbe(goodProbe())
		}, []string{"adopt-distro", "Ubuntu-24.04"}},
		{"adopt: registry unreadable, no name", func(e *env) { e.distros.list, e.distros.err = nil, errors.New("denied") }, []string{"adopt-distro"}},
		{"adopt: unknown name", func(e *env) {}, []string{"adopt-distro", "Nope"}},
		{"adopt: no distro", func(e *env) { e.distros.list = nil }, []string{"adopt-distro"}},
		{"adopt: probe fails", func(e *env) { t.Setenv("FAKE_WSL_MODE", "exit:1") }, []string{"adopt-distro"}},
	}
	seen := 0
	for _, s := range scenarios {
		e := newEnv(t)
		s.setup(e)
		e.run(s.args...)
		seen += assertFixLines(t, s.name, e.stdout())
	}
	if seen < 20 {
		t.Errorf("only %d WARN or FAIL lines were walked; the scenarios no longer cover the checks", seen)
	}
}
