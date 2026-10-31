package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// --- fakes -----------------------------------------------------------------

type fakeHost struct {
	build    int
	buildErr error
	virt     bool
	virtErr  error
	boot     time.Time
	pending  bool
	admin    bool
}

func newFakeHost() *fakeHost {
	return &fakeHost{build: 26100, virt: true, boot: time.Date(2026, 1, 2, 2, 0, 0, 0, time.UTC)}
}

func (f *fakeHost) WindowsBuild() (int, error)           { return f.build, f.buildErr }
func (f *fakeHost) VirtualizationEnabled() (bool, error) { return f.virt, f.virtErr }
func (f *fakeHost) BootTime() (time.Time, error)         { return f.boot, nil }
func (f *fakeHost) RebootPending() (bool, error)         { return f.pending, nil }
func (f *fakeHost) ProductName() (string, error)         { return "Windows 11 Pro", nil }
func (f *fakeHost) IsAdmin() bool                        { return f.admin }

// fakeElevator runs the elevated child in this process, at once.
type fakeElevator struct {
	declined bool
	startErr error
	calls    [][]string
	exes     []string
	child    func(args []string) int
}

type fakeProc struct{ exit int }

func (p fakeProc) Wait(time.Duration) (bool, int, error) { return true, p.exit, nil }
func (p fakeProc) Close()                                {}

func (f *fakeElevator) Start(exe string, args []string) (ElevatedProc, error) {
	f.calls = append(f.calls, args)
	f.exes = append(f.exes, exe)
	if f.declined {
		return nil, ErrElevationDeclined
	}
	if f.startErr != nil {
		return nil, f.startErr
	}
	exit := 0
	if f.child != nil {
		exit = f.child(args)
	}
	return fakeProc{exit}, nil
}

func (e *env) host() *fakeHost         { return e.Host.(*fakeHost) }
func (e *env) elevator() *fakeElevator { return e.Elevate.(*fakeElevator) }

// elevatedChild makes the fake UAC prompt run the elevated program (the
// fake wsl.exe) with the given arguments, as Windows would, and return its
// exit code.
func (e *env) elevatedChild() {
	e.elevator().child = func(args []string) int {
		cmd, err := wslCommand(e.System, args...)
		if err != nil {
			e.t.Fatal(err)
		}
		if err := cmd.Run(); err != nil {
			if ee, ok := err.(*exec.ExitError); ok {
				return ee.ExitCode()
			}
			e.t.Fatal(err)
		}
		return 0
	}
}

// rawEvent is any event line of the setup run stream.
type rawEvent struct {
	Event          string   `json:"event"`
	ID             string   `json:"id"`
	Status         string   `json:"status"`
	Message        string   `json:"message"`
	Line           string   `json:"line"`
	Exit           int      `json:"exit"`
	Changed        bool     `json:"changed"`
	RebootRequired bool     `json:"reboot_required"`
	Cancelled      bool     `json:"cancelled"`
	ErrorID        string   `json:"error_id"`
	Warnings       []string `json:"warnings"`
	NextActions    []string `json:"next_actions"`
}

// script sets what the fake wsl.exe answers; the first matching rule wins.
func (e *env) script(rules ...map[string]any) {
	e.t.Helper()
	data, err := json.Marshal(rules)
	if err != nil {
		e.t.Fatal(err)
	}
	p := filepath.Join(e.root, "script.json")
	if err := os.WriteFile(p, data, 0o644); err != nil {
		e.t.Fatal(err)
	}
	e.t.Setenv("FAKE_WSL_MODE", "script:"+p)
}

func notProbe(match string) string {
	if match != "--version" && match != "--status" {
		return ""
	}
	return "--cd ~" // the probe script mentions --version
}

func rule(match string, exit int, stdout string) map[string]any {
	return map[string]any{"match": match, "not": notProbe(match), "exit": exit, "stdout": stdout}
}

func ruleStdin(match string, exit int) map[string]any {
	return map[string]any{"match": match, "not": notProbe(match), "exit": exit, "stdin": true}
}

func ruleSeq(match string, replies ...map[string]any) map[string]any {
	return map[string]any{"match": match, "not": notProbe(match), "seq": replies}
}

func reply(exit int, stdout string) map[string]any {
	return map[string]any{"exit": exit, "stdout": stdout}
}

func probeOut(user, uid, pid1, linger, conf, bench, ver string) string {
	return "wslconf_b64=" + base64.StdEncoding.EncodeToString([]byte(conf)) + "\n" +
		"pid1=" + pid1 + "\nuser=" + user + "\nbenchbar=" + bench + "\nlinger=" + linger + "\n" +
		"uid=" + uid + "\ncliver=" + ver + "\n"
}

const setupGoodConf = "[boot]\nsystemd=true\n"

// readyEnv is a machine where every step is ok.
func (e *env) readyEnv() {
	e.Sleep = func(context.Context, time.Duration) {}
	e.pathSetup(`C:\Windows`, `C:\tools\benchbar`, testExe)
	e.taskHandler(taskXMLOutput(installedArgs()), statusCSV)
	e.FileExists = func(p string) bool { return p == testExe || p == `C:\tools\benchbar\benchbar.exe` }
	e.procs.add(5000, testExe)
	e.writePid(5000, 5000*1000)
	os.WriteFile(filepath.Join(e.ProfileDir, ".wslconfig"), []byte("[wsl2]\nvmIdleTimeout=-1\n[general]\ninstanceIdleTimeout=-1\n"), 0o644)
	e.script(
		rule("--status", 0, "Default Distribution: Ubuntu-24.04\n"),
		rule("--version", 0, "WSL version: 2.4.8.0\nKernel version: 5.15\n"),
		rule("--list --running --quiet", 0, "Ubuntu-24.04\r\n"),
		rule("--cd ~", 0, probeOut("alice", "1000", "systemd", "yes", setupGoodConf, "/home/alice/.local/bin/benchbar", "benchbar 0.8.0")),
	)
}

func (e *env) report() setupReport {
	e.t.Helper()
	e.out.Reset()
	if code := e.run("setup", "check", "--json"); code != 0 {
		e.t.Fatalf("exit %d: %s", code, e.stderr())
	}
	var rep setupReport
	if err := json.Unmarshal(e.out.Bytes(), &rep); err != nil {
		e.t.Fatalf("%v\n%s", err, e.stdout())
	}
	return rep
}

func (r setupReport) step(t *testing.T, id string) setupStep {
	t.Helper()
	for _, s := range r.Steps {
		if s.ID == id {
			return s
		}
	}
	t.Fatalf("no step %s", id)
	return setupStep{}
}

func action(s setupStep) string {
	if s.Action == nil {
		return ""
	}
	return *s.Action
}

func hasArg(evs []fakeEvent, want string) bool {
	for _, ev := range evs {
		if ev.Event == "start" && strings.Contains(strings.Join(ev.Args, " "), want) {
			return true
		}
	}
	return false
}

// neverDestructive fails the test when the shim ran a wsl.exe command that
// removes or stops everything.
func neverDestructive(t *testing.T, evs []fakeEvent) {
	t.Helper()
	for _, ev := range evs {
		for _, a := range ev.Args {
			if a == "--unregister" || a == "--shutdown" || a == "-t" && false {
				t.Errorf("forbidden wsl.exe call: %v", ev.Args)
			}
		}
	}
}

// --- setup check -----------------------------------------------------------

var stepIDs = []string{"windows_build", "virtualization", "wsl_feature", "reboot", "wsl_version", "distro",
	"distro_user", "systemd", "cli", "linger", "keepalive", "wslconfig", "shim_path"}

