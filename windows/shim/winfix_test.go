package main

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// --- distro choice -----------------------------------------------------------

func TestResolveDistroNeverPicksContainerToolDistros(t *testing.T) {
	cases := []struct {
		name    string
		list    []Distro
		want    string // distro, or "" for a problem
		problem string // text in the fix when there is one
	}{
		{"docker default, one real distro", []Distro{
			{Name: "docker-desktop", Version: 2, Default: true}, {Name: "Ubuntu", Version: 2}}, "Ubuntu", ""},
		{"docker default listed last", []Distro{
			{Name: "Debian", Version: 2}, {Name: "docker-desktop-data", Version: 2, Default: true}}, "Debian", ""},
		{"rancher default", []Distro{
			{Name: "rancher-desktop", Version: 2, Default: true}, {Name: "Ubuntu-24.04", Version: 2}}, "Ubuntu-24.04", ""},
		{"podman default", []Distro{
			{Name: "podman-machine-default", Version: 2, Default: true}, {Name: "Ubuntu-24.04", Version: 2}}, "Ubuntu-24.04", ""},
		{"only a tool distro", []Distro{{Name: "docker-desktop", Version: 2, Default: true}}, "", "adopt-distro NAME"},
		{"tool default, two real ones", []Distro{
			{Name: "docker-desktop", Version: 2, Default: true}, {Name: "Ubuntu", Version: 2}, {Name: "Debian", Version: 2}}, "", "adopt-distro NAME"},
		{"a real default stays the choice", []Distro{
			{Name: "Ubuntu", Version: 2, Default: true}, {Name: "Debian", Version: 2}}, "Ubuntu", ""},
	}
	for _, c := range cases {
		e := newEnv(t)
		e.distros.list = c.list
		name, info, prob := resolveDistro(e.System, "")
		if c.want == "" {
			if prob == nil || name != "" || info != nil || !strings.Contains(prob.Fix, c.problem) {
				t.Errorf("%s: %q %+v", c.name, name, prob)
			}
			continue
		}
		if prob != nil || name != c.want {
			t.Errorf("%s: got %q %+v, want %q", c.name, name, prob, c.want)
		}
	}
}

func TestExplicitToolDistroIsHonoured(t *testing.T) {
	e := newEnv(t)
	e.distros.list = []Distro{{Name: "docker-desktop", Version: 2, Default: true}, {Name: "Ubuntu", Version: 2}}
	if name, _, prob := resolveDistro(e.System, "docker-desktop"); name != "docker-desktop" || prob != nil {
		t.Errorf("%q %+v", name, prob)
	}
	e.writeConfig(`{"distro":"docker-desktop"}`)
	e.run("up")
	if st := e.starts(); len(st) != 1 || st[0].Distro != "docker-desktop" {
		t.Errorf("%+v", st)
	}
}

func TestForwardToolDefaultFallsBackToTheOnlyRealDistro(t *testing.T) {
	e := newEnv(t)
	e.distros.list = []Distro{{Name: "docker-desktop", Version: 2, Default: true}, {Name: "Ubuntu", Version: 2}}
	e.run("up")
	if st := e.starts(); len(st) != 1 || st[0].Distro != "Ubuntu" {
		t.Errorf("%+v", st)
	}
	e = newEnv(t)
	e.distros.list = []Distro{{Name: "docker-desktop", Version: 2, Default: true}}
	if code := e.run("up"); code != 1 || len(e.starts()) != 0 || !strings.Contains(e.stderr(), "adopt-distro NAME") {
		t.Errorf("exit %d, %q", code, e.stderr())
	}
}

// --- the distro is Ubuntu 24.04 -------------------------------------------------

func osProbe(id, ver, name string) string {
	return strings.Replace(probeOut("alice", "1000", "systemd", "yes", setupGoodConf, "/b/benchbar", "benchbar 0.8.0"),
		"osid=ubuntu\nosver=24.04\nosname=Ubuntu\n", "osid="+id+"\nosver="+ver+"\nosname="+name+"\n", 1)
}

func TestSetupCheckDistroOSBlocksADebian(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.script(
		rule("--status", 0, "ok\n"),
		rule("--version", 0, "WSL version: 2.4.8.0\n"),
		rule("--list --running --quiet", 0, "Ubuntu-24.04\n"),
		rule("--cd ~", 0, osProbe("debian", "13", "Debian GNU/Linux")),
	)
	rep := e.report()
	s := rep.step(t, "distro_os")
	if s.Status != "fail" || !s.Blocking || s.Action != nil ||
		!strings.Contains(s.Detail, "BenchBar supports Ubuntu 24.04; Ubuntu-24.04 is Debian GNU/Linux 13") ||
		!strings.Contains(s.Detail, "setup run distro_install --distro Ubuntu-24.04") || !strings.Contains(s.Detail, "adopt-distro NAME") {
		t.Errorf("%+v", s)
	}
	if rep.Ready || rep.step(t, "distro_user").Detail != "waits for distro_os" {
		t.Errorf("%+v", rep.Steps)
	}
}

func TestSetupCheckDistroOSOtherUbuntuAndUnknown(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.script(
		rule("--status", 0, "ok\n"),
		rule("--version", 0, "WSL version: 2.4.8.0\n"),
		rule("--list --running --quiet", 0, "Ubuntu-24.04\n"),
		rule("--cd ~", 0, osProbe("ubuntu", "22.04", "Ubuntu")),
	)
	if s := e.report().step(t, "distro_os"); s.Status != "fail" || !strings.Contains(s.Detail, "is Ubuntu 22.04") {
		t.Errorf("%+v", s)
	}
	e.script(
		rule("--status", 0, "ok\n"),
		rule("--version", 0, "WSL version: 2.4.8.0\n"),
		rule("--list --running --quiet", 0, "Ubuntu-24.04\n"),
		rule("--cd ~", 0, osProbe("", "", "")),
	)
	// no /etc/os-release: not a reason to stop
	if s := e.report().step(t, "distro_os"); s.Status != "warn" {
		t.Errorf("%+v", s)
	}
}

func TestAdoptDistroRefusesADebian(t *testing.T) {
	e := newEnv(t)
	e.distros.list = []Distro{{Name: "Debian", Version: 2, Default: true}}
	e.useProbe(strings.Replace(probeText(goodConf, "systemd", "akash", "/x/benchbar", "yes"),
		"osid=ubuntu\nosver=24.04\nosname=Ubuntu\n", "osid=debian\nosver=13\nosname=Debian GNU/Linux\n", 1))
	if code := e.run("adopt-distro"); code != 1 {
		t.Fatalf("exit %d", code)
	}
	out := e.stdout()
	if !strings.Contains(out, "[FAIL] Linux version: BenchBar supports Ubuntu 24.04; Debian is Debian GNU/Linux 13") ||
		!strings.Contains(out, "fix: benchbar.exe setup run distro_install --distro Ubuntu-24.04") {
		t.Errorf("output:\n%s", out)
	}
	if _, err := os.Stat(filepath.Join(e.ConfigDir, "config.json")); err == nil {
		t.Error("a distro that is not Ubuntu 24.04 was recorded")
	}
}

