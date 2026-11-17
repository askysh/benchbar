package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

const (
	suLocal   = `C:\Users\tester\AppData\Local`
	suDir     = suLocal + `\Programs\BenchBar`
	suExe     = suDir + `\benchbar.exe`
	suTray    = suDir + `\BenchBarTray.exe`
	suPS      = `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`
	suRelease = "https://github.com/askysh/benchbar/releases/tag/v"
)

type fakeWeb struct {
	calls   []string
	answers map[string]WebResponse
	err     error
}

func (f *fakeWeb) Get(_ context.Context, u string, follow bool) (WebResponse, error) {
	f.calls = append(f.calls, fmt.Sprintf("%s follow=%v", u, follow))
	if f.err != nil {
		return WebResponse{}, f.err
	}
	if a, ok := f.answers[u]; ok {
		return a, nil
	}
	return WebResponse{Status: 404}, nil
}

type fakeLauncher struct {
	calls   []LaunchSpec
	handler func(s LaunchSpec) (int, error)
}

func (f *fakeLauncher) Run(_ context.Context, s LaunchSpec) (int, error) {
	f.calls = append(f.calls, s)
	if f.handler != nil {
		return f.handler(s)
	}
	return 0, nil
}

// suEnv is an installed copy in the installer's folder, version 0.8.3, on
// an amd64 PC with the tray installed and running.
type suEnvT struct {
	*env
	web      *fakeWeb
	launch   *fakeLauncher
	envs     map[string]string
	trayRuns bool
	// trayGen counts tray starts: each start is a new process with a new
	// creation time (and here a new pid).
	trayGen int
}

func newSUEnv(t *testing.T) *suEnvT {
	t.Helper()
	withVersion(t, "0.8.3")
	e := &suEnvT{env: newEnv(t), web: &fakeWeb{answers: map[string]WebResponse{}}, launch: &fakeLauncher{},
		envs: map[string]string{"LOCALAPPDATA": suLocal}, trayRuns: true}
	e.Getenv = func(k string) string {
		if v, ok := e.envs[k]; ok {
			return v
		}
		return os.Getenv(k)
	}
	e.ExePath = suExe
	e.Web, e.Launch = e.web, e.launch
	e.PowerShellPath = func() (string, error) { return suPS, nil }
	e.MachineArch = func() string { return "amd64" }
	e.ProcessImages = func(name string) []ProcessInfo {
		if name == "BenchBarTray.exe" && e.trayRuns {
			return []ProcessInfo{{Pid: 4000 + e.trayGen, Image: suTray, Created: uint64(1000 + e.trayGen)}}
		}
		return nil
	}
	e.FileExists = func(p string) bool { return p == suTray }
	e.releases(rel("v0.8.4", "2026-11-20T10:00:00Z", false, false, "amd64", "arm64"),
		rel("v0.8.3", "2026-11-17T10:00:00Z", false, false, "amd64", "arm64"))
	return e
}

func rel(tag, published string, draft, pre bool, arches ...string) ghRelease {
	v := strings.TrimPrefix(tag, "v")
	r := ghRelease{TagName: tag, PublishedAt: published, Draft: draft, Prerelease: pre, HTMLURL: suRelease + v}
	r.Assets = append(r.Assets, ghAsset{Name: "BenchBar-" + v + ".dmg"})
	for _, a := range arches {
		r.Assets = append(r.Assets, ghAsset{Name: windowsZipName(v, a)})
	}
	if len(arches) > 0 {
		r.Assets = append(r.Assets, ghAsset{Name: windowsSumsName(v)})
	}
	return r
}

func (e *suEnvT) releases(list ...ghRelease) {
	b, _ := json.Marshal(list)
	e.web.answers[releasesAPIURL] = WebResponse{Status: 200, Body: b}
}

// noWSL makes the CLI part of the check find no running distro.
func (e *suEnvT) wslScript(rules string) {
	e.t.Helper()
	p := filepath.Join(e.root, "wsl-script.json")
	if err := os.WriteFile(p, []byte(rules), 0o644); err != nil {
		e.t.Fatal(err)
	}
	e.t.Setenv("FAKE_WSL_MODE", "script:"+p)
}

func (e *suEnvT) check(t *testing.T) selfUpdateReport {
	t.Helper()
	if code := e.run("self-update", "--check", "--json"); code != 0 {
		t.Fatalf("--check --json exit %d, stderr %s", code, e.stderr())
	}
	var r selfUpdateReport
	if err := json.Unmarshal(e.out.Bytes(), &r); err != nil {
		t.Fatalf("not one JSON document: %v\n%s", err, e.stdout())
	}
	return r
}