func TestSetupCheckReady(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	rep := e.report()
	if !rep.Ready || rep.RebootPending || rep.Distro != "Ubuntu-24.04" || rep.SchemaVersion != 1 {
		t.Fatalf("%+v", rep)
	}
	for i, id := range stepIDs {
		if rep.Steps[i].ID != id || rep.Steps[i].Status != "ok" || rep.Steps[i].Action != nil || rep.Steps[i].NeedsAdmin {
			t.Errorf("step %d: %+v", i, rep.Steps[i])
		}
	}
	if len(rep.Steps) != len(stepIDs) {
		t.Errorf("%d steps", len(rep.Steps))
	}
	want := `{"schema_version":1,"distro":"Ubuntu-24.04","ready":true,"reboot_pending":false,"steps":[{"id":"windows_build","status":"ok","title":"Windows version","detail":"Windows build 26100","action":null,"needs_admin":false,"blocking":true},`
	if !strings.HasPrefix(e.stdout(), want) {
		t.Errorf("shape:\n%s", e.stdout())
	}
	if len(e.elevator().calls) != 0 {
		t.Error("check must never elevate")
	}
	if !hasArg(e.events(), "--cd ~") || hasArg(e.events(), "--install") {
		t.Errorf("calls: %+v", e.starts())
	}
}

func TestSetupCheckOldWindowsStopsEarly(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.host().build = 18362
	rep := e.report()
	if rep.step(t, "windows_build").Status != "fail" || rep.Ready {
		t.Errorf("%+v", rep.Steps[0])
	}
	for _, s := range rep.Steps[1:] {
		if s.Status != "missing" || s.Detail != "waits for windows_build" || s.Action != nil {
			t.Errorf("%+v", s)
		}
	}
	if len(e.events()) != 0 {
		t.Errorf("wsl.exe ran: %+v", e.starts())
	}
}

func TestSetupCheckWSLNotInstalled(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.script(rule("--status", 1, ""))
	rep := e.report()
	f := rep.step(t, "wsl_feature")
	if f.Status != "missing" || action(f) != "wsl_enable" || !f.NeedsAdmin {
		t.Errorf("%+v", f)
	}
	if rep.step(t, "reboot").Detail != "waits for wsl_feature" {
		t.Errorf("%+v", rep.step(t, "reboot"))
	}
	if rep.step(t, "virtualization").Status != "ok" {
		t.Errorf("%+v", rep.step(t, "virtualization"))
	}
}

func TestSetupCheckVirtualization(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.host().virt = false
	// WSL answers, so the flag does not matter
	if s := e.report().step(t, "virtualization"); s.Status != "ok" {
		t.Errorf("%+v", s)
	}
	e.script(rule("--status", 1, ""))
	rep := e.report()
	if s := rep.step(t, "virtualization"); s.Status != "fail" || !strings.Contains(s.Detail, "BIOS") {
		t.Errorf("%+v", s)
	}
	if rep.step(t, "wsl_feature").Detail != "waits for virtualization" {
		t.Errorf("%+v", rep.step(t, "wsl_feature"))
	}
	e.host().virtErr = os.ErrInvalid
	e.script(rule("--status", 1, ""))
	rep = e.report()
	if s := rep.step(t, "virtualization"); s.Status != "warn" {
		t.Errorf("unknown must warn: %+v", s)
	}
	if rep.step(t, "wsl_feature").Status != "missing" || action(rep.step(t, "wsl_feature")) != "wsl_enable" {
		t.Errorf("warn must not block: %+v", rep.step(t, "wsl_feature"))
	}
}

func TestSetupCheckRebootMarker(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	// WSL was enabled after the last start of Windows
	if err := writeRebootMarker(e.System, "wsl_enable"); err != nil {
		t.Fatal(err)
	}
	rep := e.report()
	r := rep.step(t, "reboot")
	if !rep.RebootPending || r.Status != "missing" || action(r) != "reboot" || rep.Ready {
		t.Errorf("%+v %+v", rep, r)
	}
	if rep.step(t, "wsl_feature").Status != "ok" || rep.step(t, "wsl_version").Detail != "waits for reboot" {
		t.Errorf("%+v", rep.Steps)
	}
	// Windows started again after that
	e.host().boot = e.Now().Add(time.Minute)
	rep = e.report()
	if rep.RebootPending || rep.step(t, "reboot").Status != "ok" {
		t.Errorf("%+v", rep)
	}
}

func TestSetupCheckOldWSL(t *testing.T) {
	for _, v := range []struct {
		name   string
		script map[string]any
	}{
		{"inbox without --version", rule("--version", 1, "")},
		{"too old for systemd", rule("--version", 0, "WSL version: 0.66.0.0\n")},
	} {
		e := newEnv(t)
		e.readyEnv()
		e.script(v.script, rule("--status", 0, ""))
		s := e.report().step(t, "wsl_version")
		if s.Status != "missing" || action(s) != "wsl_update" {
			t.Errorf("%s: %+v", v.name, s)
		}
	}
}

func TestSetupCheckDistroSteps(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.distros.list = nil
	rep := e.report()
	if s := rep.step(t, "distro"); s.Status != "missing" || action(s) != "distro_install" {
		t.Errorf("%+v", s)
	}
	if rep.step(t, "distro_user").Detail != "waits for distro" {
		t.Errorf("%+v", rep.step(t, "distro_user"))
	}
	e.distros.list = []Distro{{Name: "Ubuntu-24.04", Version: 1}}
	if s := e.report().step(t, "distro"); s.Status != "fail" || s.Action != nil || !strings.Contains(s.Detail, "--set-version") {
		t.Errorf("%+v", s)
	}
}

func TestSetupCheckStoppedDistroIsNotStarted(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.script(
		rule("--status", 0, ""),
		rule("--version", 0, "WSL version: 2.4.8.0\n"),
		rule("--list --running --quiet", 0, "There are no running distributions.\r\n"),
	)
	rep := e.report()
	if rep.Ready || rep.step(t, "distro").Status != "ok" {
		t.Errorf("%+v", rep)
	}
	for _, id := range []string{"distro_user", "systemd", "cli", "linger"} {
		s := rep.step(t, id)
		if s.Status != "warn" || !strings.HasPrefix(s.Detail, "not checked") || s.Action != nil {
			t.Errorf("%s: %+v", id, s)
		}
	}
	if hasArg(e.events(), "--cd ~") {
		t.Error("a stopped distro was started without --probe")
	}
	// with --probe it is started and checked
	e.script(
		rule("--status", 0, ""),
		rule("--version", 0, "WSL version: 2.4.8.0\n"),
		rule("--cd ~", 0, probeOut("alice", "1000", "systemd", "yes", setupGoodConf, "/b/benchbar", "benchbar 0.8.0")),
	)
	e.out.Reset()
	if code := e.run("setup", "check", "--json", "--probe"); code != 0 {
		t.Fatal(code)
	}
	if !hasArg(e.events(), "--cd ~") || strings.Contains(e.stdout(), `"warn"`) && strings.Contains(e.stdout(), "not checked") {
		t.Errorf("probe: %s", e.stdout())
	}
}

func TestSetupCheckInsideTheDistro(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.script(
		rule("--status", 0, ""),
		rule("--version", 0, "WSL version: 2.4.8.0\n"),
		rule("--list --running --quiet", 0, "Ubuntu-24.04\n"),
		rule("--cd ~", 0, probeOut("root", "0", "init", "", "", "", "")),
	)
	rep := e.report()
	if s := rep.step(t, "distro_user"); s.Status != "missing" || action(s) != "distro_user" {
		t.Errorf("%+v", s)
	}
	if rep.step(t, "systemd").Detail != "waits for distro_user" {
		t.Errorf("%+v", rep.step(t, "systemd"))
	}

	e.script(
		rule("--status", 0, ""), rule("--version", 0, "WSL version: 2.4.8.0\n"),
		rule("--list --running --quiet", 0, "Ubuntu-24.04\n"),
		rule("--cd ~", 0, probeOut("alice", "1000", "init", "no", "[boot]\nsystemd=true\n", "", "")),
	)
	rep = e.report()
	if s := rep.step(t, "systemd"); s.Status != "missing" || action(s) != "systemd" || !strings.Contains(s.Detail, "restart") {
		t.Errorf("%+v", s)
	}

	e.script(
		rule("--status", 0, ""), rule("--version", 0, "WSL version: 2.4.8.0\n"),
		rule("--list --running --quiet", 0, "Ubuntu-24.04\n"),
		rule("--cd ~", 0, probeOut("alice", "1000", "systemd", "no", setupGoodConf, "", "")),
	)
	rep = e.report()
	if s := rep.step(t, "cli"); s.Status != "missing" || action(s) != "cli_install" {
		t.Errorf("%+v", s)
	}
	if rep.step(t, "linger").Detail != "waits for cli" {
		t.Errorf("%+v", rep.step(t, "linger"))
	}
}

