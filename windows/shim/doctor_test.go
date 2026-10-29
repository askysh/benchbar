package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func (e *env) healthyWindows() {
	e.pathSetup(`C:\Windows`, `C:\tools\benchbar`, testExe)
	e.taskNotInstalled()
	os.WriteFile(filepath.Join(e.ProfileDir, ".wslconfig"), []byte("[wsl2]\nvmIdleTimeout=-1\n[general]\ninstanceIdleTimeout=-1\n"), 0o644)
}

func TestDoctorJSONAndFixHintsPassThroughUntouched(t *testing.T) {
	for _, args := range [][]string{{"doctor", "--json"}, {"doctor", "--fix-hints"}, {"doctor", "--bench-dir", "/x", "--json"}} {
		e := newEnv(t)
		e.healthyWindows()
		if code := e.run(args...); code != 0 {
			t.Fatalf("%v: exit %d", args, code)
		}
		if e.stdout() != "" {
			t.Errorf("%v: Windows lines leaked into the output: %q", args, e.stdout())
		}
		st := e.starts()
		if len(st) != 1 || strings.Join(st[0].Exec[4:], " ") != strings.Join(args, " ") {
			t.Errorf("%v: forwarded as %+v", args, st)
		}
		if len(e.tasks.calls) != 0 {
			t.Errorf("%v: schtasks ran", args)
		}
	}
}