func TestSetupUsesTheOneUbuntu2404ThatIsThere(t *testing.T) {
	scriptFor := func(e *env, osText string, running string) {
		e.script(
			rule("--list --running --quiet", 0, running),
			rule("-d Ubuntu --exec /bin/sh", 0, osText),
			rule("--status", 0, "ok\n"),
			rule("--version", 0, "WSL version: 2.4.8.0\n"),
			rule("--cd ~", 0, probeOut("alice", "1000", "systemd", "yes", setupGoodConf, "/b/benchbar", "benchbar 0.8.0")),
		)
	}
	one := []Distro{{Name: "Ubuntu", Version: 2, Default: true}}

	e := newEnv(t)
	e.readyEnv()
	e.distros.list = one
	scriptFor(e, "ubuntu 24.04", "Ubuntu\n")
	if rep := e.report(); rep.Distro != "Ubuntu" || rep.step(t, "distro").Status != "ok" {
		t.Errorf("%q %+v", rep.Distro, rep.step(t, "distro"))
	}

	// stopped: setup check never starts it, so it keeps the old default
	e = newEnv(t)
	e.readyEnv()
	e.distros.list = one
	scriptFor(e, "ubuntu 24.04", "")
	if rep := e.report(); rep.Distro != "Ubuntu-24.04" {
		t.Errorf("stopped: %q", rep.Distro)
	}
	if hasArg(e.events(), "-d Ubuntu --exec /bin/sh") {
		t.Error("a stopped distro was started to read its release")
	}
	// with --probe it may look
	e.out.Reset()
	e.run("setup", "check", "--json", "--probe")
	if !strings.Contains(e.stdout(), `"distro":"Ubuntu"`) {
		t.Errorf("probe: %s", e.stdout())
	}

	// 22.04 is not 24.04: today's behaviour
	e = newEnv(t)
	e.readyEnv()
	e.distros.list = one
	scriptFor(e, "ubuntu 22.04", "Ubuntu\n")
	if rep := e.report(); rep.Distro != "Ubuntu-24.04" {
		t.Errorf("22.04: %q", rep.Distro)
	}

	// two distros, a distro that is not called Ubuntu, WSL 1, a configured name
	for name, list := range map[string][]Distro{
		"two":    {{Name: "Ubuntu", Version: 2}, {Name: "Debian", Version: 2}},
		"debian": {{Name: "Debian", Version: 2}},
		"wsl1":   {{Name: "Ubuntu", Version: 1}},
	} {
		e = newEnv(t)
		e.readyEnv()
		e.distros.list = list
		scriptFor(e, "ubuntu 24.04", "Ubuntu\nDebian\n")
		if rep := e.report(); rep.Distro != "Ubuntu-24.04" {
			t.Errorf("%s: %q", name, rep.Distro)
		}
		if hasArg(e.events(), "-d Debian --exec /bin/sh") || hasArg(e.events(), "-d Ubuntu --exec /bin/sh") {
			t.Errorf("%s: looked inside a distro it must not adopt", name)
		}
	}
	e = newEnv(t)
	e.readyEnv()
	e.distros.list = []Distro{{Name: "Ubuntu", Version: 2}, ubuntu}
	e.writeConfig(`{"distro":"Ubuntu"}`)
	scriptFor(e, "ubuntu 24.04", "Ubuntu\n")
	if rep := e.report(); rep.Distro != "Ubuntu" {
		t.Errorf("configured: %q", rep.Distro)
	}
	// a container tool distro next to it does not count
	e = newEnv(t)
	e.readyEnv()
	e.distros.list = []Distro{{Name: "docker-desktop", Version: 2, Default: true}, {Name: "Ubuntu", Version: 2}}
	scriptFor(e, "ubuntu 24.04", "Ubuntu\n")
	if rep := e.report(); rep.Distro != "Ubuntu" {
		t.Errorf("with docker-desktop: %q", rep.Distro)
	}
}

// --- version skew --------------------------------------------------------------

func skewEnv(t *testing.T, shim, cli string) *env {
	t.Helper()
	withVersion(t, shim)
	e := newEnv(t)
	e.readyEnv()
	e.script(
		rule("--status", 0, "ok\n"),
		rule("--version", 0, "WSL version: 2.4.8.0\n"),
		rule("--list --running --quiet", 0, "Ubuntu-24.04\n"),
		rule("--cd ~", 0, probeOut("alice", "1000", "systemd", "yes", setupGoodConf, "/b/benchbar", "benchbar "+cli)),
	)
	return e
}

func TestSetupCheckOlderCLIOffersCliInstall(t *testing.T) {
	e := skewEnv(t, "0.8.2", "0.8.1")
	rep := e.report()
	s := rep.step(t, "cli")
	if s.Status != "missing" || action(s) != "cli_install" || !s.Blocking || s.NeedsAdmin ||
		!strings.Contains(s.Detail, "benchbar 0.8.1") || !strings.Contains(s.Detail, "benchbar.exe 0.8.2") ||
		s.CLIVersion != "0.8.1" {
		t.Errorf("%+v", s)
	}
	if rep.Ready || rep.step(t, "linger").Detail != "waits for cli" {
		t.Errorf("%+v", rep)
	}
}

func TestSetupCheckSkewCases(t *testing.T) {
	// same version, a dev shim, an unreadable version and a custom cli_path never complain
	for _, c := range []struct{ shim, cli string }{{"0.8.2", "0.8.2"}, {"dev", "0.7.0"}, {"0.0.0-pr12", "0.7.0"}, {"0.8.2", "unknown"}} {
		e := skewEnv(t, c.shim, c.cli)
		if s := e.report().step(t, "cli"); s.Status != "ok" {
			t.Errorf("%+v: %+v", c, s)
		}
	}
	e := skewEnv(t, "0.8.2", "0.8.1")
	e.writeConfig(`{"cli_path":"/opt/benchbar"}`)
	if s := e.report().step(t, "cli"); s.Status != "ok" || s.Action != nil {
		t.Errorf("custom path: %+v", s)
	}
	// newer than the shim: a warning, no action, nothing blocks
	e = skewEnv(t, "0.8.2", "0.9.0")
	rep := e.report()
	if s := rep.step(t, "cli"); s.Status != "warn" || s.Action != nil || !strings.Contains(s.Detail, "newer than benchbar.exe 0.8.2") {
		t.Errorf("%+v", s)
	}
	if !rep.Ready {
		t.Error("a newer CLI must not stop the setup")
	}
}

func TestVersionCompare(t *testing.T) {
	for _, c := range []struct {
		shim, line   string
		cli          string
		older, newer bool
	}{
		{"0.8.2", "benchbar 0.8.1", "0.8.1", true, false},
		{"0.8.2", "benchbar 0.8.10", "0.8.10", false, true},
		{"0.10.0", "benchbar 0.9.9", "0.9.9", true, false},
		{"1.0.0", "benchbar 1.0.0", "1.0.0", false, false},
		{"0.8.2", "nothing here", "", false, false},
	} {
		withVersion(t, c.shim)
		cli, older, newer := cliSkew(c.line)
		if cli != c.cli || older != c.older || newer != c.newer {
			t.Errorf("%+v: %q %v %v", c, cli, older, newer)
		}
	}
}