func TestSetupCheckLingerKeepaliveWslconfigPath(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.script(
		rule("--status", 0, ""), rule("--version", 0, "WSL version: 2.4.8.0\n"),
		rule("--list --running --quiet", 0, "Ubuntu-24.04\n"),
		rule("--cd ~", 0, probeOut("alice", "1000", "systemd", "no", setupGoodConf, "/b/benchbar", "benchbar 0.8.0")),
	)
	e.taskNotInstalled()
	os.Remove(filepath.Join(e.ProfileDir, ".wslconfig"))
	e.pathSetup(`C:\Windows`, `C:\other`)
	rep := e.report()
	for id, want := range map[string]string{"linger": "linger", "keepalive": "keepalive", "wslconfig": "wslconfig", "shim_path": "path"} {
		if s := rep.step(t, id); action(s) != want {
			t.Errorf("%s: %+v", id, s)
		}
	}
	// all four are advice only: warn, never blocking, and ready stays true
	for _, id := range []string{"linger", "keepalive", "wslconfig", "shim_path"} {
		if s := rep.step(t, id); s.Status != "warn" || s.Blocking {
			t.Errorf("%s: %+v", id, s)
		}
	}
	if !rep.Ready {
		t.Errorf("an advisory step made the setup unready: %+v", rep.Steps)
	}
}

func TestSetupCheckBlockingFlag(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	rep := e.report()
	want := map[string]bool{"windows_build": true, "virtualization": true, "wsl_feature": true, "reboot": true,
		"wsl_version": true, "distro": true, "distro_user": true, "systemd": true, "cli": true,
		"linger": false, "keepalive": false, "wslconfig": false, "shim_path": false}
	for _, s := range rep.Steps {
		if s.Blocking != want[s.ID] {
			t.Errorf("%s: blocking %v", s.ID, s.Blocking)
		}
	}
	// the waiting rows say it too
	e.host().build = 18362
	for _, s := range e.report().Steps {
		if s.Blocking != want[s.ID] {
			t.Errorf("waiting %s: blocking %v", s.ID, s.Blocking)
		}
	}
	if !strings.Contains(e.stdout(), `"blocking":false`) {
		t.Errorf("field missing: %s", e.stdout())
	}
}

func TestSetupCheckShimPathWithoutActionNamesTheFix(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	// another benchbar.exe comes first on PATH, or PATH cannot be read
	e.paths.userErr = os.ErrPermission
	rep := e.report()
	s := rep.step(t, "shim_path")
	if s.Status != "warn" || s.Blocking || rep.Ready == false {
		t.Errorf("%+v ready %v", s, rep.Ready)
	}
	if s.Action == nil && !strings.Contains(s.Detail, ": ") {
		t.Errorf("no action and no fix in the detail: %+v", s)
	}
}

func TestSetupCheckCustomCLIPathIsBlockingWithTheFixInTheDetail(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.writeConfig(`{"cli_path":"/opt/nope/benchbar"}`)
	e.script(
		rule("--status", 0, ""), rule("--version", 0, "WSL version: 2.4.8.0\n"),
		rule("--list --running --quiet", 0, "Ubuntu-24.04\n"),
		rule("--cd ~", 0, probeOut("alice", "1000", "systemd", "yes", setupGoodConf, "", "")),
	)
	s := e.report().step(t, "cli")
	if s.Status != "missing" || s.Action != nil || !s.Blocking || !strings.Contains(s.Detail, "cli_path") {
		t.Errorf("%+v", s)
	}
}

func TestSetupCheckDistroFlagAndName(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.distros.list = []Distro{{Name: "Debian", Version: 2}}
	e.out.Reset()
	e.run("setup", "check", "--json", "--distro", "Debian")
	if !strings.Contains(e.stdout(), `"distro":"Debian"`) {
		t.Errorf("%s", e.stdout())
	}
	e.err.Reset()
	if code := e.run("setup", "check", "--json", "--distro", `a" b`); code != 1 || !strings.Contains(e.stderr(), "not a usable distro name") {
		t.Errorf("%d %s", code, e.stderr())
	}
	e.writeConfig(`{"distro":"Debian"}`)
	e.out.Reset()
	e.run("setup", "check", "--json")
	if !strings.Contains(e.stdout(), `"distro":"Debian"`) {
		t.Errorf("config distro ignored: %s", e.stdout())
	}
}

func TestSetupOtherSubcommandsGoToTheCLI(t *testing.T) {
	e := newEnv(t)
	if code := e.run("setup", "something"); code != 0 {
		t.Fatal(code)
	}
	st := e.starts()
	if len(st) != 1 || strings.Join(st[0].Exec[4:], " ") != "setup something" {
		t.Errorf("%+v", st)
	}
}

// --- setup run: wsl_enable and the elevated child --------------------------

// jsonLines parses stdout as the event stream: every line is one JSON
// object, there is exactly one done event and it is last.
func jsonLines(t *testing.T, out string) []rawEvent {
	t.Helper()
	var evs []rawEvent
	for _, l := range strings.Split(strings.TrimSpace(out), "\n") {
		var ev rawEvent
		if err := json.Unmarshal([]byte(l), &ev); err != nil {
			t.Fatalf("not JSON: %q", l)
		}
		if ev.Event != "step" && ev.Event != "log" && ev.Event != "done" {
			t.Fatalf("event %q", ev.Event)
		}
		evs = append(evs, ev)
	}
	dones := 0
	for _, ev := range evs {
		if ev.Event == "done" {
			dones++
		}
	}
	if dones != 1 || evs[len(evs)-1].Event != "done" {
		t.Fatalf("done events: %d, last %q\n%s", dones, evs[len(evs)-1].Event, out)
	}
	return evs
}

func lastEvent(evs []rawEvent) rawEvent { return evs[len(evs)-1] }

func TestSetupRunWslEnableElevated(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.elevatedChild()
	// WSL does not answer before, and still not after the install
	e.script(
		rule("--status", 1, ""),
		rule("--install --no-distribution", 0, "Installing: Virtual Machine Platform\n"),
	)
	code := e.run("setup", "run", "wsl_enable", "--jsonl")
	evs := jsonLines(t, e.stdout())
	d := lastEvent(evs)
	if code != 0 || d.Exit != 0 || !d.Changed || !d.RebootRequired || strings.Join(d.NextActions, ",") != "reboot" {
		t.Fatalf("code %d, done %+v\n%s", code, d, e.stdout())
	}
	for _, ev := range evs {
		if ev.Event == "log" {
			t.Errorf("the hidden elevated wsl.exe has no output to relay: %+v", ev)
		}
	}
	// one prompt, for the system wsl.exe and nothing else, with fixed words
	el := e.elevator()
	if len(el.calls) != 1 || el.exes[0] != fakeWSL {
		t.Fatalf("%v %v", el.calls, el.exes)
	}
	if strings.Join(el.calls[0], " ") != "--install --no-distribution" {
		t.Errorf("args %v", el.calls[0])
	}
	if el.exes[0] == e.ExePath {
		t.Error("the shim must not elevate itself")
	}
	// the restart is remembered
	if !rebootMarkerPending(e.System) {
		t.Error("no reboot marker")
	}
	neverDestructive(t, e.events())
}

func TestSetupRunWslEnableNeverElevatesThePathWSL(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.elevatedChild()
	e.WSLPath = func() (string, error) { return "/somewhere/else/wsl.exe", nil }
	e.script(rule("--status", 1, ""))
	e.ElevatedWSLPath = nil
	if code := e.run("setup", "run", "wsl_enable", "--jsonl"); code != 1 {
		t.Errorf("exit %d", code)
	}
	if len(e.elevator().calls) != 0 {
		t.Error("elevated without a trusted wsl.exe")
	}
}