func TestDoctorPrintsWindowsSectionThenForwards(t *testing.T) {
	e := newEnv(t)
	e.healthyWindows()
	if code := e.run("doctor", "--bench-dir", "/x"); code != 0 {
		t.Fatalf("exit %d: %s", code, e.stderr())
	}
	out := e.stdout()
	if !strings.HasPrefix(out, "\nWINDOWS\n") {
		t.Errorf("output starts %q", out[:min(len(out), 20)])
	}
	for _, want := range []string{
		"  [OK] PATH: ",
		"  [OK] WSL distro: Ubuntu-24.04 is registered and runs WSL 2\n",
		"  [OK] .wslconfig: ",
		"  [WARN] Keepalive: not installed\n     fix: benchbar.exe keepalive install\n",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
	if !strings.HasSuffix(out, "\n\n") {
		t.Errorf("no blank line before the CLI output: %q", out)
	}
	st := e.starts()
	if len(st) != 1 || strings.Join(st[0].Exec[4:], " ") != "doctor --bench-dir /x" {
		t.Errorf("forwarded %+v", st)
	}
}

func TestDoctorWslconfigWarning(t *testing.T) {
	e := newEnv(t)
	e.healthyWindows()
	os.Remove(filepath.Join(e.ProfileDir, ".wslconfig"))
	e.run("doctor")
	if !strings.Contains(e.stdout(), "  [WARN] .wslconfig: ") || !strings.Contains(e.stdout(), "fix: benchbar.exe wslconfig --apply --yes") {
		t.Errorf("output:\n%s", e.stdout())
	}
}

func TestDoctorExitCodes(t *testing.T) {
	for _, n := range []int{0, 1, 2} {
		e := newEnv(t)
		e.healthyWindows()
		t.Setenv("FAKE_WSL_MODE", fmt.Sprintf("exit:%d", n))
		if code := e.run("doctor"); code != n {
			t.Errorf("CLI exit %d gave %d", n, code)
		}
	}

	// a FAIL in the Windows section turns a clean CLI run into 1
	e := newEnv(t)
	e.healthyWindows()
	e.distros.list = []Distro{{Name: "Ubuntu-24.04", Version: 1, Default: true}}
	if code := e.run("doctor"); code != 1 {
		t.Errorf("WSL 1 with a passing CLI gave %d, want 1", code)
	}
	if !strings.Contains(e.stdout(), "[FAIL] WSL distro: Ubuntu-24.04 runs as WSL 1") ||
		!strings.Contains(e.stdout(), "fix: wsl.exe --set-version Ubuntu-24.04 2") {
		t.Errorf("output:\n%s", e.stdout())
	}

	// the CLI's own code wins when it is not 0
	e2 := newEnv(t)
	e2.healthyWindows()
	e2.distros.list = []Distro{{Name: "Ubuntu-24.04", Version: 1, Default: true}}
	t.Setenv("FAKE_WSL_MODE", "exit:2")
	if code := e2.run("doctor"); code != 2 {
		t.Errorf("got %d, want the CLI's 2", code)
	}
}

func TestDoctorWithoutDistro(t *testing.T) {
	e := newEnv(t)
	e.healthyWindows()
	e.distros.list = nil
	if code := e.run("doctor"); code != 1 {
		t.Errorf("exit %d", code)
	}
	if !strings.Contains(e.stdout(), "[FAIL] WSL distro: no WSL distro is installed") {
		t.Errorf("output:\n%s", e.stdout())
	}
	if len(e.starts()) != 0 {
		t.Error("wsl.exe must not run without a distro")
	}
}

func TestDoctorRegistryUnreadable(t *testing.T) {
	e := newEnv(t)
	e.healthyWindows()
	e.distros.list, e.distros.err = nil, fmt.Errorf("denied")
	if code := e.run("doctor"); code != 0 {
		t.Errorf("exit %d", code)
	}
	if !strings.Contains(e.stdout(), "[WARN] WSL distro: cannot read the WSL registry") {
		t.Errorf("output:\n%s", e.stdout())
	}
	st := e.starts()
	if len(st) != 1 || st[0].Distro != "" {
		t.Errorf("starts %+v", st)
	}
}

func TestDoctorTrayChecks(t *testing.T) {
	const tray = `C:\tools\benchbar\BenchBarTray.exe`
	const lnk = `C:\Users\u\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\BenchBar Tray.lnk`
	cases := []struct {
		name  string
		files []string
		dirs  map[string][]string
		env   map[string]string
		want  []string
		not   []string
	}{
		{"no tray, no checks", []string{lnk}, nil, nil, nil, []string{"Desktop Runtime", "Tray at logon"}},
		{"runtime missing, no shortcut", []string{tray}, nil, nil, []string{
			"  [WARN] .NET Desktop Runtime: ", "fix: winget install Microsoft.DotNet.DesktopRuntime.10\n",
			"  [OK] Tray at logon: not set to open at logon\n"}, nil},
		{"runtime in Program Files, shortcut set", []string{tray, lnk},
			map[string][]string{`C:\Program Files\dotnet\shared\Microsoft.WindowsDesktop.App`: {"8.0.1", "10.0.0"}}, nil,
			[]string{"  [OK] .NET Desktop Runtime: ", "  [OK] Tray at logon: opens at logon\n"}, []string{"winget"}},
		{"only version 8", []string{tray},
			map[string][]string{`C:\Program Files\dotnet\shared\Microsoft.WindowsDesktop.App`: {"8.0.1"}}, nil,
			[]string{"  [WARN] .NET Desktop Runtime: "}, nil},
		{"DOTNET_ROOT", []string{tray},
			map[string][]string{`D:\sdk\shared\Microsoft.WindowsDesktop.App`: {"10.0.2"}},
			map[string]string{"DOTNET_ROOT": `D:\sdk\`}, []string{"  [OK] .NET Desktop Runtime: "}, []string{"winget"}},
	}
	for _, c := range cases {
		e := newEnv(t)
		e.healthyWindows()
		vars := map[string]string{"ProgramFiles": `C:\Program Files`, "APPDATA": `C:\Users\u\AppData\Roaming`}
		for k, v := range c.env {
			vars[k] = v
		}
		e.Getenv = func(k string) string { return vars[k] }
		e.FileExists = func(p string) bool {
			for _, f := range append(c.files, testExe) {
				if f == p {
					return true
				}
			}
			return false
		}
		e.ListDir = func(p string) []string { return c.dirs[p] }
		e.run("doctor")
		for _, w := range c.want {
			if !strings.Contains(e.stdout(), w) {
				t.Errorf("%s: missing %q in:\n%s", c.name, w, e.stdout())
			}
		}
		for _, w := range c.not {
			if strings.Contains(e.stdout(), w) {
				t.Errorf("%s: unexpected %q in:\n%s", c.name, w, e.stdout())
			}
		}
	}
}

func TestDoctorTrayChecksStayOutOfJSON(t *testing.T) {
	e := newEnv(t)
	e.healthyWindows()
	e.FileExists = func(p string) bool { return p == testExe || strings.HasSuffix(p, "BenchBarTray.exe") }
	e.run("doctor", "--json")
	if e.stdout() != "" {
		t.Errorf("leaked: %q", e.stdout())
	}
}