func TestCLIInstallUpdatesAnOlderCLI(t *testing.T) {
	withVersion(t, "0.8.2")
	e := newEnv(t)
	e.readyEnv()
	e.script(
		ruleSeq("--cd ~ --exec /bin/sh",
			reply(0, probeOut("alice", "1000", "systemd", "yes", setupGoodConf, "/b/benchbar", "benchbar 0.8.1")),
			reply(0, probeOut("alice", "1000", "systemd", "yes", setupGoodConf, "/b/benchbar", "benchbar 0.8.2"))),
		rule("/bin/bash -c", 0, "Updated\n"),
	)
	if code := e.run("setup", "run", "cli_install", "--jsonl"); code != 0 {
		t.Fatalf("%d %s", code, e.stdout())
	}
	d := lastEvent(jsonLines(t, e.stdout()))
	if !d.Changed || !strings.Contains(e.stdout(), "updated benchbar from 0.8.1 to 0.8.2") {
		t.Errorf("%+v\n%s", d, e.stdout())
	}
	script := e.starts()[1].Exec[len(e.starts()[1].Exec)-1]
	if !strings.Contains(script, "--version v0.8.2") || !strings.Contains(script, "set -o pipefail") {
		t.Errorf("installer %q", script)
	}
}

func TestCLIInstallKeepsAnUpToDateOrNewerCLI(t *testing.T) {
	for _, cli := range []string{"0.8.2", "0.9.0"} {
		withVersion(t, "0.8.2")
		e := newEnv(t)
		e.readyEnv()
		e.script(rule("--cd ~ --exec /bin/sh", 0, probeOut("alice", "1000", "systemd", "yes", setupGoodConf, "/b/benchbar", "benchbar "+cli)))
		if code := e.run("setup", "run", "cli_install", "--jsonl"); code != 0 || hasArg(e.events(), "curl") {
			t.Errorf("%s: exit %d", cli, code)
		}
		if !strings.Contains(e.stdout(), `"status":"skipped"`) {
			t.Errorf("%s: %s", cli, e.stdout())
		}
	}
}

func TestCLIInstallStillOlderAfterTheInstallerFails(t *testing.T) {
	withVersion(t, "0.8.2")
	e := newEnv(t)
	e.readyEnv()
	e.script(
		rule("--cd ~ --exec /bin/sh", 0, probeOut("alice", "1000", "systemd", "yes", setupGoodConf, "/b/benchbar", "benchbar 0.8.1")),
		rule("/bin/bash -c", 0, ""),
	)
	if code := e.run("setup", "run", "cli_install", "--jsonl"); code != 1 || !strings.Contains(e.stdout(), "is still 0.8.1, not 0.8.2") {
		t.Errorf("exit %d\n%s", code, e.stdout())
	}
}

func TestDoctorWarnsAboutAnOlderCLI(t *testing.T) {
	withVersion(t, "0.8.2")
	e := newEnv(t)
	e.healthyWindows()
	e.script(
		map[string]any{"match": "head -n 1", "exit": 0, "stdout": "benchbar 0.8.1\n"},
		map[string]any{"match": "--exec", "exit": 0, "stdout": ""},
	)
	if code := e.run("doctor"); code != 0 {
		t.Fatalf("exit %d: %s", code, e.stderr())
	}
	want := "  [WARN] CLI version: benchbar 0.8.1 in Ubuntu-24.04 is older than benchbar.exe 0.8.2\n     fix: benchbar.exe setup run cli_install --distro Ubuntu-24.04\n"
	if !strings.Contains(e.stdout(), want) {
		t.Errorf("output:\n%s", e.stdout())
	}
}

func TestDoctorSkewSilentForDevAndMatching(t *testing.T) {
	withVersion(t, "dev")
	e := newEnv(t)
	e.healthyWindows()
	e.run("doctor")
	if strings.Contains(e.stdout(), "CLI version") || len(e.starts()) != 1 {
		t.Errorf("a dev build asked the distro: %d calls\n%s", len(e.starts()), e.stdout())
	}
	withVersion(t, "0.8.2")
	e = newEnv(t)
	e.healthyWindows()
	e.script(
		map[string]any{"match": "head -n 1", "exit": 0, "stdout": "benchbar 0.8.2\n"},
		map[string]any{"match": "--exec", "exit": 0, "stdout": ""},
	)
	e.run("doctor")
	if !strings.Contains(e.stdout(), "[OK] CLI version: benchbar 0.8.2 in the distro matches benchbar.exe 0.8.2") {
		t.Errorf("output:\n%s", e.stdout())
	}
}

// --- timeouts ------------------------------------------------------------------

func TestWslExecTimesOutAndSaysWhatToDo(t *testing.T) {
	e := newEnv(t)
	t.Setenv("FAKE_WSL_MODE", "sleep")
	start := time.Now()
	_, err := wslExecTimeout(e.System, time.Second, "", "--status")
	if !isWslTimeout(err) {
		t.Fatalf("err %v", err)
	}
	if time.Since(start) > 15*time.Second {
		t.Errorf("took %s", time.Since(start))
	}
	for _, want := range []string{"wsl.exe did not answer in 1 s", "wsl.exe --shutdown", "stops every WSL distro"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("missing %q in %q", want, err)
		}
	}
}

func TestWslTimeouts(t *testing.T) {
	for _, a := range [][]string{{"--status"}, {"--version"}, {"--list", "--running", "--quiet"}, {"--terminate", "x"}} {
		if wslTimeoutFor(a) != 60*time.Second {
			t.Errorf("%v: %s", a, wslTimeoutFor(a))
		}
	}
	for _, a := range [][]string{{"-d", "X", "--exec", "/bin/true"}, {"-d", "X", "-u", "root", "--exec", "id"}} {
		if wslTimeoutFor(a) != 90*time.Second {
			t.Errorf("%v: %s", a, wslTimeoutFor(a))
		}
	}
}

func TestWslTextEndsTheProcessAtTheDeadline(t *testing.T) {
	e := newEnv(t)
	t.Setenv("FAKE_WSL_MODE", "sleep")
	if _, err := wslText(e.System, time.Second, "--version"); !isWslTimeout(err) {
		t.Errorf("err %v", err)
	}
}

func TestSetupCheckWSLNotAnsweringIsNotReportedAsNotInstalled(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	t.Setenv("FAKE_WSL_MODE", "sleep")
	old := wslQuickTimeout
	wslQuickTimeout = time.Second
	t.Cleanup(func() { wslQuickTimeout = old })
	s := e.report().step(t, "wsl_feature")
	if s.Status != "fail" || s.Action != nil || !strings.Contains(s.Detail, "wsl.exe did not answer in 1 s") ||
		!strings.Contains(s.Detail, "wsl.exe --shutdown") {
		t.Errorf("%+v", s)
	}
}

