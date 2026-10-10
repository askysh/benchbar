package main

import (
	"strings"
	"testing"
)

func envMap(m map[string]string) func(string) string {
	return func(k string) string { return m[strings.ToUpper(k)] }
}

var testEnvVars = envMap(map[string]string{"USERPROFILE": `C:\Users\u`, "SYSTEMROOT": `C:\Windows`})

func TestExpandPercent(t *testing.T) {
	cases := map[string]string{
		`%USERPROFILE%\bin`:          `C:\Users\u\bin`,
		`%userprofile%\bin`:          `C:\Users\u\bin`,
		`%NOPE%\bin`:                 `%NOPE%\bin`,
		`100%`:                       `100%`,
		`%%`:                         `%%`,
		`%SYSTEMROOT%;%USERPROFILE%`: `C:\Windows;C:\Users\u`,
		`plain`:                      `plain`,
	}
	for in, want := range cases {
		if got := expandPercent(in, testEnvVars); got != want {
			t.Errorf("expandPercent(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestAppendPathDir(t *testing.T) {
	const dir = `C:\tools\benchbar`
	cases := []struct {
		name, current, want string
		changed             bool
	}{
		{"empty", ``, dir, true},
		{"blank", `  `, dir, true},
		{"plain", `C:\a;C:\b`, `C:\a;C:\b;` + dir, true},
		{"trailing semicolon", `C:\a;`, `C:\a;` + dir, true},
		{"odd spacing kept", `C:\a ; ;C:\b;;`, `C:\a ; ;C:\b;;` + dir, true},
		{"already there", `C:\a;` + dir, `C:\a;` + dir, false},
		{"other case and slash", `C:\a;C:\TOOLS\Benchbar\`, `C:\a;C:\TOOLS\Benchbar\`, false},
		{"forward slashes", `C:/tools/benchbar`, `C:/tools/benchbar`, false},
		{"quoted", `"C:\tools\benchbar";C:\a`, `"C:\tools\benchbar";C:\a`, false},
		{"through a variable", `%USERPROFILE%\x;C:\a`, `%USERPROFILE%\x;C:\a;` + dir, true},
		{"only entry", dir, dir, false},
		{"prefix is not a match", `C:\tools\benchbar2`, `C:\tools\benchbar2;` + dir, true},
	}
	for _, c := range cases {
		got, changed := appendPathDir(c.current, dir, testEnvVars)
		if got != c.want || changed != c.changed {
			t.Errorf("%s: got %q, %v; want %q, %v", c.name, got, changed, c.want, c.changed)
		}
	}
	if got, changed := appendPathDir(`%USERPROFILE%\bin`, `C:\Users\u\bin`, testEnvVars); changed || got != `%USERPROFILE%\bin` {
		t.Errorf("variable spelling of the same folder: %q %v", got, changed)
	}
}

func TestFirstBenchbar(t *testing.T) {
	have := map[string]bool{
		`C:\Other\benchbar.exe`:          true,
		`C:\Users\u\bin\benchbar.exe`:    true,
		`C:\tools\benchbar\benchbar.exe`: true,
	}
	exists := func(p string) bool { return have[p] }
	machine := `C:\Windows;%SYSTEMROOT%\System32;C:\Other\`
	user := `%USERPROFILE%\bin;C:\tools\benchbar`
	dir, ok := firstBenchbar(machine, user, testEnvVars, exists)
	if !ok || dir != `C:\Other\` {
		t.Errorf("machine wins: %q %v", dir, ok)
	}
	dir, ok = firstBenchbar("", user, testEnvVars, exists)
	if !ok || dir != `C:\Users\u\bin` {
		t.Errorf("first user entry: %q %v", dir, ok)
	}
	if _, ok := firstBenchbar(`C:\Windows;;`, `"C:\nope"`, testEnvVars, exists); ok {
		t.Error("found a copy that is not there")
	}
}

func (e *env) pathSetup(machine, user string, existing ...string) {
	e.paths.machine = machine
	e.paths.user = PathValue{Value: user, Expand: true, Exists: true}
	e.Getenv = testEnvVars
	set := map[string]bool{}
	for _, p := range existing {
		set[p] = true
	}
	e.FileExists = func(p string) bool { return set[p] }
}

func TestPathCheck(t *testing.T) {
	e := newEnv(t)
	e.pathSetup(`C:\Windows`, `C:\tools\benchbar\`, `C:\tools\benchbar\benchbar.exe`)
	c := pathCheck(e.System)
	if c.Status != "ok" || c.Fix != "" || !strings.Contains(c.Message, `C:\tools\benchbar`) {
		t.Errorf("ok case: %+v", c)
	}

	e.pathSetup(`C:\Other`, `C:\tools\benchbar`, `C:\Other\benchbar.exe`, `C:\tools\benchbar\benchbar.exe`)
	c = pathCheck(e.System)
	if c.Status != "warn" || c.Fix != "benchbar.exe path install" || !strings.Contains(c.Message, `C:\Other\benchbar.exe`) {
		t.Errorf("other copy: %+v", c)
	}

	e.pathSetup(`C:\Windows`, `C:\a`)
	c = pathCheck(e.System)
	if c.Status != "warn" || c.Fix != "benchbar.exe path install" || !strings.Contains(c.Message, "is not on PATH") {
		t.Errorf("not found: %+v", c)
	}
}

func TestPathStatusCommand(t *testing.T) {
	e := newEnv(t)
	e.pathSetup(`C:\Windows`, `C:\a`)
	if code := e.run("path", "status"); code != 0 {
		t.Fatalf("exit %d", code)
	}
	if !strings.HasPrefix(e.stdout(), "  [WARN] PATH: ") || !strings.Contains(e.stdout(), "fix: benchbar.exe path install") {
		t.Errorf("output %q", e.stdout())
	}
	if len(e.starts()) != 0 || e.paths.setCalls != 0 {
		t.Error("status must not change anything")
	}
}

func TestPathInstall(t *testing.T) {
	e := newEnv(t)
	e.pathSetup(`C:\Windows`, `%USERPROFILE%\bin;`, `C:\tools\benchbar\benchbar.exe`)
	if code := e.run("path", "install"); code != 0 {
		t.Fatalf("exit %d: %s", code, e.stderr())
	}
	if got, want := e.paths.user.Value, `%USERPROFILE%\bin;C:\tools\benchbar`; got != want {
		t.Errorf("PATH %q want %q", got, want)
	}
	if !e.paths.user.Expand {
		t.Error("REG_EXPAND_SZ turned into REG_SZ")
	}
	if e.bcast.n != 1 {
		t.Errorf("broadcasts: %d", e.bcast.n)
	}
	for _, want := range []string{`Added C:\tools\benchbar to your user PATH`, "New terminals pick it up", "[OK] PATH"} {
		if !strings.Contains(e.stdout(), want) {
			t.Errorf("missing %q in %q", want, e.stdout())
		}
	}

	// again: nothing to do
	e.out.Reset()
	if code := e.run("path", "install"); code != 0 {
		t.Fatal(code)
	}
	if e.paths.setCalls != 1 || e.bcast.n != 1 {
		t.Errorf("second run wrote again: sets %d broadcasts %d", e.paths.setCalls, e.bcast.n)
	}
	if !strings.Contains(e.stdout(), "already on your user PATH") {
		t.Errorf("output %q", e.stdout())
	}
}

func TestPathInstallKeepsPlainStringType(t *testing.T) {
	e := newEnv(t)
	e.pathSetup(`C:\Windows`, `C:\a`)
	e.paths.user.Expand = false
	e.run("path", "install")
	if e.paths.user.Expand || e.paths.user.Value != `C:\a;C:\tools\benchbar` {
		t.Errorf("%+v", e.paths.user)
	}
}

func TestPathInstallWithNoUserPath(t *testing.T) {
	e := newEnv(t)
	e.pathSetup(`C:\Windows`, ``)
	e.paths.user = PathValue{}
	e.run("path", "install")
	if e.paths.user.Value != `C:\tools\benchbar` || !e.paths.user.Expand {
		t.Errorf("%+v", e.paths.user)
	}
}

func TestDirOf(t *testing.T) {
	for in, want := range map[string]string{
		`C:\tools\benchbar\benchbar.exe`: `C:\tools\benchbar`,
		`C:/x/y.exe`:                     `C:/x`,
		`benchbar.exe`:                   `.`,
	} {
		if got := dirOf(in); got != want {
			t.Errorf("dirOf(%q) = %q", in, got)
		}
	}
}