func TestSetupRunWslEnableSecondElevationIsRefused(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.elevatedChild()
	e.script(rule("--status", 1, ""))
	e.locks.held[wslEnableLock] = true
	code := e.run("setup", "run", "wsl_enable", "--jsonl")
	d := lastEvent(jsonLines(t, e.stdout()))
	if code != 1 || d.Exit != 1 || len(e.elevator().calls) != 0 {
		t.Errorf("code %d %+v, prompts %d", code, d, len(e.elevator().calls))
	}
	// the lock is released at the end of a normal run
	delete(e.locks.held, wslEnableLock)
	e.out.Reset()
	e.run("setup", "run", "wsl_enable", "--jsonl")
	if e.locks.held[wslEnableLock] {
		t.Error("the lock was not released")
	}
}

// slowProc is an elevated program that runs until release is closed.
type slowProc struct{ release chan struct{} }

func (p slowProc) Wait(d time.Duration) (bool, int, error) {
	select {
	case <-p.release:
		return true, 0, nil
	case <-time.After(time.Millisecond):
		return false, 0, nil
	}
}
func (p slowProc) Close() {}

type slowElevator struct {
	fakeElevator
	proc slowProc
}

func (f *slowElevator) Start(exe string, args []string) (ElevatedProc, error) {
	f.calls = append(f.calls, args)
	return f.proc, nil
}

func TestSetupRunWslEnableCancelledWhileItRuns(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.script(rule("--status", 1, ""))
	ctx, cancel := context.WithCancel(context.Background())
	el := &slowElevator{proc: slowProc{release: make(chan struct{})}}
	e.Elevate, e.Ctx = el, ctx
	cancel() // the caller stops while wsl.exe still runs
	code := e.run("setup", "run", "wsl_enable", "--jsonl")
	evs := jsonLines(t, e.stdout())
	d := lastEvent(evs)
	if code != 0 || d.Exit != 0 || !d.RebootRequired || d.Cancelled || strings.Join(d.NextActions, ",") != "reboot" {
		t.Fatalf("code %d %+v\n%s", code, d, e.stdout())
	}
	var msg string
	for _, ev := range evs {
		if ev.Event == "step" && ev.Status == "failed" {
			t.Errorf("a clean failure was reported: %+v", ev)
		}
		if ev.Event == "step" && ev.Status == "done" {
			msg = ev.Message
		}
	}
	if !strings.Contains(msg, "keeps running in Windows") || !strings.Contains(msg, "Restart Windows") {
		t.Errorf("message %q", msg)
	}
	if !rebootMarkerPending(e.System) {
		t.Error("no reboot marker")
	}
	if e.locks.held[wslEnableLock] {
		t.Error("the lock was not released")
	}
}

func TestSetupRunWslEnableWaitsForTheNaturalEnd(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.script(ruleSeq("--status", reply(1, ""), reply(0, "ok")))
	el := &slowElevator{proc: slowProc{release: make(chan struct{})}}
	e.Elevate = el
	go func() { time.Sleep(20 * time.Millisecond); close(el.proc.release) }()
	code := e.run("setup", "run", "wsl_enable", "--jsonl")
	d := lastEvent(jsonLines(t, e.stdout()))
	if code != 0 || !d.Changed || d.RebootRequired || strings.Join(d.NextActions, ",") != "wsl_update" {
		t.Errorf("code %d %+v", code, d)
	}
}

func TestSetupRunWslEnableUACCancelIsCancelled(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.script(rule("--status", 1, ""))
	e.elevator().startErr = ErrElevationDeclined
	e.run("setup", "run", "wsl_enable", "--jsonl")
	if d := lastEvent(jsonLines(t, e.stdout())); !d.Cancelled || d.Exit != 1 {
		t.Errorf("%+v", d)
	}
}

func TestSetupRunWslEnableRestartExitCodes(t *testing.T) {
	for _, code := range []int{3010, 1641} {
		e := newEnv(t)
		e.readyEnv()
		e.elevator().child = func([]string) int { return code }
		e.script(ruleSeq("--status", reply(1, ""), reply(0, "ok")))
		e.run("setup", "run", "wsl_enable", "--jsonl")
		d := lastEvent(jsonLines(t, e.stdout()))
		if !d.RebootRequired || !d.Changed || d.Exit != 0 || !rebootMarkerPending(e.System) {
			t.Errorf("exit %d: %+v", code, d)
		}
	}
}

func TestSetupRunWslEnableExitCode3010(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("exit codes above 255 exist only on Windows")
	}
	e := newEnv(t)
	e.readyEnv()
	e.elevatedChild()
	e.script(rule("--status", 1, ""), rule("--install --no-distribution", 3010, "Das angeforderte Vorgang war erfolgreich.\n"))
	if code := e.run("setup", "run", "wsl_enable", "--jsonl"); code != 0 {
		t.Fatalf("%d %s", code, e.stdout())
	}
	if d := lastEvent(jsonLines(t, e.stdout())); !d.RebootRequired || !d.Changed {
		t.Errorf("%+v", d)
	}
}

func TestSetupRunWslEnableNoRestartNeeded(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.elevatedChild()
	// parent check fails, child check fails, after the install WSL answers
	e.script(
		ruleSeq("--status", reply(1, ""), reply(0, "ok")),
		rule("--install --no-distribution", 0, "done\n"),
	)
	if code := e.run("setup", "run", "wsl_enable", "--jsonl"); code != 0 {
		t.Fatalf("%d %s", code, e.stdout())
	}
	d := lastEvent(jsonLines(t, e.stdout()))
	if d.RebootRequired || !d.Changed || strings.Join(d.NextActions, ",") != "wsl_update" {
		t.Errorf("%+v", d)
	}
	if rebootMarkerPending(e.System) {
		t.Error("marker without a restart")
	}
}

func TestSetupRunWslEnableIgnoresGenericRestartFlags(t *testing.T) {
	// the decision: an unrelated Windows Update must not report a restart
	e := newEnv(t)
	e.readyEnv()
	e.elevatedChild()
	e.host().pending = true
	e.script(
		ruleSeq("--status", reply(1, ""), reply(0, "ok")),
		rule("--install --no-distribution", 0, "done\n"),
	)
	e.run("setup", "run", "wsl_enable", "--jsonl")
	if d := lastEvent(jsonLines(t, e.stdout())); d.RebootRequired {
		t.Errorf("%+v", d)
	}
}

func TestSetupRunWslEnableStillDeadAfterInstallMeansRestart(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.elevatedChild()
	e.script(rule("--status", 1, ""), rule("--install --no-distribution", 0, "done\n"))
	e.run("setup", "run", "wsl_enable", "--jsonl")
	d := lastEvent(jsonLines(t, e.stdout()))
	if !d.RebootRequired || len(d.Warnings) != 1 {
		t.Errorf("%+v", d)
	}
}

func TestSetupRunWslEnableDeclined(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.elevator().declined = true
	e.script(rule("--status", 1, ""))
	code := e.run("setup", "run", "wsl_enable", "--jsonl")
	d := lastEvent(jsonLines(t, e.stdout()))
	if code != 1 || d.Exit != 1 || !d.Cancelled || d.Changed {
		t.Errorf("code %d %+v", code, d)
	}
	if hasArg(e.events(), "--install") {
		t.Error("wsl.exe --install ran after the prompt was declined")
	}
}

func TestSetupRunWslEnableFailure(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.elevatedChild()
	e.script(rule("--status", 1, ""), map[string]any{"match": "--install", "exit": 1, "stdout": "Error: 0x80370102\n"})
	code := e.run("setup", "run", "wsl_enable", "--jsonl")
	evs := jsonLines(t, e.stdout())
	d := lastEvent(evs)
	if code != 1 || d.Exit != 1 || d.Cancelled || d.Changed || d.RebootRequired || len(d.NextActions) != 0 {
		t.Errorf("code %d %+v", code, d)
	}
	var failed string
	for _, ev := range evs {
		if ev.Event == "step" && ev.Status == "failed" {
			failed = ev.Message
		}
	}
	if !strings.Contains(failed, "exit code 1") {
		t.Errorf("failed message %q", failed)
	}
}