func TestSelfUpdateCheckUpdateAvailable(t *testing.T) {
	e := newSUEnv(t)
	e.wslScript(`[{"match":"--running","stdout":"Ubuntu-24.04\n"},
	  {"match":"self-update --check --json","stdout":"{\"current\":\"0.8.3\",\"latest\":\"0.8.4\",\"install\":\"managed\"}\n"}]`)
	r := e.check(t)
	if r.Current != "0.8.3" || r.Latest == nil || *r.Latest != "0.8.4" || !r.UpdateAvailable || r.Install != "installer" || r.Error != nil {
		t.Fatalf("report %+v", r)
	}
	if r.Command == nil || *r.Command != "benchbar.exe self-update" || *r.ReleaseURL != suRelease+"0.8.4" || r.InstallDir != suDir {
		t.Fatalf("command/url/dir: %+v", r)
	}
	var cli map[string]any
	if err := json.Unmarshal(r.CLI, &cli); err != nil || cli["install"] != "managed" || r.CLIError != nil || *r.CLIDistro != "Ubuntu-24.04" {
		t.Fatalf("cli part: %s %v", r.CLI, r.CLIError)
	}
	// the contract of the tray: these keys are always there
	var raw map[string]json.RawMessage
	json.Unmarshal(e.out.Bytes(), &raw)
	for _, k := range []string{"current", "latest", "update_available", "install", "error"} {
		if _, ok := raw[k]; !ok {
			t.Errorf("key %s missing", k)
		}
	}
	if got := e.web.calls; len(got) != 1 || got[0] != releasesAPIURL+" follow=true" {
		t.Errorf("web calls %v", got)
	}
	if len(e.launch.calls) != 0 {
		t.Errorf("a check started programs: %v", e.launch.calls)
	}
}

func TestSelfUpdateCheckUpToDate(t *testing.T) {
	e := newSUEnv(t)
	e.releases(rel("v0.8.3", "2026-11-17T10:00:00Z", false, false, "amd64"))
	e.wslScript(`[{"match":"--running","stdout":""}]`)
	r := e.check(t)
	if r.UpdateAvailable || *r.Latest != "0.8.3" || r.Command != nil {
		t.Fatalf("report %+v", r)
	}
	if (r.CLI != nil && string(r.CLI) != "null") || r.CLIError == nil || !strings.Contains(*r.CLIError, "not running") {
		t.Fatalf("a stopped distro must not be asked or started: %s %v", r.CLI, r.CLIError)
	}
	for _, ev := range e.starts() {
		if strings.Contains(strings.Join(ev.Args, " "), "self-update") {
			t.Fatalf("the CLI was asked in a stopped distro: %v", ev.Args)
		}
	}
}

func TestSelfUpdateCheckOffline(t *testing.T) {
	e := newSUEnv(t)
	e.web.err = errors.New("dial tcp: no such host")
	r := e.check(t)
	if r.Error == nil || !strings.Contains(*r.Error, "could not reach GitHub") || r.Latest != nil || r.UpdateAvailable {
		t.Fatalf("report %+v", r)
	}
	// without --json an unknown latest release is a failure
	e.out.Reset()
	if code := e.run("self-update", "--check"); code != 1 || !strings.Contains(e.stdout(), "Latest release: unknown") {
		t.Fatalf("text check: exit %d\n%s", code, e.stdout())
	}
}

func TestSelfUpdateCheckRateLimited(t *testing.T) {
	e := newSUEnv(t)
	e.web.answers[releasesAPIURL] = WebResponse{Status: 403}
	e.web.answers[latestPageURL] = WebResponse{Status: 302, Location: repoWeb + "/releases/tag/v0.8.4"}
	r := e.check(t)
	if r.Error != nil || *r.Latest != "0.8.4" || *r.LatestSource != "release_page" || !r.UpdateAvailable || len(r.Notes) == 0 {
		t.Fatalf("report %+v", r)
	}
	if e.web.calls[1] != latestPageURL+" follow=false" {
		t.Fatalf("the release page must be read without following the redirect: %v", e.web.calls)
	}

	e2 := newSUEnv(t)
	e2.web.answers[releasesAPIURL] = WebResponse{Status: 429}
	r = e2.check(t)
	if r.Error == nil || !strings.Contains(*r.Error, "rate limit") || r.Latest != nil {
		t.Fatalf("report %+v", r)
	}
}

func TestSelfUpdateCheckNeedsAssetForThisCPU(t *testing.T) {
	e := newSUEnv(t)
	e.releases(rel("v0.8.4", "2026-11-20T10:00:00Z", false, false, "arm64"),
		rel("v0.8.3", "2026-11-17T10:00:00Z", false, false, "amd64", "arm64"))
	if r := e.check(t); *r.Latest != "0.8.3" || r.UpdateAvailable {
		t.Fatalf("amd64 got %+v", r)
	}
	e2 := newSUEnv(t)
	e2.MachineArch = func() string { return "arm64" }
	e2.releases(rel("v0.8.4", "2026-11-20T10:00:00Z", false, false, "arm64"))
	if r := e2.check(t); *r.Latest != "0.8.4" || r.Arch != "arm64" {
		t.Fatalf("arm64 got %+v", r)
	}
	e3 := newSUEnv(t)
	e3.releases(rel("v0.8.4", "2026-11-20T10:00:00Z", false, false))
	if r := e3.check(t); r.Error == nil || r.Latest != nil {
		t.Fatalf("no Windows build at all: %+v", r)
	}
}