func TestForwardedCommandHasNoDeadline(t *testing.T) {
	e := newEnv(t)
	old := wslQuickTimeout
	oldProbe := wslProbeTimeout
	wslQuickTimeout, wslProbeTimeout = time.Millisecond, time.Millisecond
	t.Cleanup(func() { wslQuickTimeout, wslProbeTimeout = old, oldProbe })
	t.Setenv("FAKE_WSL_MODE", "echo-stdin")
	e.Stdin = strings.NewReader("data")
	time.Sleep(10 * time.Millisecond)
	if code := e.run("up"); code != 0 {
		t.Errorf("exit %d: %s", code, e.stderr())
	}
}

// --- exit codes and failure advice ------------------------------------------------

func TestWslFailureLineAndAdvice(t *testing.T) {
	if got := wslFailureLine(0xFFFFFFFF); got != "wsl.exe itself failed (0xFFFFFFFF): run benchbar.exe setup check" {
		t.Errorf("%q", got)
	}
	if got := wslFailureLine(-1); got != "wsl.exe itself failed (0xFFFFFFFF): run benchbar.exe setup check" {
		t.Errorf("%q", got)
	}
	if got := wslFailureLine(0x80370102); !strings.HasPrefix(got, "wsl.exe itself failed (0x80370102)") {
		t.Errorf("%q", got)
	}
	if hexCode(0x80070005) != "0x80070005" || hexCode(1) != "0x00000001" {
		t.Error("hex")
	}
	for code, want := range map[uint32][]string{
		0x80370102: {"VT-x", "SVM"},
		0x80072ee7: {"network", "proxy"},
		0x80072efd: {"network", "proxy"},
		0x80072ee2: {"network", "proxy"},
		0x80070005: {"policy", "service"},
		0x80070422: {"policy", "service"},
	} {
		a := wslFailureAdvice(code)
		for _, w := range want {
			if !strings.Contains(a, w) {
				t.Errorf("%#x: %q lacks %q", code, a, w)
			}
		}
	}
	if wslFailureAdvice(0x12345678) != "" || !strings.Contains(wslInstallAdvice(0x12345678), "wsl --install --no-distribution in a terminal opened as administrator") {
		t.Error("unknown code")
	}
}

func TestControlCExitIsAnInterruptNotAWslFailure(t *testing.T) {
	for _, c := range []int{0xC000013A, -1073741510} {
		if !isControlCExit(c) {
			t.Errorf("%#x is Ctrl+C", c)
		}
	}
	for _, c := range []int{0, 1, 130, -1, 0x80370102} {
		if isControlCExit(c) {
			t.Errorf("%#x is not Ctrl+C", c)
		}
	}
}

func TestOnlyDeadlineBoundCallsGetAWaitDelay(t *testing.T) {
	e := newEnv(t)
	plain, err := wslCommand(e.System, "--update")
	if err != nil || plain.WaitDelay != 0 {
		t.Errorf("streamed calls must not have a wait delay: %v %v", plain, err)
	}
	bound, err := wslCommandContext(context.Background(), e.System, "--status")
	if err != nil || bound.WaitDelay != wslWaitDelay {
		t.Errorf("deadline bound calls have one: %v %v", bound, err)
	}
}

func TestTerminateHasItsOwnDeadline(t *testing.T) {
	if wslQuickTimeout != 60*time.Second || wslTerminateTimeout != 60*time.Second {
		t.Errorf("quick %v terminate %v", wslQuickTimeout, wslTerminateTimeout)
	}
	old := wslTerminateTimeout
	wslTerminateTimeout = 7 * time.Second
	t.Cleanup(func() { wslTerminateTimeout = old })
	if wslTimeoutFor([]string{"--terminate", "Ubuntu"}) != 7*time.Second || wslTimeoutFor([]string{"--status"}) != wslQuickTimeout {
		t.Error("terminate and quick calls have their own deadlines")
	}
}

func TestWslTimeoutMessageSaysWaitBeforeShutdown(t *testing.T) {
	m := (&wslTimeoutError{60 * time.Second}).Error()
	wait, shut := strings.Index(m, "wait a minute and run benchbar.exe setup check again"), strings.Index(m, "wsl.exe --shutdown")
	if wait < 0 || shut < wait || !strings.Contains(m, "stops every WSL distro") || !strings.Contains(m, "in 60 s") {
		t.Errorf("%q", m)
	}
}

func TestOutOfRangeIsNilForNormalCodes(t *testing.T) {
	if outOfRange(nil) != nil {
		t.Error("nil error")
	}
	cmd := exec.Command(fakeWSL)
	t.Setenv("FAKE_WSL_MODE", "exit:3")
	if outOfRange(cmd.Run()) != nil {
		t.Error("exit 3 is the CLI's")
	}
}

func TestSetupRunWslEnableFailureNamesTheCause(t *testing.T) {
	for code, want := range map[int]string{
		0x80370102: "Intel VT-x or AMD SVM",
		0x80072ee7: "network",
		0x80072efd: "network",
		0x80072ee2: "network",
		0x80070005: "policy or a stopped Windows service",
		0x80070422: "policy or a stopped Windows service",
		0x80041234: "wsl --install --no-distribution in a terminal opened as administrator",
	} {
		e := newEnv(t)
		e.readyEnv()
		e.script(rule("--status", 1, ""))
		c := code
		e.elevator().child = func([]string) int { return c }
		if exit := e.run("setup", "run", "wsl_enable", "--jsonl"); exit != 1 {
			t.Fatalf("%#x: exit %d", code, exit)
		}
		var failed string
		for _, ev := range jsonLines(t, e.stdout()) {
			if ev.Event == "step" && ev.Status == "failed" {
				failed = ev.Message
			}
		}
		if !strings.Contains(failed, hexCode(code)) || !strings.Contains(failed, want) {
			t.Errorf("%#x: %q", code, failed)
		}
		if strings.Contains(failed, "2147") || strings.Contains(failed, "21516") {
			t.Errorf("%#x: a decimal code is left: %q", code, failed)
		}
		if len(e.elevator().exes) != 1 || e.elevator().exes[0] != fakeWSL {
			t.Errorf("what was elevated changed: %v", e.elevator().exes)
		}
	}
}

// --- the installer line ----------------------------------------------------------

func TestInstallerPipeFailsWhenTheDownloadFails(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("bash on Windows can be the WSL launcher")
	}
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("no bash")
	}
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "curl"), []byte("#!/bin/sh\necho 'curl: (22) The requested URL returned error: 404' >&2\nexit 22\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, v := range []string{"0.8.2", "dev"} {
		withVersion(t, v)
		cmd := exec.Command(bash, "-c", installerPipe())
		cmd.Env = append(os.Environ(), "PATH="+dir+string(os.PathListSeparator)+os.Getenv("PATH"))
		err := cmd.Run()
		ee, ok := err.(*exec.ExitError)
		if !ok || ee.ExitCode() != 22 {
			t.Errorf("%s: a 404 must be exit 22, got %v", v, err)
		}
	}
	if !strings.HasPrefix(installerPipe(), "set -o pipefail; curl -fsSL ") {
		t.Errorf("%q", installerPipe())
	}
}