func TestSetupRunWslEnableChildCrash(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.elevator().child = func([]string) int { return 5 } // writes nothing
	e.script(rule("--status", 1, ""))
	code := e.run("setup", "run", "wsl_enable", "--jsonl")
	d := lastEvent(jsonLines(t, e.stdout()))
	if code != 1 || d.Exit != 1 {
		t.Errorf("code %d %+v", code, d)
	}
}

func TestSetupRunWslEnableSkippedWhenWorking(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	if code := e.run("setup", "run", "wsl_enable", "--jsonl"); code != 0 {
		t.Fatal(code)
	}
	if len(e.elevator().calls) != 0 {
		t.Error("asked for permission although WSL works")
	}
	if d := lastEvent(jsonLines(t, e.stdout())); d.Changed {
		t.Errorf("%+v", d)
	}
}

func TestSetupRunWslEnableAlreadyAdminDoesNotPrompt(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.host().admin = true
	e.script(ruleSeq("--status", reply(1, ""), reply(0, "ok")), rule("--install --no-distribution", 0, "done\n"))
	if code := e.run("setup", "run", "wsl_enable", "--jsonl"); code != 0 {
		t.Fatalf("%d %s", code, e.stdout())
	}
	if len(e.elevator().calls) != 0 {
		t.Error("prompted although already elevated")
	}
	if d := lastEvent(jsonLines(t, e.stdout())); !d.Changed {
		t.Errorf("%+v", d)
	}
}

func TestSetupRunUsageErrorsStillEndWithDone(t *testing.T) {
	for _, args := range [][]string{
		{"setup", "run", "--jsonl"},
		{"setup", "run", "reboot", "--jsonl"},
		{"setup", "run", "format_disk", "--jsonl"},
		{"setup", "run", "wsl_update", "extra", "--jsonl"},
		{"setup", "run", "distro_user", "--user", "Root", "--jsonl"},
		{"setup", "run", "distro_user", "--user", "root", "--jsonl"},
		{"setup", "run", "linger", "--distro", "a b", "--jsonl"},
	} {
		e := newEnv(t)
		e.readyEnv()
		code := e.run(args...)
		d := lastEvent(jsonLines(t, e.stdout()))
		if code != 1 || d.Exit != 1 || len(e.events()) != 0 {
			t.Errorf("%v: code %d %+v", args, code, d)
		}
	}
}

// --- setup run: the other actions ------------------------------------------

func TestSetupRunWslUpdate(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.script(
		ruleSeq("--version", reply(0, "WSL version: 2.3.0.0\n"), reply(0, "WSL version: 2.4.8.0\n")),
		rule("--update", 0, "Checking for updates...\nThe most recent version of WSL is already installed.\n"),
	)
	if code := e.run("setup", "run", "wsl_update", "--jsonl"); code != 0 {
		t.Fatalf("%d %s", code, e.stdout())
	}
	d := lastEvent(jsonLines(t, e.stdout()))
	if !d.Changed || strings.Join(d.NextActions, ",") != "distro_install" {
		t.Errorf("%+v", d)
	}
	e2 := newEnv(t)
	e2.readyEnv()
	e2.script(rule("--version", 0, "WSL version: 2.4.8.0\n"), rule("--update", 5, "boom\n"))
	if code := e2.run("setup", "run", "wsl_update", "--jsonl"); code != 1 {
		t.Errorf("failure exit %d", code)
	}
}

// installAwareDistros lists the distro only after the fake wsl.exe was asked
// to install it.
type installAwareDistros struct{ e *env }

func (d installAwareDistros) Distros() ([]Distro, error) {
	if hasArg(readEvents(d.e.t, d.e.record), "--install") {
		return []Distro{ubuntu}, nil
	}
	return nil, nil
}

func TestSetupRunDistroInstall(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.Distros = installAwareDistros{e}
	e.script(
		rule("--install -d Ubuntu-24.04 --no-launch", 0, "Installing: Ubuntu 24.04 LTS\n"),
		rule("-u root --exec /bin/true", 0, ""),
	)
	if code := e.run("setup", "run", "distro_install", "--jsonl"); code != 0 {
		t.Fatalf("%d %s", code, e.stdout())
	}
	d := lastEvent(jsonLines(t, e.stdout()))
	if !d.Changed || strings.Join(d.NextActions, ",") != "distro_user" {
		t.Errorf("%+v", d)
	}
	if got := string(e.readConfig()["distro"]); got != `"Ubuntu-24.04"` {
		t.Errorf("config distro %s", got)
	}
	// installed without a window, then started once as root: no first run questions
	evs := e.starts()
	if len(evs) != 2 || strings.Join(evs[0].Args, " ") != "--install -d Ubuntu-24.04 --no-launch" ||
		strings.Join(evs[1].Args, " ") != "-d Ubuntu-24.04 -u root --exec /bin/true" {
		t.Errorf("%+v", evs)
	}
	neverDestructive(t, e.events())
}

func TestSetupRunDistroInstallNotRegisteredAfterwards(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.distros.list = nil
	e.script(rule("--install", 0, "ok\n"))
	if code := e.run("setup", "run", "distro_install", "--jsonl"); code != 1 {
		t.Fatalf("%d", code)
	}
	if !strings.Contains(e.stdout(), "wsl_update") {
		t.Errorf("no hint: %s", e.stdout())
	}
	if _, err := os.Stat(filepath.Join(e.ConfigDir, "config.json")); err == nil {
		t.Error("recorded a distro that is not there")
	}
}

func TestSetupRunDistroInstallAlreadyThere(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.writeConfig(`{"distro":"Ubuntu-24.04","other":1}`)
	e.script(rule("-u root --exec /bin/true", 0, ""))
	if code := e.run("setup", "run", "distro_install", "--jsonl"); code != 0 {
		t.Fatal(code)
	}
	if hasArg(e.events(), "--install") {
		t.Error("installed again")
	}
	if d := lastEvent(jsonLines(t, e.stdout())); d.Changed {
		t.Errorf("%+v", d)
	}
	if string(e.readConfig()["other"]) != "1" {
		t.Error("config keys lost")
	}
}

const (
	rReadConf  = "then cat"
	rBackup    = "cp -p"
	rWriteConf = "cat > "
)

func (e *env) withPassword(pw string) {
	prev := e.Getenv
	e.Getenv = func(k string) string {
		if k == "BENCHBAR_SETUP_PASSWORD" {
			return pw
		}
		return prev(k)
	}
}

func stdinOf(t *testing.T, evs []fakeEvent) []string {
	t.Helper()
	var out []string
	for _, ev := range evs {
		if ev.Event == "stdin" {
			b, err := base64.StdEncoding.DecodeString(ev.Stdin)
			if err != nil {
				t.Fatal(err)
			}
			out = append(out, string(b))
		}
	}
	return out
}

func TestSetupRunDistroUserCreates(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.withPassword("s3cret:pw")
	e.script(
		rule("/usr/bin/id -u", 1, ""),
		rule("/usr/sbin/useradd", 0, ""),
		ruleStdin("/usr/sbin/chpasswd", 0),
		rule(rReadConf, 3, ""),
		rule(rBackup, 0, ""),
		ruleStdin(rWriteConf, 0),
		rule("--terminate Ubuntu-24.04", 0, ""),
	)
	code := e.run("setup", "run", "distro_user", "--user", "alice", "--jsonl")
	if code != 0 {
		t.Fatalf("%d %s", code, e.stdout())
	}
	d := lastEvent(jsonLines(t, e.stdout()))
	if !d.Changed || strings.Join(d.NextActions, ",") != "systemd" {
		t.Errorf("%+v", d)
	}
	in := stdinOf(t, e.events())
	if len(in) != 2 || in[0] != "alice:s3cret:pw\n" || in[1] != "[user]\ndefault=alice\n" {
		t.Errorf("stdin %q", in)
	}
	// the password is on stdin only
	for _, ev := range e.events() {
		if strings.Contains(strings.Join(ev.Args, " "), "s3cret") {
			t.Errorf("password in a command line: %v", ev.Args)
		}
	}
	for _, s := range []string{e.stdout(), e.stderr()} {
		if strings.Contains(s, "s3cret") {
			t.Errorf("password printed: %s", s)
		}
	}
	all := strings.Join(func() (l []string) {
		for _, ev := range e.starts() {
			l = append(l, strings.Join(ev.Args, " "))
		}
		return
	}(), "\n")
	for _, want := range []string{
		"-d Ubuntu-24.04 -u root --exec /usr/sbin/useradd -m -s /bin/bash -G sudo alice",
		"-d Ubuntu-24.04 -u root --exec /usr/sbin/chpasswd",
		"--terminate Ubuntu-24.04",
	} {
		if !strings.Contains(all, want) {
			t.Errorf("missing call %q in\n%s", want, all)
		}
	}
	neverDestructive(t, e.events())
}