func TestSelfUpdateCheckSkipsPrereleaseAndDraft(t *testing.T) {
	e := newSUEnv(t)
	e.releases(rel("v0.9.0", "2026-11-25T10:00:00Z", false, true, "amd64"),
		rel("v0.9.1", "2026-11-26T10:00:00Z", true, false, "amd64"),
		rel("v0.9.0-beta.1", "2026-11-24T10:00:00Z", false, false, "amd64"),
		rel("v0.8.3", "2026-11-17T10:00:00Z", false, false, "amd64"),
		rel("v0.8.4", "2026-11-20T10:00:00Z", false, false, "amd64"))
	if r := e.check(t); *r.Latest != "0.8.4" {
		t.Fatalf("got %+v", r)
	}
}

func TestSelfUpdatePackaged(t *testing.T) {
	e := newSUEnv(t)
	e.ExePath = `C:\Program Files\WindowsApps\Askysh.BenchBar_0.9.0.0_x64__0f196q1bwh8q6\benchbar.exe`
	if code := e.run("self-update", "--yes"); code != 0 || !strings.Contains(e.stdout(), "Microsoft Store") {
		t.Fatalf("exit %d\n%s%s", code, e.stdout(), e.stderr())
	}
	if len(e.launch.calls) != 0 || len(e.web.calls) != 0 {
		t.Fatalf("a Store copy must change nothing: %v %v", e.launch.calls, e.web.calls)
	}
	e.out.Reset()
	if r := e.check(t); r.Install != "store" || r.Command != nil {
		t.Fatalf("check %+v", r)
	}
}

func TestSelfUpdateLooseCopy(t *testing.T) {
	e := newSUEnv(t)
	e.ExePath = `C:\dev\benchbar\benchbar.exe`
	if code := e.run("self-update", "--yes"); code != 1 {
		t.Fatalf("exit %d", code)
	}
	if !strings.Contains(e.stderr(), suExe) || !strings.Contains(e.stderr(), "nothing was changed") || strings.Count(e.stderr(), "\n") != 1 {
		t.Fatalf("stderr %q", e.stderr())
	}
	if len(e.launch.calls) != 0 {
		t.Fatalf("started %v", e.launch.calls)
	}
	e.err.Reset()
	if r := e.check(t); r.Install != "other" || r.Command != nil {
		t.Fatalf("check %+v", r)
	}
}

func TestSelfUpdateRefusesWithoutTerminal(t *testing.T) {
	e := newSUEnv(t)
	e.StdinIsTerminal = false
	if code := e.run("self-update"); code != 1 {
		t.Fatalf("exit %d", code)
	}
	if !strings.Contains(e.stderr(), "no terminal") || !strings.Contains(e.stderr(), "fix: benchbar.exe self-update --yes") {
		t.Fatalf("stderr %q", e.stderr())
	}
	if len(e.launch.calls) != 0 {
		t.Fatalf("started %v", e.launch.calls)
	}
	// BENCHBAR_NONINTERACTIVE refuses even on a terminal
	e2 := newSUEnv(t)
	e2.StdinIsTerminal = true
	e2.envs["BENCHBAR_NONINTERACTIVE"] = "1"
	if code := e2.run("self-update"); code != 1 || len(e2.launch.calls) != 0 {
		t.Fatalf("exit %d, %v", code, e2.launch.calls)
	}
}

// updateHandler answers like a working update: the installer exits 0 and
// the tray runs again, the new exe says 0.8.4, cli_install updates the CLI.
func (e *suEnvT) updateHandler(newVersion string, cliEvents string) {
	e.launch.handler = func(s LaunchSpec) (int, error) {
		switch {
		case s.Path == suPS:
			e.trayRuns = true
			e.trayGen++
			return 0, nil
		case s.Path == suExe && reflect.DeepEqual(s.Args, []string{"--shim-version"}):
			fmt.Fprintf(s.Stdout, "benchbar.exe %s\n", newVersion)
			return 0, nil
		case s.Path == suExe && len(s.Args) > 1 && s.Args[0] == "setup":
			fmt.Fprint(s.Stdout, cliEvents)
			if strings.Contains(cliEvents, `"failed"`) {
				return 1, nil
			}
			return 0, nil
		}
		return 0, nil
	}
}

const cliUpdated = `{"event":"step","id":"cli_install","status":"running","message":"Install the BenchBar command line tool"}
{"event":"log","line":"benchbar 0.8.3 is older than benchbar.exe 0.8.4: updating it"}
{"event":"step","id":"cli_install","status":"done","message":"updated benchbar from 0.8.3 to 0.8.4"}
{"event":"done","exit":0,"changed":true}
`