func TestCLIInstallMapsCurlExitCodes(t *testing.T) {
	cases := []struct {
		code  int
		line  string
		wants []string
	}{
		{22, "curl: (22) The requested URL returned error: 404", []string{"the release v0.8.2 is not published for this build"}},
		{6, "curl: (6) Could not resolve host: raw.githubusercontent.com", []string{"no network or DNS", "VPN", "proxy"}},
		{7, "curl: (7) Failed to connect", []string{"no network or DNS"}},
		{28, "curl: (28) Connection timed out", []string{"no network or DNS"}},
		{35, "curl: (35) TLS connect error", []string{"TLS", "certificate"}},
		{60, "curl: (60) SSL certificate problem", []string{"TLS", "certificate"}},
	}
	for _, c := range cases {
		withVersion(t, "0.8.2")
		e := newEnv(t)
		e.readyEnv()
		e.script(
			rule("--cd ~ --exec /bin/sh", 0, probeOut("alice", "1000", "systemd", "no", setupGoodConf, "", "")),
			map[string]any{"match": "/bin/bash -c", "exit": c.code, "stdout": c.line + "\n"},
		)
		e.run("setup", "run", "cli_install", "--jsonl")
		out := e.stdout()
		if !strings.Contains(out, "exit code ") || !strings.Contains(out, c.line) {
			t.Errorf("%d: the failure is not named:\n%s", c.code, out)
		}
		for _, w := range c.wants {
			if !strings.Contains(out, w) {
				t.Errorf("%d: missing %q in:\n%s", c.code, w, out)
			}
		}
	}
	// an exit code that curl did not print is the installer's own
	e := newEnv(t)
	e.readyEnv()
	e.script(
		rule("--cd ~ --exec /bin/sh", 0, probeOut("alice", "1000", "systemd", "no", setupGoodConf, "", "")),
		map[string]any{"match": "/bin/bash -c", "exit": 22, "stdout": "the installer says no\n"},
	)
	e.run("setup", "run", "cli_install", "--jsonl")
	if strings.Contains(e.stdout(), "not published") {
		t.Errorf("a curl hint without curl's own line:\n%s", e.stdout())
	}
}

func TestProxyVariablesReachTheDistro(t *testing.T) {
	e := newEnv(t)
	t.Setenv("WSLENV", "")
	t.Setenv("HTTPS_PROXY", "http://proxy:3128")
	t.Setenv("https_proxy", "http://proxy:3128")
	t.Setenv("NO_PROXY", "localhost")
	e.run("status")
	got := e.starts()[0].Wslenv
	for _, want := range []string{"HTTPS_PROXY", "https_proxy", "NO_PROXY"} {
		if !strings.Contains(got, want) {
			t.Errorf("WSLENV %q lacks %s", got, want)
		}
	}
	if strings.Contains(got, "HTTP_PROXY") && !strings.Contains(got, "HTTPS_PROXY") {
		t.Errorf("WSLENV %q", got)
	}
	if j := strings.Join(e.starts()[0].Args, " "); strings.Contains(j, "proxy:3128") {
		t.Errorf("value on the command line: %s", j)
	}
}

func TestProxyIsNotForwardedWhenNotSetAndNotToOtherCalls(t *testing.T) {
	e := newEnv(t)
	t.Setenv("WSLENV", "")
	e.run("status")
	if e.starts()[0].Wslenv != "" {
		t.Errorf("WSLENV %q", e.starts()[0].Wslenv)
	}
	e = newEnv(t)
	t.Setenv("HTTPS_PROXY", "http://proxy:3128")
	e.readyEnv()
	e.Getenv = os.Getenv // readyEnv fakes the variables of the PATH tests
	e.script(
		ruleSeq("--cd ~ --exec /bin/sh",
			reply(0, probeOut("alice", "1000", "systemd", "no", setupGoodConf, "", "")),
			reply(0, probeOut("alice", "1000", "systemd", "no", setupGoodConf, "/b/benchbar", "benchbar 0.8.0"))),
		rule("/bin/bash -c", 0, ""),
	)
	e.run("setup", "run", "cli_install", "--jsonl")
	st := e.starts()
	if len(st) != 3 {
		t.Fatalf("%d calls", len(st))
	}
	if !strings.Contains(st[1].Wslenv, "HTTPS_PROXY") {
		t.Errorf("the installer did not get the proxy: %q", st[1].Wslenv)
	}
	if strings.Contains(st[0].Wslenv, "HTTPS_PROXY") || strings.Contains(st[2].Wslenv, "HTTPS_PROXY") {
		t.Errorf("the probes got the proxy: %q %q", st[0].Wslenv, st[2].Wslenv)
	}
}

// --- Windows 10 floor ---------------------------------------------------------------

func TestWindowsBuildFloorIs19045(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.host().build = 19044
	s := e.report().step(t, "windows_build")
	if s.Status != "fail" || s.Action != nil || !strings.Contains(s.Detail, "update Windows") || !strings.Contains(s.Detail, "19045") {
		t.Errorf("%+v", s)
	}
	e.host().build = 19045
	if s := e.report().step(t, "windows_build"); s.Status != "ok" {
		t.Errorf("%+v", s)
	}
}

// --- Windows paths as arguments --------------------------------------------------------

func TestLinuxPathArg(t *testing.T) {
	cases := []struct{ in, distro, want string }{
		{`C:\Users\x\bench`, "Ubuntu-24.04", "/mnt/c/Users/x/bench"},
		{`c:/Users/x/bench`, "Ubuntu-24.04", "/mnt/c/Users/x/bench"},
		{`D:\`, "Ubuntu-24.04", "/mnt/d"},
		{`D:/`, "Ubuntu-24.04", "/mnt/d"},
		{`C:\dir\`, "Ubuntu-24.04", "/mnt/c/dir"},
		{`\\wsl.localhost\Ubuntu-24.04\home\a\bench`, "Ubuntu-24.04", "/home/a/bench"},
		{`\\wsl$\Ubuntu-24.04\home\a\bench`, "ubuntu-24.04", "/home/a/bench"},
		{`\\wsl.localhost\Ubuntu-24.04`, "Ubuntu-24.04", "/"},
		{`\\wsl.localhost\Ubuntu-24.04\`, "Ubuntu-24.04", "/"},
		{`//wsl.localhost/Ubuntu-24.04/home/a`, "Ubuntu-24.04", "/home/a"},
		{`\\wsl.localhost\Debian\home\a`, "Ubuntu-24.04", `\\wsl.localhost\Debian\home\a`},
		{`\\wsl.localhost\Ubuntu-24.04\home\a`, "", `\\wsl.localhost\Ubuntu-24.04\home\a`},
		{`C:`, "x", `C:`},
		{`C:foo`, "x", `C:foo`},
		{`a:b`, "x", `a:b`},
		{`http://example.com/x`, "x", `http://example.com/x`},
		{`/home/akash/bench`, "x", `/home/akash/bench`},
		{`relative\path`, "x", `relative\path`},
		{`\\server\share\x`, "x", `\\server\share\x`},
		{``, "x", ``},
		{`see C:\x`, "x", `see C:\x`},
	}
	for _, c := range cases {
		if got := linuxPathArg(c.in, c.distro); got != c.want {
			t.Errorf("%q (%s): %q, want %q", c.in, c.distro, got, c.want)
		}
	}
}

func TestForwardConvertsWindowsPaths(t *testing.T) {
	e := newEnv(t)
	e.run("adopt", `C:\Users\x\bench`, "--bench-dir=D:/b", "--bench-dir", `\\wsl.localhost\Ubuntu-24.04\home\a\bench`,
		"--", `E:\other`, "plain", "--msg=C:foo")
	st := e.starts()
	if len(st) != 1 {
		t.Fatalf("%d calls", len(st))
	}
	got := st[0].Exec[4:]
	want := []string{"adopt", "/mnt/c/Users/x/bench", "--bench-dir=/mnt/d/b", "--bench-dir", "/home/a/bench",
		"--", "/mnt/e/other", "plain", "--msg=C:foo"}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Errorf("args\n got %q\nwant %q", got, want)
	}
}