func TestSetupRunDistroUserKeepsTheRestOfWslConf(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.withPassword("pw")
	conf := "# mine\n[boot]\nsystemd=true\n[interop]\nenabled=false\n[user]\ndefault=root\n"
	e.script(
		rule("/usr/bin/id -u", 0, "1000\n"),
		rule("/usr/sbin/usermod", 0, ""),
		rule(rReadConf, 0, conf),
		rule(rBackup, 0, ""),
		ruleStdin(rWriteConf, 0),
		rule("--terminate", 0, ""),
	)
	if code := e.run("setup", "run", "distro_user", "--user", "alice", "--jsonl"); code != 0 {
		t.Fatalf("%d %s", code, e.stdout())
	}
	in := stdinOf(t, e.events())
	want := "# mine\n[boot]\nsystemd=true\n[interop]\nenabled=false\n[user]\ndefault=alice\n"
	if len(in) != 1 || in[0] != want {
		t.Errorf("wsl.conf %q", in)
	}
	// an existing user keeps their password
	if hasArg(e.events(), "chpasswd") || hasArg(e.events(), "useradd") {
		t.Error("changed an existing user")
	}
	// the old file was copied first
	var order []string
	for _, ev := range e.starts() {
		j := strings.Join(ev.Args, " ")
		switch {
		case strings.Contains(j, "cp -p"):
			order = append(order, "backup")
		case strings.Contains(j, "cat > "):
			order = append(order, "write")
		}
	}
	if strings.Join(order, ",") != "backup,write" {
		t.Errorf("order %v", order)
	}
	if !hasArg(e.events(), "/etc/wsl.conf 20260102-030405-4242") || !hasArg(e.events(), "while [ -e") {
		t.Errorf("backup stamp: %+v", e.starts())
	}
}

func TestSetupRunDistroUserAlreadyDone(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.script(
		rule("/usr/bin/id -u", 0, "1000\n"),
		rule("/usr/sbin/usermod", 0, ""),
		rule(rReadConf, 0, "[user]\ndefault=alice\n"),
	)
	if code := e.run("setup", "run", "distro_user", "--user", "alice", "--jsonl"); code != 0 {
		t.Fatal(code)
	}
	if hasArg(e.events(), "--terminate") || hasArg(e.events(), "cat > ") {
		t.Error("changed something that was already right")
	}
	if d := lastEvent(jsonLines(t, e.stdout())); d.Changed {
		t.Errorf("%+v", d)
	}
}

func TestSetupRunDistroUserNeedsAPassword(t *testing.T) {
	for _, pw := range []string{"", "a\nb"} {
		e := newEnv(t)
		e.readyEnv()
		e.withPassword(pw)
		e.script(rule("/usr/bin/id -u", 1, ""))
		if code := e.run("setup", "run", "distro_user", "--user", "alice", "--jsonl"); code != 1 {
			t.Errorf("%q: exit %d", pw, code)
		}
		if hasArg(e.events(), "useradd") {
			t.Errorf("%q: created a user without a usable password", pw)
		}
	}
}

func TestSetupRunDistroUserDefaultName(t *testing.T) {
	e := newEnv(t) // the fake Windows user is PC\tester
	e.readyEnv()
	e.withPassword("pw")
	e.script(rule("/usr/bin/id -u", 1, ""), rule("useradd", 0, ""), ruleStdin("chpasswd", 0),
		rule(rReadConf, 3, ""), rule(rBackup, 0, ""), ruleStdin(rWriteConf, 0), rule("--terminate", 0, ""))
	e.run("setup", "run", "distro_user", "--jsonl")
	if in := stdinOf(t, e.events()); len(in) == 0 || in[0] != "tester:pw\n" {
		t.Errorf("%q", in)
	}
}