func TestSelfUpdateYesRunsInstallerThenNewExe(t *testing.T) {
	e := newSUEnv(t)
	t.Setenv("BENCHBAR_UNINSTALL", "1") // left in the shell: must not reach the installer
	e.updateHandler("0.8.4", cliUpdated)
	e.trayRuns = true
	if code := e.run("self-update", "--yes"); code != 0 {
		t.Fatalf("exit %d\n%s\n%s", code, e.stdout(), e.stderr())
	}
	calls := e.launch.calls
	if len(calls) != 3 {
		t.Fatalf("calls %+v", calls)
	}
	wantScript := "$ErrorActionPreference = 'Stop'; [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; " +
		"& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/askysh/benchbar/main/install.ps1'))) -Yes -Version '0.8.4'; exit $LASTEXITCODE"
	want := []string{"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", wantScript}
	if calls[0].Path != suPS || !reflect.DeepEqual(calls[0].Args, want) {
		t.Fatalf("installer line:\n got %q %q\nwant %q", calls[0].Path, calls[0].Args, want)
	}
	if strings.Contains(wantScript, `"`) {
		t.Fatal("the script must hold no double quote")
	}
	envHas := func(env []string, prefix string) bool {
		for _, kv := range env {
			if strings.HasPrefix(strings.ToUpper(kv), prefix) {
				return true
			}
		}
		return false
	}
	if envHas(calls[0].Env, "BENCHBAR_UNINSTALL=") || !envHas(calls[0].Env, "BENCHBAR_FROM_SELF_UPDATE=1") {
		t.Fatalf("installer env: %v", calls[0].Env)
	}
	if calls[0].Stdin != nil || calls[0].Stdout != e.Stdout {
		t.Fatal("the installer streams to the shim's output and reads nothing")
	}
	if !reflect.DeepEqual(calls[2].Args, []string{"setup", "run", "cli_install", "--distro", "Ubuntu-24.04", "--jsonl"}) || calls[2].Path != suExe {
		t.Fatalf("CLI step %q %q", calls[2].Path, calls[2].Args)
	}
	out := e.stdout()
	for _, s := range []string{
		"BenchBar for Windows 0.8.3 is installed in " + suDir,
		"This installs 0.8.4:",
		"Windows programs: updated from 0.8.3 to 0.8.4",
		"Tray app: restarted",
		"CLI in WSL (Ubuntu-24.04): updated benchbar from 0.8.3 to 0.8.4",
		"    benchbar 0.8.3 is older than benchbar.exe 0.8.4: updating it",
	} {
		if !strings.Contains(out, s) {
			t.Errorf("missing %q in\n%s", s, out)
		}
	}
	if strings.Contains(out, "Keepalive") {
		t.Errorf("no keepalive task, no keepalive line:\n%s", out)
	}
}

func TestSelfUpdateNoTrayInstallAndNoDistro(t *testing.T) {
	e := newSUEnv(t)
	e.FileExists = func(string) bool { return false }
	e.trayRuns = false
	e.distros.list = nil
	e.updateHandler("0.8.4", "")
	if code := e.run("self-update", "--yes"); code != 0 {
		t.Fatalf("exit %d\n%s%s", code, e.stdout(), e.stderr())
	}
	if !strings.HasSuffix(e.launch.calls[0].Args[5], "-Yes -Version '0.8.4' -NoTray; exit $LASTEXITCODE") {
		t.Fatalf("a benchbar.exe only install stays one: %q", e.launch.calls[0].Args[5])
	}
	if len(e.launch.calls) != 2 {
		t.Fatalf("no distro, no CLI step: %+v", e.launch.calls)
	}
	out := e.stdout()
	if !strings.Contains(out, "Tray app: not installed") || !strings.Contains(out, "CLI in WSL: skipped: no Linux distro is set up yet; the setup installs the CLI") {
		t.Fatalf("summary:\n%s", out)
	}
}

func TestSelfUpdateInstallerFails(t *testing.T) {
	e := newSUEnv(t)
	e.launch.handler = func(s LaunchSpec) (int, error) {
		if s.Path == suPS {
			e.trayRuns = false
			return 1, nil
		}
		return 0, nil
	}
	if code := e.run("self-update", "--yes"); code != 1 {
		t.Fatalf("exit %d", code)
	}
	if len(e.launch.calls) != 1 {
		t.Fatalf("nothing runs after a failed installer: %+v", e.launch.calls)
	}
	out := e.stdout()
	for _, s := range []string{"Windows programs: failed: the installer exited with 1", "Tray app: closed for the update and not running now",
		"CLI in WSL: not updated, because the Windows part failed"} {
		if !strings.Contains(out, s) {
			t.Errorf("missing %q in\n%s", s, out)
		}
	}
}

func TestSelfUpdateWrongVersionAfterInstaller(t *testing.T) {
	e := newSUEnv(t)
	e.updateHandler("0.8.3", cliUpdated)
	if code := e.run("self-update", "--yes"); code != 1 || !strings.Contains(e.stdout(), "benchbar.exe reports 0.8.3, not 0.8.4") {
		t.Fatalf("exit %d\n%s", code, e.stdout())
	}
}

