package main

import (
	"strings"
	"testing"
)

func TestForwardPassesOnlyTheListedVariablesThroughWSLENV(t *testing.T) {
	e := newEnv(t)
	t.Setenv("ADMIN_PASSWORD", "a-secret")
	t.Setenv("BENCHBAR_SUDO", "env")
	t.Setenv("BENCHBAR_SUDO_PASSWORD", "b-secret")
	t.Setenv("OTHER_SECRET", "no")
	t.Setenv("WSLENV", "FOO/p:BAR")
	if code := e.run("status", "--json"); code != 0 {
		t.Fatalf("exit %d", code)
	}
	st := e.starts()
	if len(st) != 1 {
		t.Fatalf("%+v", st)
	}
	if got, want := st[0].Wslenv, "FOO/p:BAR:ADMIN_PASSWORD:BENCHBAR_SUDO:BENCHBAR_SUDO_PASSWORD"; got != want {
		t.Errorf("WSLENV %q, want %q", got, want)
	}
	if strings.Contains(st[0].Wslenv, "OTHER_SECRET") {
		t.Error("an unlisted variable is forwarded")
	}
	// the values are never on the command line
	if j := strings.Join(st[0].Args, " "); strings.Contains(j, "secret") {
		t.Errorf("value in the arguments: %s", j)
	}
}

// BENCHBAR_CALLER names the holder of a lease: a Windows caller (the tray, an agent running
// benchbar.exe) sets it, and the CLI in the distro must see it.
func TestForwardPassesTheLeaseHolderName(t *testing.T) {
	e := newEnv(t)
	t.Setenv("BENCHBAR_CALLER", "claude-qa")
	t.Setenv("WSLENV", "")
	if code := e.run("lease", "list", "--json"); code != 0 {
		t.Fatalf("exit %d", code)
	}
	st := e.starts()
	if len(st) != 1 {
		t.Fatalf("%+v", st)
	}
	if got := ":" + st[0].Wslenv + ":"; !strings.Contains(got, ":BENCHBAR_CALLER:") {
		t.Errorf("BENCHBAR_CALLER is not in WSLENV %q", st[0].Wslenv)
	}
	// the name travels in the environment, never on the command line
	if j := strings.Join(st[0].Args, " "); strings.Contains(j, "claude-qa") {
		t.Errorf("the holder name is in the arguments: %s", j)
	}
}

func TestForwardLeavesWSLENVAloneWhenNothingIsSet(t *testing.T) {
	for _, n := range forwardedEnv {
		t.Setenv(n, "")
	}
	e := newEnv(t)
	t.Setenv("WSLENV", "FOO/p")
	e.run("status")
	if got := e.starts()[0].Wslenv; got != "FOO/p" {
		t.Errorf("WSLENV %q", got)
	}
}

func TestForwardDoesNotDuplicateAName(t *testing.T) {
	e := newEnv(t)
	t.Setenv("ADMIN_PASSWORD", "x")
	t.Setenv("WSLENV", "admin_password/u:BENCHBAR_SUDO")
	e.run("status")
	if got := e.starts()[0].Wslenv; got != "admin_password/u:BENCHBAR_SUDO" {
		t.Errorf("WSLENV %q", got)
	}
}

func TestOtherShimCommandsDoNotForwardTheVariables(t *testing.T) {
	e := newEnv(t)
	t.Setenv("ADMIN_PASSWORD", "x")
	t.Setenv("WSLENV", "")
	e.run("adopt-distro", "--json")
	for _, ev := range e.starts() {
		if ev.Wslenv != "" {
			t.Errorf("WSLENV %q on %v", ev.Wslenv, ev.Args)
		}
	}
}

func TestWithForwardedEnvKeepsTheCallersEnvironment(t *testing.T) {
	e := newEnv(t)
	t.Setenv("BENCHBAR_NONINTERACTIVE", "1")
	in := []string{"A=1", "wslenv=X", "B=2"}
	out := withForwardedEnv(e.System, in)
	want := "A=1,B=2,WSLENV=X:BENCHBAR_NONINTERACTIVE"
	if strings.Join(out, ",") != want {
		t.Errorf("%v", out)
	}
	if strings.Join(in, ",") != "A=1,wslenv=X,B=2" {
		t.Error("the input slice was changed")
	}
}