// --- .wslconfig networking and backups ---------------------------------------------------

func TestNetworkChecks(t *testing.T) {
	cases := []struct {
		conf   string
		status string // "" for no line
		want   string
	}{
		{"[wsl2]\nlocalhostForwarding=false\n", "warn", "localhostForwarding=false"},
		{"[wsl2]\nlocalhostForwarding = False\n", "warn", "localhostForwarding=false"},
		{"[wsl2]\nlocalhostForwarding=true\n", "", ""},
		{"[wsl2]\nnetworkingMode=bridged\n", "warn", "networkingMode=bridged"},
		{"[wsl2]\nnetworkingMode=VirtioProxy\n", "warn", "networkingMode=virtioproxy"},
		{"[wsl2]\nnetworkingMode=mirrored\n", "ok", "networkingMode=mirrored"},
		{"[wsl2]\nnetworkingMode=mirrored\nlocalhostForwarding=false\n", "ok", "networkingMode=mirrored"},
		{"[wsl2]\nnetworkingMode=nat\n", "", ""},
		{"[wsl2]\nmemory=8GB\n", "", ""},
		{"", "", ""},
	}
	for _, c := range cases {
		cs := networkChecks(parseINI([]byte(c.conf)))
		if c.status == "" {
			if len(cs) != 0 {
				t.Errorf("%q: %+v", c.conf, cs)
			}
			continue
		}
		if len(cs) != 1 || cs[0].Status != c.status || !strings.Contains(cs[0].Message, c.want) {
			t.Errorf("%q: %+v", c.conf, cs)
			continue
		}
		if c.status == "warn" && (cs[0].Fix == "" || !strings.Contains(cs[0].Message, "Windows browser")) {
			t.Errorf("%q: %+v", c.conf, cs[0])
		}
	}
}

func TestDoctorShowsNetworkWarnings(t *testing.T) {
	e := newEnv(t)
	e.healthyWindows()
	os.WriteFile(filepath.Join(e.ProfileDir, ".wslconfig"), []byte("[wsl2]\nvmIdleTimeout=-1\nlocalhostForwarding=false\n[general]\ninstanceIdleTimeout=-1\n"), 0o644)
	e.run("doctor")
	if !strings.Contains(e.stdout(), "  [WARN] WSL networking: localhostForwarding=false in .wslconfig") {
		t.Errorf("output:\n%s", e.stdout())
	}
}

func TestWslconfigBackupNeverReplacesAnEarlierOne(t *testing.T) {
	e := newEnv(t)
	path := filepath.Join(e.ProfileDir, ".wslconfig")
	os.WriteFile(path, []byte("[wsl2]\nmemory=2GB\n"), 0o644)
	e.run("wslconfig", "--apply", "--yes")
	os.WriteFile(path, []byte("[wsl2]\nmemory=1GB\n"), 0o644) // changed again within the same second
	e.run("wslconfig", "--apply", "--yes")
	b1, _ := os.ReadFile(path + ".benchbar-backup-20260102-030405")
	b2, _ := os.ReadFile(path + ".benchbar-backup-20260102-030405-1")
	if string(b1) != "[wsl2]\nmemory=2GB\n" || string(b2) != "[wsl2]\nmemory=1GB\n" {
		t.Errorf("backups %q %q", b1, b2)
	}
}

// --- keepalive -----------------------------------------------------------------------------

func TestKeepaliveWarnsWhenTheTaskRunsAnotherCopy(t *testing.T) {
	e := newEnv(t)
	e.pathSetup(`C:\Windows`, `C:\tools\benchbar`, testExe, `C:\new\benchbar.exe`)
	e.taskHandler(taskXMLOutput(installedArgs()), statusCSV)
	e.procs.add(5000, testExe)
	e.writePid(5000, 5000*1000)
	e.ExePath = `C:\new\benchbar.exe`
	info := queryKeepalive(e.System)
	c := info.Checks[0]
	if c.Status != "warn" || c.Fix != "benchbar.exe keepalive install" ||
		!strings.Contains(c.Message, testExe) || !strings.Contains(c.Message, `C:\new\benchbar.exe`) {
		t.Errorf("%+v", c)
	}
	// setup check offers the keepalive action for it
	if s := (&checker{sys: e.System, distro: "Ubuntu-24.04"}).keepaliveStep(); s.Status != "warn" || action(s) != "keepalive" {
		t.Errorf("%+v", s)
	}
	// the same copy, spelled differently, is fine
	e.ExePath = `c:/TOOLS/benchbar/BENCHBAR.exe`
	if c := queryKeepalive(e.System).Checks[0]; c.Status != "ok" {
		t.Errorf("%+v", c)
	}
}

func TestKeepaliveInstallNeedsAUserName(t *testing.T) {
	e := newEnv(t)
	e.User = ""
	if code := e.run("keepalive", "install"); code != 1 {
		t.Errorf("exit %d", code)
	}
	if len(e.tasks.calls) != 0 || !strings.Contains(e.stderr(), "cannot tell which Windows user") || !strings.Contains(e.stderr(), "fix: ") {
		t.Errorf("calls %v, stderr %q", e.tasks.calls, e.stderr())
	}
}

// --- distro_wsl2 ------------------------------------------------------------------------------

type convertAwareDistros struct{ e *env }

func (d convertAwareDistros) Distros() ([]Distro, error) {
	v := 1
	if hasArg(readEvents(d.e.t, d.e.record), "--set-version") {
		v = 2
	}
	return []Distro{{Name: "Ubuntu-24.04", Version: v, Default: true}}, nil
}

func TestSetupRunDistroWSL2(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.Distros = convertAwareDistros{e}
	e.script(rule("--list --running --quiet", 0, ""), rule("--set-version", 0, "Conversion in progress\nConversion complete.\n"))
	if code := e.run("setup", "run", "distro_wsl2", "--jsonl"); code != 0 {
		t.Fatalf("%d %s", code, e.stdout())
	}
	d := lastEvent(jsonLines(t, e.stdout()))
	if !d.Changed || strings.Join(d.NextActions, ",") != "distro_user" || d.ErrorID != "" {
		t.Errorf("%+v", d)
	}
	if !hasArg(e.events(), "--set-version Ubuntu-24.04 2") {
		t.Errorf("%+v", e.starts())
	}
	neverDestructive(t, e.events())
}