func TestSelfUpdateCLIStepFails(t *testing.T) {
	e := newSUEnv(t)
	e.updateHandler("0.8.4", `{"event":"step","id":"cli_install","status":"failed","message":"the installer failed with exit code 22"}
{"event":"done","exit":1}
`)
	if code := e.run("self-update", "--yes"); code != 1 {
		t.Fatalf("exit %d", code)
	}
	out := e.stdout()
	if !strings.Contains(out, "Windows programs: updated from 0.8.3 to 0.8.4") ||
		!strings.Contains(out, "CLI in WSL (Ubuntu-24.04): failed: the installer failed with exit code 22. fix: benchbar.exe setup run cli_install --distro Ubuntu-24.04") {
		t.Fatalf("summary:\n%s", out)
	}
}

func TestSelfUpdateRestartsKeepaliveOfThisCopy(t *testing.T) {
	e := newSUEnv(t)
	e.updateHandler("0.8.4", cliUpdated)
	e.tasks.handler = func(args []string) (string, int, error) {
		if len(args) == 4 && args[3] == "/XML" {
			return keepaliveXML(e.User, suExe, "Ubuntu-24.04"), 0, nil
		}
		return "", 0, nil
	}
	if code := e.run("self-update", "--yes"); code != 0 {
		t.Fatalf("exit %d\n%s", code, e.stdout())
	}
	got := e.launch.calls[2]
	if got.Path != suExe || !reflect.DeepEqual(got.Args, []string{"keepalive", "install", "--distro", "Ubuntu-24.04"}) {
		t.Fatalf("keepalive call %q %q", got.Path, got.Args)
	}
	if !strings.Contains(e.stdout(), "Keepalive: restarted with the new benchbar.exe") {
		t.Fatalf("summary:\n%s", e.stdout())
	}

	// another copy's task is left alone
	e2 := newSUEnv(t)
	e2.updateHandler("0.8.4", cliUpdated)
	e2.tasks.handler = func(args []string) (string, int, error) {
		return keepaliveXML(e2.User, `D:\other\benchbar.exe`, "Ubuntu-24.04"), 0, nil
	}
	e2.run("self-update", "--yes")
	for _, c := range e2.launch.calls {
		if len(c.Args) > 0 && c.Args[0] == "keepalive" {
			t.Fatalf("restarted another copy's keepalive: %v", c.Args)
		}
	}
}

func TestSelfUpdateAsksOnTerminal(t *testing.T) {
	e := newSUEnv(t)
	e.StdinIsTerminal = true
	e.Stdin = strings.NewReader("n\n")
	if code := e.run("self-update", "--version", "0.8.2"); code != 1 || len(e.launch.calls) != 0 {
		t.Fatalf("a no must change nothing: exit %d %v", code, e.launch.calls)
	}
	if !strings.Contains(e.stdout(), "This installs 0.8.2 (an older release than this one)") || !strings.Contains(e.stdout(), "Cancelled. Nothing was changed.") {
		t.Fatalf("stdout:\n%s", e.stdout())
	}
	if len(e.web.calls) != 0 {
		t.Fatalf("--version needs no lookup: %v", e.web.calls)
	}

	e2 := newSUEnv(t)
	e2.StdinIsTerminal = true
	e2.Stdin = strings.NewReader("y\n")
	e2.updateHandler("0.8.2", cliUpdated)
	if code := e2.run("self-update", "--version", "v0.8.2"); code != 0 {
		t.Fatalf("exit %d\n%s", code, e2.stdout())
	}
	if !strings.Contains(e2.launch.calls[0].Args[5], "-Yes -Version '0.8.2';") {
		t.Fatalf("pinned version: %q", e2.launch.calls[0].Args[5])
	}
}

func TestSelfUpdateZipAndInstallerFile(t *testing.T) {
	e := newSUEnv(t)
	e.updateHandler("0.8.4", cliUpdated)
	zip := `C:\Users\tester\Downloads\benchbar-windows-0.8.4-amd64.zip`
	if code := e.run("self-update", "--yes", "--zip", zip, "--installer", `C:\it's\install.ps1`); code != 0 {
		t.Fatalf("exit %d\n%s%s", code, e.stdout(), e.stderr())
	}
	s := e.launch.calls[0].Args[5]
	if !strings.Contains(s, `& ([scriptblock]::Create((Get-Content -Raw -LiteralPath 'C:\it''s\install.ps1'))) -Yes -Zip '`+zip+`';`) {
		t.Fatalf("script %q", s)
	}
	if code := newSUEnv(t).run("self-update", "--yes", "--zip", `C:\x\other.zip`); code != 1 {
		t.Fatalf("a zip that is not BenchBar's: exit %d", code)
	}
}

func TestSelfUpdateUpToDateStillAlignsCLI(t *testing.T) {
	e := newSUEnv(t)
	e.releases(rel("v0.8.3", "2026-11-17T10:00:00Z", false, false, "amd64"))
	e.updateHandler("0.8.3", `{"event":"step","id":"cli_install","status":"skipped","message":"benchbar is already installed: benchbar 0.8.3"}
`)
	if code := e.run("self-update", "--yes"); code != 0 {
		t.Fatalf("exit %d", code)
	}
	if len(e.launch.calls) != 1 || e.launch.calls[0].Args[0] != "setup" {
		t.Fatalf("only the CLI step runs: %+v", e.launch.calls)
	}
	if !strings.Contains(e.stdout(), "Windows programs: up to date (0.8.3)") || !strings.Contains(e.stdout(), "benchbar is already installed: benchbar 0.8.3") {
		t.Fatalf("stdout:\n%s", e.stdout())
	}
}