func TestDefaultLinuxUser(t *testing.T) {
	for in, want := range map[string]string{
		`PC\Tester`:                     "tester",
		`DOMAIN\Anna.Lee`:               "anna_lee",
		`PC\Äkash Mishra`:               "kash_mishra",
		`PC\1st-User`:                   "u1st-user",
		`PC\-x`:                         "u-x",
		`PC\root`:                       "bench",
		``:                              "bench",
		`PC\日本`:                         "bench",
		`PC\` + strings.Repeat("a", 40): strings.Repeat("a", 32),
	} {
		got := defaultLinuxUser(in)
		if got != want {
			t.Errorf("%q: got %q, want %q", in, got, want)
		}
		if !validLinuxUser(got) {
			t.Errorf("%q: %q is not a valid user", in, got)
		}
	}
}

func TestSetupRunSystemd(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.script(
		rule(rReadConf, 0, "[interop]\nenabled=true\n"),
		rule(rBackup, 0, ""),
		ruleStdin(rWriteConf, 0),
		rule("--terminate Ubuntu-24.04", 0, ""),
		ruleSeq("/proc/1/comm", reply(0, "init\n"), reply(0, "init\n"), reply(0, "systemd\n")),
	)
	if code := e.run("setup", "run", "systemd", "--jsonl"); code != 0 {
		t.Fatalf("%d %s", code, e.stdout())
	}
	d := lastEvent(jsonLines(t, e.stdout()))
	if !d.Changed || strings.Join(d.NextActions, ",") != "cli_install" {
		t.Errorf("%+v", d)
	}
	in := stdinOf(t, e.events())
	if len(in) != 1 || in[0] != "[interop]\nenabled=true\n\n[boot]\nsystemd=true\n" {
		t.Errorf("wsl.conf %q", in)
	}
	// only this distro is stopped, and it is never a shutdown
	for _, ev := range e.starts() {
		j := strings.Join(ev.Args, " ")
		if strings.Contains(j, "--terminate") && j != "--terminate Ubuntu-24.04" {
			t.Errorf("terminate call %q", j)
		}
	}
	neverDestructive(t, e.events())
}

func TestSetupRunSystemdAlreadyRunning(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.script(rule(rReadConf, 0, setupGoodConf), rule("/proc/1/comm", 0, "systemd\n"))
	if code := e.run("setup", "run", "systemd", "--jsonl"); code != 0 {
		t.Fatal(code)
	}
	if hasArg(e.events(), "--terminate") {
		t.Error("restarted a distro that already runs systemd")
	}
	if d := lastEvent(jsonLines(t, e.stdout())); d.Changed {
		t.Errorf("%+v", d)
	}
}

func TestSetupRunSystemdNeverComesUp(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.script(rule(rReadConf, 0, setupGoodConf), rule("--terminate", 0, ""), rule("/proc/1/comm", 0, "init\n"))
	if code := e.run("setup", "run", "systemd", "--jsonl"); code != 1 {
		t.Errorf("exit %d", code)
	}
}

func TestSetupRunCLIInstall(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.script(
		ruleSeq("--cd ~ --exec /bin/sh",
			reply(0, probeOut("alice", "1000", "systemd", "no", setupGoodConf, "", "")),
			reply(0, probeOut("alice", "1000", "systemd", "no", setupGoodConf, "/home/alice/.local/bin/benchbar", "benchbar 0.8.0"))),
		rule("/bin/bash -c", 0, "Cloning...\nInstalled benchbar\n"),
	)
	if code := e.run("setup", "run", "cli_install", "--jsonl"); code != 0 {
		t.Fatalf("%d %s", code, e.stdout())
	}
	evs := jsonLines(t, e.stdout())
	if d := lastEvent(evs); !d.Changed || strings.Join(d.NextActions, ",") != "linger" {
		t.Errorf("%+v", d)
	}
	found := false
	for _, ev := range evs {
		if ev.Event == "log" && ev.Line == "Installed benchbar" {
			found = true
		}
	}
	if !found {
		t.Error("installer output not streamed as log events")
	}
	want := `-d Ubuntu-24.04 --cd ~ --exec /bin/bash -c curl -fsSL ` + installerURL + ` | bash`
	if got := e.starts()[1].Args; strings.Join(got, " ") != want {
		t.Errorf("installer call %q", strings.Join(got, " "))
	}
}

func TestSetupRunCLIInstallRefusals(t *testing.T) {
	// root is the default user
	e := newEnv(t)
	e.readyEnv()
	e.script(rule("--cd ~", 0, probeOut("root", "0", "systemd", "", setupGoodConf, "", "")))
	if code := e.run("setup", "run", "cli_install", "--jsonl"); code != 1 || hasArg(e.events(), "curl") {
		t.Errorf("root: exit %d", code)
	}
	// already installed
	e = newEnv(t)
	e.readyEnv()
	if code := e.run("setup", "run", "cli_install", "--jsonl"); code != 0 || hasArg(e.events(), "curl") {
		t.Errorf("installed: exit %d", code)
	}
	// the installer ends well but nothing is installed (curl failed inside the pipe)
	e = newEnv(t)
	e.readyEnv()
	e.script(rule("/bin/bash -c", 0, ""), rule("--cd ~ --exec /bin/sh", 0, probeOut("alice", "1000", "systemd", "no", setupGoodConf, "", "")))
	if code := e.run("setup", "run", "cli_install", "--jsonl"); code != 1 {
		t.Errorf("silent failure: exit %d", code)
	}
}

func TestSetupRunLinger(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.script(
		ruleSeq("--cd ~ --exec /bin/sh",
			reply(0, probeOut("alice", "1000", "systemd", "no", setupGoodConf, "/b/benchbar", "benchbar 0.8.0")),
			reply(0, probeOut("alice", "1000", "systemd", "yes", setupGoodConf, "/b/benchbar", "benchbar 0.8.0"))),
		rule("-u root --exec /usr/bin/loginctl enable-linger alice", 0, ""),
	)
	if code := e.run("setup", "run", "linger", "--jsonl"); code != 0 {
		t.Fatalf("%d %s", code, e.stdout())
	}
	if d := lastEvent(jsonLines(t, e.stdout())); !d.Changed || strings.Join(d.NextActions, ",") != "keepalive" {
		t.Errorf("%+v", d)
	}
	// already on
	e = newEnv(t)
	e.readyEnv()
	if code := e.run("setup", "run", "linger", "--jsonl"); code != 0 || hasArg(e.events(), "enable-linger") {
		t.Errorf("already on: %d", code)
	}
	// refused
	e = newEnv(t)
	e.readyEnv()
	e.script(rule("--cd ~", 0, probeOut("alice", "1000", "init", "no", "", "/b/benchbar", "")), rule("enable-linger", 1, ""))
	if code := e.run("setup", "run", "linger", "--jsonl"); code != 1 {
		t.Errorf("refused: %d", code)
	}
}

func TestSetupRunKeepaliveWslconfigPath(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.tasks.handler = func(a []string) (string, int, error) {
		if a[0] == "/Query" {
			return "ERROR: The system cannot find the file specified.\r\n", 1, nil
		}
		return "", 0, nil
	}
	os.Remove(filepath.Join(e.ProfileDir, ".wslconfig"))
	e.pathSetup(`C:\Windows`, `C:\other`, `C:\tools\benchbar\benchbar.exe`)
	e.script(rule("", 0, ""))

	if code := e.run("setup", "run", "keepalive", "--jsonl"); code != 0 {
		t.Fatalf("keepalive %d %s", code, e.stdout())
	}
	var creates int
	for _, c := range e.tasks.calls {
		if c[0] == "/Create" {
			creates++
		}
	}
	if creates != 1 {
		t.Errorf("schtasks calls %v", e.tasks.calls)
	}

	e.out.Reset()
	if code := e.run("setup", "run", "wslconfig", "--jsonl"); code != 0 {
		t.Fatalf("wslconfig %d %s", code, e.stdout())
	}
	d := lastEvent(jsonLines(t, e.stdout()))
	if !d.Changed || len(d.Warnings) != 1 || !strings.Contains(d.Warnings[0], "does not run wsl.exe --shutdown") {
		t.Errorf("%+v", d)
	}
	data, err := os.ReadFile(filepath.Join(e.ProfileDir, ".wslconfig"))
	if err != nil || !strings.Contains(string(data), "vmIdleTimeout=-1") {
		t.Errorf(".wslconfig: %v %q", err, data)
	}

	e.out.Reset()
	if code := e.run("setup", "run", "path", "--jsonl"); code != 0 {
		t.Fatalf("path %d %s", code, e.stdout())
	}
	if e.paths.setCalls != 1 || !strings.Contains(e.paths.user.Value, `C:\tools\benchbar`) {
		t.Errorf("path %+v", e.paths)
	}
	if d := lastEvent(jsonLines(t, e.stdout())); !d.Changed {
		t.Errorf("%+v", d)
	}
	neverDestructive(t, e.events())
}

func TestSetupRunDoneAlwaysHasArrays(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.run("setup", "run", "linger", "--jsonl")
	out := strings.TrimSpace(e.stdout())
	last := out[strings.LastIndex(out, "\n")+1:]
	for _, want := range []string{`"event":"done"`, `"warnings":[]`, `"next_actions":["keepalive"]`, `"cancelled":false`} {
		if !strings.Contains(last, want) {
			t.Errorf("done line %s lacks %s", last, want)
		}
	}
}

func TestSetupRunPlainTextWithoutJSONL(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	if code := e.run("setup", "run", "linger"); code != 0 {
		t.Fatal(code)
	}
	if strings.Contains(e.stdout(), `{"event"`) || !strings.Contains(e.stdout(), "[skipped] linger:") {
		t.Errorf("%s", e.stdout())
	}
}

func TestSetupNeverRunsDestructiveWSL(t *testing.T) {
	// every action, in one machine that needs everything
	for id := range setupActions {
		e := newEnv(t)
		e.readyEnv()
		e.elevatedChild()
		e.withPassword("pw")
		e.script(rule("", 0, "ok\n"))
		e.run("setup", "run", id, "--jsonl")
		neverDestructive(t, e.events())
		for _, ev := range e.starts() {
			j := strings.Join(ev.Args, " ")
			if strings.Contains(j, "/mnt/c") || strings.Contains(j, `C:\`) {
				t.Errorf("%s: a path on C: in %q", id, j)
			}
		}
	}
}

// --- helpers ---------------------------------------------------------------

func TestWslVersionOK(t *testing.T) {
	for in, want := range map[string]bool{
		"WSL version: 2.4.8.0\nKernel": true,
		"WSL-Version: 1.0.0.0":         true,
		"WSL version: 0.67.6.0":        true,
		"WSL version: 0.67.5.0":        false,
		"WSL version: 0.66.0.0":        false,
		"nothing":                      false,
		"":                             false,
	} {
		if _, got := wslVersionOK(in); got != want {
			t.Errorf("%q: %v", in, got)
		}
	}
}

func TestLineWriter(t *testing.T) {
	var got []string
	w := &lineWriter{emit: func(s string) { got = append(got, s) }}
	w.Write([]byte("one\r\ntw"))
	w.Write([]byte("o\rprogress 10%\rprogress 20%\r\n\n\x00 three\x07\n"))
	w.Write([]byte("tail"))
	w.Flush()
	want := []string{"one", "two", "progress 10%", "progress 20%", "three", "tail"}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Errorf("%q", got)
	}
}

// --- a running distro is not stopped without --force -----------------------

func doneErrorID(t *testing.T, out string) rawEvent {
	t.Helper()
	return lastEvent(jsonLines(t, out))
}

func TestSetupRunSystemdRefusesARunningDistro(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.script(
		rule("--list --running --quiet", 0, "Ubuntu-24.04\r\n"),
		rule(rReadConf, 0, "[interop]\nenabled=true\n"),
		rule("/proc/1/comm", 0, "init\n"),
	)
	code := e.run("setup", "run", "systemd", "--jsonl")
	d := doneErrorID(t, e.stdout())
	if code != 1 || d.Exit != 1 || d.ErrorID != "distro_running" || d.Changed {
		t.Fatalf("code %d %+v", code, d)
	}
	var msg string
	for _, ev := range jsonLines(t, e.stdout()) {
		if ev.Event == "step" && ev.Status == "failed" {
			msg = ev.Message
		}
	}
	if !strings.Contains(msg, "benches") || !strings.Contains(msg, "MariaDB") || !strings.Contains(msg, "--force") {
		t.Errorf("message %q", msg)
	}
	if hasArg(e.events(), "--terminate") || hasArg(e.events(), "cat > ") {
		t.Error("changed a running distro without --force")
	}
}

func TestSetupRunSystemdForceStopsARunningDistro(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.script(
		rule("--list --running --quiet", 0, "Ubuntu-24.04\r\n"),
		rule(rReadConf, 0, "[interop]\nenabled=true\n"),
		rule(rBackup, 0, ""),
		ruleStdin(rWriteConf, 0),
		rule("--terminate Ubuntu-24.04", 0, ""),
		ruleSeq("/proc/1/comm", reply(0, "init\n"), reply(0, "init\n"), reply(0, "systemd\n")),
	)
	if code := e.run("setup", "run", "systemd", "--force", "--jsonl"); code != 0 {
		t.Fatalf("%d %s", code, e.stdout())
	}
	if d := doneErrorID(t, e.stdout()); d.ErrorID != "" || !d.Changed {
		t.Errorf("%+v", d)
	}
	if !hasArg(e.events(), "--terminate Ubuntu-24.04") {
		t.Error("did not stop the distro")
	}
}

func TestSetupRunSystemdRunningButNothingToDoNeedsNoForce(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.script(rule("--list --running --quiet", 0, "Ubuntu-24.04\r\n"), rule(rReadConf, 0, setupGoodConf), rule("/proc/1/comm", 0, "systemd\n"))
	if code := e.run("setup", "run", "systemd", "--jsonl"); code != 0 {
		t.Fatalf("%d %s", code, e.stdout())
	}
}

func TestSetupRunDistroUserRefusesARunningDistroBeforeChangingAnything(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.withPassword("pw")
	e.script(
		rule("--list --running --quiet", 0, "Ubuntu-24.04\r\n"),
		rule("/usr/bin/id -u", 1, ""),
		rule(rReadConf, 3, ""),
	)
	code := e.run("setup", "run", "distro_user", "--user", "alice", "--jsonl")
	d := doneErrorID(t, e.stdout())
	if code != 1 || d.ErrorID != "distro_running" {
		t.Fatalf("code %d %+v", code, d)
	}
	for _, w := range []string{"useradd", "chpasswd", "cat > ", "--terminate"} {
		if hasArg(e.events(), w) {
			t.Errorf("%s ran before the refusal", w)
		}
	}
}

func TestSetupRunDistroUserStoppedDistroNeedsNoForce(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.withPassword("pw")
	e.script(
		rule("--list --running --quiet", 0, "\r\n"),
		rule("/usr/bin/id -u", 1, ""), rule("useradd", 0, ""), ruleStdin("chpasswd", 0),
		rule(rReadConf, 3, ""), rule(rBackup, 0, ""), ruleStdin(rWriteConf, 0), rule("--terminate", 0, ""),
	)
	if code := e.run("setup", "run", "distro_user", "--user", "alice", "--jsonl"); code != 0 {
		t.Fatalf("%d %s", code, e.stdout())
	}
}

func TestSetupRunOtherFailuresHaveNoErrorID(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.script(rule("--status", 1, ""))
	e.host().admin = true
	e.script(rule("--status", 1, ""), rule("--install", 1, "boom\n"))
	e.run("setup", "run", "wsl_enable", "--jsonl")
	if strings.Contains(e.stdout(), "error_id") {
		t.Errorf("error_id on an unrelated failure: %s", e.stdout())
	}
}

// --- distro_install and cli_install ----------------------------------------

func TestSetupRunDistroInstallNeedsRestart(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("exit codes above 255 exist only on Windows")
	}
	e := newEnv(t)
	e.readyEnv()
	e.distros.list = nil
	e.script(rule("--install -d Ubuntu-24.04", 3010, "restart needed\n"))
	if code := e.run("setup", "run", "distro_install", "--jsonl"); code != 0 {
		t.Fatalf("%d %s", code, e.stdout())
	}
	d := lastEvent(jsonLines(t, e.stdout()))
	if !d.RebootRequired || strings.Join(d.NextActions, ",") != "reboot" || !rebootMarkerPending(e.System) {
		t.Errorf("%+v", d)
	}
}

func TestSetupRunDistroInstallRestartTextWritesTheMarker(t *testing.T) {
	// the same path without a 3010 exit code: use the stream hook directly
	e := newEnv(t)
	e.readyEnv()
	rc := &runCtx{sys: e.System, em: &emitter{w: e.out, jsonl: true}, distro: "Ubuntu-24.04"}
	setupActions["distro_install"] = setupAction{"Install the Linux distro", func(rc *runCtx) error {
		rc.reboot, rc.msg = true, "restart Windows, then install the distro again"
		return nil
	}, []string{"distro_user"}}
	defer func() {
		setupActions["distro_install"] = setupAction{"Install the Linux distro", actDistroInstall, []string{"distro_user"}}
	}()
	runAction(rc, "distro_install")
	d := lastEvent(jsonLines(t, e.stdout()))
	if !d.RebootRequired || strings.Join(d.NextActions, ",") != "reboot" || !rebootMarkerPending(e.System) {
		t.Errorf("%+v", d)
	}
}

func TestSetupRunCLIInstallFailureNamesTheLastLine(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.script(
		rule("--cd ~ --exec /bin/sh", 0, probeOut("alice", "1000", "systemd", "no", setupGoodConf, "", "")),
		rule("/bin/bash -c", 1, "Cloning...\ncurl: (6) Could not resolve host: raw.githubusercontent.com\n"),
	)
	if code := e.run("setup", "run", "cli_install", "--jsonl"); code != 1 {
		t.Fatalf("exit %d", code)
	}
	var msg string
	for _, ev := range jsonLines(t, e.stdout()) {
		if ev.Event == "step" && ev.Status == "failed" {
			msg = ev.Message
		}
	}
	if !strings.Contains(msg, "exit code 1") || !strings.HasSuffix(msg, "Could not resolve host: raw.githubusercontent.com") {
		t.Errorf("message %q", msg)
	}
}

func TestSetupRunWslEnableNoSecondPromptWhileARestartIsPending(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.script(rule("--status", 1, ""))
	ctx, cancel := context.WithCancel(context.Background())
	el := &slowElevator{proc: slowProc{release: make(chan struct{})}}
	e.Elevate, e.Ctx = el, ctx
	cancel() // the first run stops waiting: the install keeps going in Windows
	e.run("setup", "run", "wsl_enable", "--jsonl")
	if len(el.calls) != 1 {
		t.Fatalf("first run prompts %d", len(el.calls))
	}
	e.Ctx = context.Background()
	e.out.Reset()
	code := e.run("setup", "run", "wsl_enable", "--jsonl")
	d := lastEvent(jsonLines(t, e.stdout()))
	if code != 0 || !d.RebootRequired || len(el.calls) != 1 {
		t.Errorf("code %d %+v, prompts %d", code, d, len(el.calls))
	}
}