func TestSetupRunDistroWSL2RefusesARunningDistro(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.Distros = convertAwareDistros{e}
	e.script(rule("--list --running --quiet", 0, "Ubuntu-24.04\n"), rule("--set-version", 0, ""))
	if code := e.run("setup", "run", "distro_wsl2", "--jsonl"); code != 1 {
		t.Fatalf("exit %d", code)
	}
	if d := lastEvent(jsonLines(t, e.stdout())); d.ErrorID != errDistroRunning || hasArg(e.events(), "--set-version") {
		t.Errorf("%+v", d)
	}
	e.out.Reset()
	if code := e.run("setup", "run", "distro_wsl2", "--jsonl", "--force"); code != 0 || !hasArg(e.events(), "--set-version") {
		t.Errorf("--force: exit %d\n%s", code, e.stdout())
	}
}

func TestSetupRunDistroWSL2Failures(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.distros.list = []Distro{{Name: "Ubuntu-24.04", Version: 1, Default: true}}
	e.script(rule("--list --running --quiet", 0, ""), rule("--set-version", 1, "The conversion failed\n"))
	if code := e.run("setup", "run", "distro_wsl2", "--jsonl"); code != 1 || !strings.Contains(e.stdout(), "The conversion failed") {
		t.Errorf("exit %d\n%s", code, e.stdout())
	}
	// already WSL 2: nothing to do
	e = newEnv(t)
	e.readyEnv()
	e.script(rule("--list --running --quiet", 0, ""))
	if code := e.run("setup", "run", "distro_wsl2", "--jsonl"); code != 0 || !strings.Contains(e.stdout(), `"status":"skipped"`) {
		t.Errorf("exit %d\n%s", code, e.stdout())
	}
}

func TestSetupCheckRebootSaysRestartNotShutDown(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	writeRebootMarker(e.System, "wsl_enable")
	d := e.report().step(t, "reboot").Detail
	if !strings.Contains(d, "Restart") || !strings.Contains(d, "not Shut down") || !strings.Contains(d, "Fast Startup") {
		t.Errorf("%q", d)
	}
}

// --- config.json ---------------------------------------------------------------------------------

func TestConfigReadsUTF16FromWindowsPowerShell(t *testing.T) {
	e := newEnv(t)
	os.MkdirAll(e.ConfigDir, 0o755)
	enc := textEnc{utf16: true, bom: true}.encode([]byte("{\r\n  \"distro\": \"Debian\", \"cli_path\": \"benchbar\"\r\n}\r\n"))
	os.WriteFile(filepath.Join(e.ConfigDir, "config.json"), enc, 0o644)
	e.distros.list = []Distro{{Name: "Debian", Version: 2}}
	cfg, err := loadConfig(e.System)
	if err != nil || cfg.str("distro") != "Debian" {
		t.Fatalf("%v %+v", err, cfg)
	}
	e.run("up")
	if st := e.starts(); len(st) != 1 || st[0].Distro != "Debian" {
		t.Errorf("%+v", st)
	}
}

func TestInvalidConfigNamesThePathAndTheFix(t *testing.T) {
	e := newEnv(t)
	e.writeConfig("{not json")
	if code := e.run("up"); code != 1 || len(e.starts()) != 0 {
		t.Errorf("exit %d", code)
	}
	p := filepath.Join(e.ConfigDir, "config.json")
	for _, want := range []string{p, "not a JSON object", "delete it", "adopt-distro NAME"} {
		if !strings.Contains(e.stderr(), want) {
			t.Errorf("stderr lacks %q: %q", want, e.stderr())
		}
	}
}

func TestAdoptDistroNameRepairsAnInvalidConfig(t *testing.T) {
	e := newEnv(t)
	e.writeConfig("{not json")
	e.useProbe(probeText(goodConf, "systemd", "akash", "/x/benchbar", "yes"))
	// without a name there is nothing to repair with
	if code := e.run("adopt-distro"); code != 1 || !strings.Contains(e.stderr(), "adopt-distro NAME") {
		t.Errorf("exit %d, %q", code, e.stderr())
	}
	e.err.Reset()
	if code := e.run("adopt-distro", "Ubuntu-24.04"); code != 0 {
		t.Fatalf("exit %d\n%s\n%s", code, e.stdout(), e.stderr())
	}
	if got := string(e.readConfig()["distro"]); got != `"Ubuntu-24.04"` {
		t.Errorf("config %s", got)
	}
	old, err := os.ReadFile(filepath.Join(e.ConfigDir, "config.json.invalid"))
	if err != nil || string(old) != "{not json" {
		t.Errorf("the old file is not kept: %v %q", err, old)
	}
}

func TestConfigWriteIsAtomicAndKeepsNoTempFiles(t *testing.T) {
	e := newEnv(t)
	e.writeConfig(`{"keep":"me","distro":"Old"}`)
	if err := updateConfig(e.System, func(c *configFile) { c.setStr("distro", "New") }); err != nil {
		t.Fatal(err)
	}
	cfg := e.readConfig()
	if string(cfg["keep"]) != `"me"` || string(cfg["distro"]) != `"New"` {
		t.Errorf("%v", cfg)
	}
	left, _ := filepath.Glob(filepath.Join(e.ConfigDir, "config.json.tmp*"))
	if len(left) != 0 {
		t.Errorf("temp files left: %v", left)
	}
}

func TestUpdateConfigWaitsForTheLock(t *testing.T) {
	e := newEnv(t)
	e.writeConfig(`{"distro":"Old"}`)
	e.locks.held[configLockName] = true
	waits := 0
	e.Sleep = func(_ context.Context, d time.Duration) {
		waits++
		if waits == 3 {
			delete(e.locks.held, configLockName) // the tray lets go
		}
	}
	if err := updateConfig(e.System, func(c *configFile) { c.setStr("distro", "New") }); err != nil {
		t.Fatal(err)
	}
	if waits != 3 || string(e.readConfig()["distro"]) != `"New"` {
		t.Errorf("waits %d, config %v", waits, e.readConfig())
	}
	if e.locks.held[configLockName] {
		t.Error("the lock was not released")
	}
	// a lock that is never released does not stop the write
	e.locks.held[configLockName] = true
	waits = 0
	e.Sleep = func(context.Context, time.Duration) { waits++ }
	if err := updateConfig(e.System, func(c *configFile) { c.setStr("distro", "Newer") }); err != nil || waits != 20 {
		t.Errorf("%v, waits %d", err, waits)
	}
	if string(e.readConfig()["distro"]) != `"Newer"` {
		t.Errorf("%v", e.readConfig())
	}
}

// --- tray at logon ----------------------------------------------------------------------------------