func TestSelfUpdateDryRunAndFlags(t *testing.T) {
	e := newSUEnv(t)
	if code := e.run("self-update", "--dry-run"); code != 0 || len(e.launch.calls) != 0 {
		t.Fatalf("exit %d %v", code, e.launch.calls)
	}
	if !strings.Contains(e.stdout(), `runs: powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$ErrorActionPreference`) ||
		!strings.Contains(e.stdout(), "dry-run: nothing was run") {
		t.Fatalf("stdout:\n%s", e.stdout())
	}
	e2 := newSUEnv(t)
	if code := e2.run("self-update", "--channel", "beta"); code != 1 || !strings.Contains(e2.stderr(), "unknown option --channel") || !strings.Contains(e2.stderr(), "self-update --cli") {
		t.Fatalf("exit %d %q", code, e2.stderr())
	}
	e3 := newSUEnv(t)
	if code := e3.run("self-update", "--version", "0.8"); code != 1 || len(e3.launch.calls) != 0 {
		t.Fatalf("bad version: exit %d", code)
	}
}

func TestSelfUpdateCLIOnlyForwards(t *testing.T) {
	e := newSUEnv(t)
	if code := e.run("self-update", "--cli", "--check", "--json"); code != 0 {
		t.Fatalf("exit %d %s", code, e.stderr())
	}
	st := e.starts()
	if len(st) != 1 || !strings.HasSuffix(strings.Join(st[0].Args, " "), "benchbar self-update --check --json") {
		t.Fatalf("forwarded %+v", st)
	}
	if !strings.Contains(e.stderr(), "updates only that CLI") || e.stdout() != "" {
		t.Fatalf("stderr %q stdout %q", e.stderr(), e.stdout())
	}
}

func TestKeepaliveRunAfterRenameIsStillOurs(t *testing.T) {
	e := newEnv(t)
	e.procs.add(77, `C:\x\benchbar.exe.old`)
	if !isKeepaliveProcess(e.System, pidRecord{Pid: 77, Created: 77000}) {
		t.Fatal("a run whose exe was renamed by an update must still be found")
	}
	e.procs.add(79, `C:\x\benchbar.exe.2.old`)
	if !isKeepaliveProcess(e.System, pidRecord{Pid: 79, Created: 79000}) {
		t.Fatal("benchbar.exe.N.old is the name when benchbar.exe.old is still taken")
	}
	e.procs.add(80, `C:\x\benchbar.exe.x.old`)
	if isKeepaliveProcess(e.System, pidRecord{Pid: 80, Created: 80000}) {
		t.Fatal("only a number goes between benchbar.exe and .old")
	}
	e.procs.add(78, `C:\x\notepad.exe`)
	if isKeepaliveProcess(e.System, pidRecord{Pid: 78, Created: 78000}) {
		t.Fatal("another program is never ours")
	}
}

func TestPickProxy(t *testing.T) {
	cases := []struct{ server, override, host, want string }{
		{"proxy:8080", "", "api.github.com", "http://proxy:8080"},
		{"http=a:1;https=b:2", "", "api.github.com", "http://b:2"},
		{"http=a:1", "", "api.github.com", "http://a:1"},
		{"proxy:8080", "*.github.com;<local>", "api.github.com", ""},
		{"proxy:8080", "<local>", "intranet", ""},
		{"", "", "api.github.com", ""},
	}
	for _, c := range cases {
		got := ""
		if u := pickProxy(c.server, c.override, c.host); u != nil {
			got = u.String()
		}
		if got != c.want {
			t.Errorf("pickProxy(%q, %q, %q) = %q, want %q", c.server, c.override, c.host, got, c.want)
		}
	}
}

func TestInstallerEnvDropsPSModulePath(t *testing.T) {
	e := newSUEnv(t)
	e.Environ = func() []string {
		return []string{
			`PSModulePath=C:\Program Files\PowerShell\7\Modules;C:\Program Files\PowerShell\7\Modules`,
			`psmodulepath=C:\Users\tester\Documents\PowerShell\Modules`,
			`LOCALAPPDATA=` + suLocal,
			`PATH=C:\Windows\System32;C:\Windows`,
			`SystemRoot=C:\Windows`,
			`USERPROFILE=C:\Users\tester`,
			`HTTPS_PROXY=http://proxy:8080`,
			`BENCHBAR_ZIP=C:\old.zip`,
		}
	}
	got := installerEnv(e.System, "")
	for _, kv := range got {
		k, _, _ := strings.Cut(kv, "=")
		if strings.EqualFold(k, "PSModulePath") || strings.EqualFold(k, "BENCHBAR_ZIP") {
			t.Errorf("%q reached the installer", kv)
		}
	}
	for _, want := range []string{"LOCALAPPDATA=" + suLocal, `PATH=C:\Windows\System32;C:\Windows`, `SystemRoot=C:\Windows`,
		`USERPROFILE=C:\Users\tester`, "HTTPS_PROXY=http://proxy:8080", "BENCHBAR_FROM_SELF_UPDATE=1"} {
		found := false
		for _, kv := range got {
			found = found || kv == want
		}
		if !found {
			t.Errorf("missing %q in %q", want, got)
		}
	}
}