func TestTrayLogonWarnsWhenWindowsTurnedItOff(t *testing.T) {
	const tray = `C:\tools\benchbar\BenchBarTray.exe`
	const lnk = `C:\Users\u\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\BenchBar Tray.lnk`
	for _, c := range []struct {
		name  string
		value []byte
		err   error
		warn  bool
	}{
		{"disabled 03", []byte{3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}, nil, true},
		{"disabled 01", []byte{1}, nil, true},
		{"enabled 02", []byte{2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}, nil, false},
		{"no value", nil, os.ErrNotExist, false},
		{"empty value", []byte{}, nil, false},
	} {
		e := newEnv(t)
		e.healthyWindows()
		vars := map[string]string{"ProgramFiles": `C:\Program Files`, "APPDATA": `C:\Users\u\AppData\Roaming`}
		e.Getenv = func(k string) string { return vars[k] }
		e.FileExists = func(p string) bool { return p == tray || p == lnk || p == testExe }
		var asked string
		e.StartupApproved = func(name string) ([]byte, error) { asked = name; return c.value, c.err }
		e.run("doctor")
		out := e.stdout()
		if asked != "BenchBar Tray.lnk" {
			t.Errorf("%s: asked for %q", c.name, asked)
		}
		if c.warn {
			if !strings.Contains(out, "  [WARN] Tray at logon: Windows has turned it off: Settings > Apps > Startup\n     fix: start ms-settings:startupapps\n") {
				t.Errorf("%s: output:\n%s", c.name, out)
			}
		} else if !strings.Contains(out, "  [OK] Tray at logon: opens at logon\n") {
			t.Errorf("%s: output:\n%s", c.name, out)
		}
	}
}

// --- path remove ------------------------------------------------------------------------------------------

func TestPathRemove(t *testing.T) {
	e := newEnv(t)
	e.pathSetup(`C:\Windows`, `C:\Users\u\bin;C:\tools\benchbar;%USERPROFILE%\x;`, testExe)
	if code := e.run("path", "remove"); code != 0 {
		t.Fatalf("exit %d: %s", code, e.stderr())
	}
	if got := e.paths.user.Value; got != `C:\Users\u\bin;%USERPROFILE%\x;` || !e.paths.user.Expand {
		t.Errorf("user PATH %q", got)
	}
	if e.bcast.n != 1 || !strings.Contains(e.stdout(), `Removed C:\tools\benchbar from your user PATH`) {
		t.Errorf("broadcasts %d, out %q", e.bcast.n, e.stdout())
	}
	// again: nothing to do, and a clear line
	e.out.Reset()
	calls := e.paths.setCalls
	if code := e.run("path", "remove"); code != 0 || e.paths.setCalls != calls || e.bcast.n != 1 ||
		!strings.Contains(e.stdout(), `C:\tools\benchbar is not on your user PATH. Nothing to remove.`) {
		t.Errorf("second run: exit %d, out %q", code, e.stdout())
	}
}

func TestPathRemoveTakesEveryEntryForTheFolderAndNoOther(t *testing.T) {
	e := newEnv(t)
	e.pathSetup(`C:\Windows`, `C:\tools\benchbar\;C:\other;c:/TOOLS/benchbar;C:\tools\benchbar2`)
	e.run("path", "remove")
	if got := e.paths.user.Value; got != `C:\other;C:\tools\benchbar2` {
		t.Errorf("user PATH %q", got)
	}
	// install then remove leaves the value as it was
	e = newEnv(t)
	e.pathSetup(`C:\Windows`, `C:\a;C:\b`)
	e.run("path", "install")
	e.run("path", "remove")
	if got := e.paths.user.Value; got != `C:\a;C:\b` {
		t.Errorf("after install and remove: %q", got)
	}
}

func TestPathRemoveReadFailure(t *testing.T) {
	e := newEnv(t)
	e.paths.userErr = os.ErrPermission
	if code := e.run("path", "remove"); code != 1 || !strings.Contains(e.stderr(), "fix: ") {
		t.Errorf("exit %d, %q", code, e.stderr())
	}
}

func TestOtherPathWordsStillGoToTheCLI(t *testing.T) {
	e := newEnv(t)
	e.run("path", "--bench-dir", "/x")
	if st := e.starts(); len(st) != 1 {
		t.Errorf("%+v", st)
	}
}

// --- the install record -------------------------------------------------------------------------------------------

func installRecordEnv(t *testing.T, manifest string, present ...string) *env {
	t.Helper()
	e := newEnv(t)
	dir := filepath.Join(e.root, "install")
	os.MkdirAll(dir, 0o755)
	if manifest != "" {
		os.WriteFile(filepath.Join(dir, ".installed-files.txt"), []byte(manifest), 0o644)
	}
	e.ExePath = filepath.Join(dir, "benchbar.exe")
	e.healthyWindows()
	have := map[string]bool{e.ExePath: true}
	for _, p := range present {
		have[dirOf(e.ExePath)+`\`+p] = true
	}
	e.FileExists = func(p string) bool { return have[p] }
	return e
}

func TestDoctorNamesAMissingTrayFromTheInstallRecord(t *testing.T) {
	e := installRecordEnv(t, "BenchBarTray.exe\r\nbenchbar.exe\r\nREADME.txt\r\n", "benchbar.exe")
	e.run("doctor")
	out := e.stdout()
	for _, want := range []string{"[WARN] Installed files: BenchBarTray.exe is missing from ", "A security product may have removed it", "Windows Security > Virus & threat protection > Protection history", "fix: restore the file"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
}

func TestDoctorNamesAMissingKeepaliveTarget(t *testing.T) {
	e := installRecordEnv(t, "\xef\xbb\xbfBenchBarTray.exe\r\nbenchbar.exe\r\n", "BenchBarTray.exe")
	// benchbar.exe itself is the missing file here, whatever the path separator of the test machine
	present := e.FileExists
	e.FileExists = func(p string) bool { return !strings.EqualFold(p, e.ExePath) && present(p) }
	args := `--headless "` + e.ExePath + `" keepalive run --distro "Ubuntu-24.04"`
	e.taskHandler(taskXMLOutput(args), statusCSV)
	e.run("doctor")
	if !strings.Contains(e.stdout(), "[WARN] Installed files: benchbar.exe is missing from ") {
		t.Errorf("output:\n%s", e.stdout())
	}
}

func TestDoctorInstallRecordQuietCases(t *testing.T) {
	// everything listed is there
	e := installRecordEnv(t, "BenchBarTray.exe\r\nbenchbar.exe\r\n", "BenchBarTray.exe", "benchbar.exe")
	e.run("doctor")
	if strings.Contains(e.stdout(), "Installed files") {
		t.Errorf("output:\n%s", e.stdout())
	}
	// no record: a copy that was not installed by the installer says nothing
	e = installRecordEnv(t, "")
	e.run("doctor")
	if strings.Contains(e.stdout(), "Installed files") {
		t.Errorf("output:\n%s", e.stdout())
	}
	// a file the record does not list is not asked for
	e = installRecordEnv(t, "benchbar.exe\r\n", "benchbar.exe")
	e.run("doctor")
	if strings.Contains(e.stdout(), "Installed files") {
		t.Errorf("output:\n%s", e.stdout())
	}
}

// --- JSON stays JSON ------------------------------------------------------------------------------------------------

func TestSetupCheckJSONHasTheNewStepAndStaysOneDocument(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.report()
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(e.out.Bytes(), &doc); err != nil {
		t.Fatalf("%v\n%s", err, e.stdout())
	}
	if !strings.Contains(e.stdout(), `"id":"distro_os"`) {
		t.Error("no distro_os step")
	}
}