func TestSelfUpdateInstallerGetsNoPSModulePath(t *testing.T) {
	e := newSUEnv(t)
	e.Environ = func() []string {
		return append(os.Environ(), `PSModulePath=C:\Program Files\PowerShell\7\Modules`)
	}
	e.updateHandler("0.8.4", cliUpdated)
	if code := e.run("self-update", "--yes"); code != 0 {
		t.Fatalf("exit %d\n%s%s", code, e.stdout(), e.stderr())
	}
	if e.launch.calls[0].Path != suPS {
		t.Fatalf("first call %q", e.launch.calls[0].Path)
	}
	for _, kv := range e.launch.calls[0].Env {
		if strings.HasPrefix(strings.ToUpper(kv), "PSMODULEPATH=") {
			t.Fatalf("%q reached powershell.exe", kv)
		}
	}
}

// trayCase runs a self-update where the installer exits with code and
// leaves the tray as after says: "same" (the process from before), "new"
// (a new process) or "none".
func trayCase(t *testing.T, runsBefore bool, code int, after string) string {
	t.Helper()
	e := newSUEnv(t)
	e.trayRuns = runsBefore
	e.launch.handler = func(s LaunchSpec) (int, error) {
		switch {
		case s.Path == suPS:
			switch after {
			case "same":
				e.trayRuns = true
			case "new":
				e.trayRuns = true
				e.trayGen++
			default:
				e.trayRuns = false
			}
			return code, nil
		case s.Path == suExe && reflect.DeepEqual(s.Args, []string{"--shim-version"}):
			fmt.Fprintln(s.Stdout, "benchbar.exe 0.8.4")
		case s.Path == suExe && len(s.Args) > 1 && s.Args[0] == "setup":
			fmt.Fprint(s.Stdout, cliUpdated)
		}
		return 0, nil
	}
	e.run("self-update", "--yes")
	return e.stdout()
}

func TestSelfUpdateTrayLineComparesTheProcess(t *testing.T) {
	cases := []struct {
		name       string
		runsBefore bool
		code       int
		after      string
		want       string
	}{
		{"installer failed, same tray", true, 1, "same", "Tray app: still running, not closed by the failed update"},
		{"worked, same tray", true, 0, "same", "Tray app: still the old one (the installer did not get to it)"},
		{"worked, new tray", true, 0, "new", "Tray app: restarted"},
		{"installer failed, new tray", true, 1, "new", "Tray app: running a new process, but the Windows part failed"},
		{"worked, closed", true, 0, "none", "Tray app: closed for the update and not running now"},
		{"not running before or after", false, 0, "none", "Tray app: not running (it was not running before the update)"},
		{"not running before, started", false, 0, "new", "Tray app: started"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			out := trayCase(t, c.runsBefore, c.code, c.after)
			if !strings.Contains(out, c.want) {
				t.Fatalf("want %q in\n%s", c.want, out)
			}
			if !strings.Contains(c.want, "restarted") && strings.Contains(out, "Tray app: restarted") {
				t.Fatalf("claims a restart:\n%s", out)
			}
			if c.code != 0 && strings.Contains(out, "quit BenchBar") {
				t.Fatalf("a failed update gives restart advice:\n%s", out)
			}
		})
	}
}

func TestSameProcessNeedsPidAndCreationTime(t *testing.T) {
	before := []ProcessInfo{{Pid: 10, Created: 5}}
	if !sameProcess(before, []ProcessInfo{{Pid: 10, Created: 5}}) {
		t.Fatal("same pid and time is the same process")
	}
	if sameProcess(before, []ProcessInfo{{Pid: 10, Created: 6}}) {
		t.Fatal("a reused pid is another process")
	}
	if sameProcess(before, []ProcessInfo{{Pid: 11, Created: 5}}) || sameProcess(nil, before) {
		t.Fatal("another pid, or nothing before, is not the same process")
	}
}

// envValue is the value of key in a child's environment, "" when unset.
func envValue(env []string, key string) string {
	for _, kv := range env {
		if k, v, ok := strings.Cut(kv, "="); ok && strings.EqualFold(k, key) {
			return v
		}
	}
	return ""
}

// failedInstall runs a self-update whose installer exits 1 after writing
// result to BENCHBAR_INSTALL_RESULT and leaves the tray as after says.
func failedInstall(t *testing.T, result, after string) (*suEnvT, string) {
	t.Helper()
	e := newSUEnv(t)
	e.launch.handler = func(s LaunchSpec) (int, error) {
		if s.Path != suPS {
			return 0, nil
		}
		path := envValue(s.Env, "BENCHBAR_INSTALL_RESULT")
		if path == "" || !strings.HasPrefix(path, e.ConfigDir) {
			t.Errorf("result file %q is not in the config folder %q", path, e.ConfigDir)
		}
		if result != "" {
			os.WriteFile(path, []byte(result), 0o644)
		}
		if after == "new" {
			e.trayGen++
		}
		e.trayRuns = after != "none"
		return 1, nil
	}
	if code := e.run("self-update", "--yes"); code != 1 {
		t.Fatalf("exit %d", code)
	}
	return e, e.stdout()
}

func TestSelfUpdateFailedInstallerNothingChanged(t *testing.T) {
	e, out := failedInstall(t, "unchanged\r\nCould not update BenchBar: BenchBar.Tray.Core.dll could not be moved aside, most likely because a program holds it open (in use).\r\n", "new")
	for _, s := range []string{
		"Windows programs: failed: the installer exited with 1: Could not update BenchBar: BenchBar.Tray.Core.dll could not be moved aside",
		"Windows programs: nothing was changed: benchbar.exe and the tray app are still 0.8.3",
		"Tray app: started again, with the files from before the update",
		"CLI in WSL: not updated, because the Windows part failed",
		"Retry, once the cause above is fixed: benchbar.exe self-update\n",
	} {
		if !strings.Contains(out, s) {
			t.Errorf("missing %q in\n%s", s, out)
		}
	}
	for _, s := range []string{"quit BenchBar", "Tray app: restarted", "may be the old version"} {
		if strings.Contains(out, s) {
			t.Errorf("%q does not fit a failed update that changed nothing:\n%s", s, out)
		}
	}
	if _, err := os.Stat(filepath.Join(e.ConfigDir, "self-update-result.txt")); !os.IsNotExist(err) {
		t.Errorf("the result file is left behind: %v", err)
	}
}

func TestSelfUpdateFailedInstallerSameTrayVersionRetry(t *testing.T) {
	e := newSUEnv(t)
	e.launch.handler = func(s LaunchSpec) (int, error) { return 1, nil }
	e.run("self-update", "--yes", "--version", "0.8.4")
	out := e.stdout()
	for _, s := range []string{
		"Windows programs: failed: the installer exited with 1 (the lines above say why)",
		"Tray app: still running, not closed by the failed update",
		"Retry, once the cause above is fixed: benchbar.exe self-update --version 0.8.4",
	} {
		if !strings.Contains(out, s) {
			t.Errorf("missing %q in\n%s", s, out)
		}
	}
	if strings.Contains(out, "nothing was changed") {
		t.Errorf("an installer that said nothing is not quoted as saying nothing changed:\n%s", out)
	}
}

func TestSelfUpdateFailedInstallerMixed(t *testing.T) {
	_, out := failedInstall(t, "mixed\nCould not update BenchBar: x could not be copied\n", "none")
	if !strings.Contains(out, "Windows programs: some files could not be put back (the lines above name them). fix: "+oneLineInstall) {
		t.Errorf("no repair line:\n%s", out)
	}
	if strings.Contains(out, "nothing was changed") || strings.Contains(out, "Retry, once") {
		t.Errorf("a mixed install is not retried with self-update:\n%s", out)
	}
}

func TestSelfUpdatePlanSaysWhatHappensToTheTray(t *testing.T) {
	const restarts = "The tray app closes and starts again."
	const stays = "The tray app is not running and will not be started."
	e := newSUEnv(t)
	e.trayRuns = true
	e.run("self-update", "--dry-run")
	if out := e.stdout(); !strings.Contains(out, restarts) || strings.Contains(out, stays) {
		t.Errorf("running tray:\n%s", out)
	}
	e = newSUEnv(t)
	e.trayRuns = false
	e.run("self-update", "--dry-run")
	if out := e.stdout(); !strings.Contains(out, stays) || strings.Contains(out, restarts) {
		t.Errorf("tray not running:\n%s", out)
	}
	e = newSUEnv(t)
	e.ProcessImages = nil
	e.run("self-update", "--dry-run")
	if out := e.stdout(); !strings.Contains(out, "A running tray app closes and starts again.") {
		t.Errorf("processes unknown:\n%s", out)
	}
}

func TestInstallerEnvResultFile(t *testing.T) {
	e := newSUEnv(t)
	e.Environ = func() []string { return []string{`BENCHBAR_INSTALL_RESULT=C:\elsewhere.txt`, `PATH=C:\Windows`} }
	got := installerEnv(e.System, `C:\cfg\self-update-result.txt`)
	if v := envValue(got, "BENCHBAR_INSTALL_RESULT"); v != `C:\cfg\self-update-result.txt` {
		t.Fatalf("result file %q in %q", v, got)
	}
	n := 0
	for _, kv := range got {
		if strings.HasPrefix(strings.ToUpper(kv), "BENCHBAR_INSTALL_RESULT=") {
			n++
		}
	}
	if n != 1 {
		t.Fatalf("an inherited BENCHBAR_INSTALL_RESULT reached the installer: %q", got)
	}
	if envValue(installerEnv(e.System, ""), "BENCHBAR_INSTALL_RESULT") != "" {
		t.Fatal("no result path, no variable")
	}
}
