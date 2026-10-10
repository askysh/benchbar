package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const goodConf = "[boot]\nsystemd=true\n"

func probeText(conf, pid1, user, bench, linger string) string {
	return fmt.Sprintf("wslconf_b64=%s\npid1=%s\nuser=%s\nbenchbar=%s\nlinger=%s\n",
		base64.StdEncoding.EncodeToString([]byte(conf)), pid1, user, bench, linger)
}

func (e *env) useProbe(text string) {
	e.t.Helper()
	path := filepath.Join(e.root, "probe.txt")
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		e.t.Fatal(err)
	}
	e.t.Setenv("FAKE_WSL_MODE", "probe:"+path)
}

func (e *env) configExists() bool {
	_, err := os.Stat(filepath.Join(e.ConfigDir, "config.json"))
	return err == nil
}

type adoptJSON struct {
	Distro   string
	Recorded bool
	Checks   []Check
}

func goodProbe() string {
	return probeText(goodConf, "systemd", "akash", "/home/akash/.local/bin/benchbar", "yes")
}

func TestAdoptGoodDistro(t *testing.T) {
	e := newEnv(t)
	e.useProbe(goodProbe())
	if code := e.run("adopt-distro"); code != 0 {
		t.Fatalf("exit %d\n%s%s", code, e.stdout(), e.stderr())
	}
	out := e.stdout()
	for _, want := range []string{
		"  [OK] Distro: Ubuntu-24.04 is registered\n",
		"  [OK] WSL version: runs as WSL 2\n",
		"  [OK] systemd: ",
		"  [OK] benchbar: found at /home/akash/.local/bin/benchbar\n",
		"  [OK] Linger: ",
		"Recorded Ubuntu-24.04 in " + filepath.Join(e.ConfigDir, "config.json"),
		"5 ok, 0 warn, 0 fail",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
	if string(e.readConfig()["distro"]) != `"Ubuntu-24.04"` {
		t.Error("distro not recorded")
	}
	st := e.starts()
	if len(st) != 1 {
		t.Fatalf("%d wsl.exe calls, want 1", len(st))
	}
	if got := st[0].Exec[:3]; got[0] != "/bin/sh" || got[1] != "-c" || got[2] != probeScript || st[0].Exec[3] != "benchbar" {
		t.Errorf("probe exec %q", st[0].Exec)
	}
	if st[0].Distro != "Ubuntu-24.04" || st[0].Cd != "~" {
		t.Errorf("probe distro %q cd %q", st[0].Distro, st[0].Cd)
	}
}

func TestProbeScriptOnlyReads(t *testing.T) {
	for _, bad := range []string{"rm ", "tee", "sudo", "mkdir", "mv ", "cp ", "enable-linger"} {
		if strings.Contains(probeScript, bad) {
			t.Errorf("probe contains %q", bad)
		}
	}
	// the only redirections are to /dev/null
	s := strings.ReplaceAll(probeScript, "2>/dev/null", "")
	if strings.Contains(s, ">") {
		t.Errorf("probe redirects somewhere: %s", probeScript)
	}
}

func TestAdoptSystemdMissing(t *testing.T) {
	e := newEnv(t)
	e.useProbe(probeText("", "init", "akash", "/x/benchbar", "yes"))
	if code := e.run("adopt-distro"); code != 1 {
		t.Fatalf("exit %d", code)
	}
	out := e.stdout()
	if !strings.Contains(out, "  [FAIL] systemd: ") ||
		!strings.Contains(out, `fix: wsl.exe -d Ubuntu-24.04 -- sudo sh -c "printf '[boot]\nsystemd=true\n' >> /etc/wsl.conf"; wsl.exe --terminate Ubuntu-24.04`) {
		t.Errorf("output:\n%s", out)
	}
	if e.configExists() {
		t.Error("a FAIL must not record the distro")
	}
	if strings.Contains(out, "Recorded") {
		t.Error("recorded despite FAIL")
	}
}

func TestAdoptSystemdNeedsRestart(t *testing.T) {
	e := newEnv(t)
	e.useProbe(probeText("[boot]\nsystemd = true\n", "init", "akash", "/x/benchbar", "yes"))
	if code := e.run("adopt-distro", "--json"); code != 1 {
		t.Fatalf("exit %d", code)
	}
	var r adoptJSON
	if err := json.Unmarshal(e.out.Bytes(), &r); err != nil {
		t.Fatalf("%v\n%s", err, e.stdout())
	}
	for _, c := range r.Checks {
		if c.ID == "systemd" && (c.Status != "fail" || c.Fix != "wsl.exe --terminate Ubuntu-24.04") {
			t.Errorf("%+v", c)
		}
	}
}

func TestAdoptSystemdFalseInConf(t *testing.T) {
	e := newEnv(t)
	e.useProbe(probeText("# c\n[boot]\nsystemd=false\n", "systemd", "akash", "/x/benchbar", "yes"))
	if code := e.run("adopt-distro"); code != 1 {
		t.Fatalf("exit %d", code)
	}
}

func TestAdoptBenchbarMissing(t *testing.T) {
	e := newEnv(t)
	e.useProbe(probeText(goodConf, "systemd", "akash", "", "yes"))
	if code := e.run("adopt-distro"); code != 1 {
		t.Fatalf("exit %d", code)
	}
	want := `fix: wsl.exe -d Ubuntu-24.04 -- bash -c "curl -fsSL https://raw.githubusercontent.com/askysh/benchbar/main/install.sh | bash"`
	if !strings.Contains(e.stdout(), "[FAIL] benchbar: ") || !strings.Contains(e.stdout(), want) {
		t.Errorf("output:\n%s", e.stdout())
	}
}

func TestAdoptWSL1(t *testing.T) {
	e := newEnv(t)
	e.distros.list = []Distro{{Name: "Ubuntu-24.04", Version: 1, Default: true}}
	e.useProbe(goodProbe())
	if code := e.run("adopt-distro"); code != 1 {
		t.Fatalf("exit %d", code)
	}
	if !strings.Contains(e.stdout(), "[FAIL] WSL version: ") || !strings.Contains(e.stdout(), "fix: wsl.exe --set-version Ubuntu-24.04 2") {
		t.Errorf("output:\n%s", e.stdout())
	}
	if e.configExists() {
		t.Error("recorded despite FAIL")
	}
}

func TestAdoptUnregisteredDistro(t *testing.T) {
	e := newEnv(t)
	if code := e.run("adopt-distro", "Nope"); code != 1 {
		t.Fatalf("exit %d", code)
	}
	if !strings.Contains(e.stdout(), "[FAIL] Distro: ") || !strings.Contains(e.stdout(), "fix: benchbar.exe adopt-distro <NAME> (wsl.exe --list --verbose shows the names)") {
		t.Errorf("output:\n%s", e.stdout())
	}
	if len(e.starts()) != 0 {
		t.Error("wsl.exe must not run for an unregistered distro")
	}
}

func TestAdoptNamedDistroIsRecordedWithRegistrySpelling(t *testing.T) {
	e := newEnv(t)
	e.distros.list = []Distro{ubuntu, {Name: "Debian", Version: 2}}
	e.useProbe(goodProbe())
	if code := e.run("adopt-distro", "debian"); code != 0 {
		t.Fatalf("exit %d\n%s", code, e.stdout())
	}
	if string(e.readConfig()["distro"]) != `"Debian"` {
		t.Errorf("config %v", e.readConfig())
	}
	if st := e.starts(); len(st) != 1 || st[0].Distro != "Debian" {
		t.Errorf("starts %+v", st)
	}
}

func TestAdoptKeepsOtherConfigKeys(t *testing.T) {
	e := newEnv(t)
	e.writeConfig(`{"cli_path":"/x/benchbar","extra":true}`)
	e.useProbe(probeText(goodConf, "systemd", "akash", "/x/benchbar", "yes"))
	if code := e.run("adopt-distro"); code != 0 {
		t.Fatalf("exit %d", code)
	}
	m := e.readConfig()
	if string(m["cli_path"]) != `"/x/benchbar"` || string(m["extra"]) != "true" || string(m["distro"]) != `"Ubuntu-24.04"` {
		t.Errorf("config %v", m)
	}
	// the probe looks for the configured CLI
	if st := e.starts(); st[0].Exec[3] != "/x/benchbar" {
		t.Errorf("probe cli %q", st[0].Exec[3])
	}
}

func TestAdoptRegistryUnreadable(t *testing.T) {
	e := newEnv(t)
	e.distros.list, e.distros.err = nil, fmt.Errorf("denied")
	e.useProbe(goodProbe())
	if code := e.run("adopt-distro", "Ubuntu-24.04"); code != 0 {
		t.Fatalf("exit %d\n%s", code, e.stdout())
	}
	if !strings.Contains(e.stdout(), "[WARN] Distro: cannot read the WSL registry") {
		t.Errorf("output:\n%s", e.stdout())
	}
	e2 := newEnv(t)
	e2.distros.err = fmt.Errorf("denied")
	if code := e2.run("adopt-distro"); code != 1 {
		t.Errorf("exit %d without a name", code)
	}
}

func TestAdoptProbeFailure(t *testing.T) {
	e := newEnv(t)
	t.Setenv("FAKE_WSL_MODE", "exit:1")
	if code := e.run("adopt-distro"); code != 1 {
		t.Fatalf("exit %d", code)
	}
	if !strings.Contains(e.stdout(), "[FAIL] WSL access: cannot run a command in Ubuntu-24.04") {
		t.Errorf("output:\n%s", e.stdout())
	}
	if e.configExists() {
		t.Error("recorded despite FAIL")
	}
}

func lingerOff() string {
	return probeText(goodConf, "systemd", "akash", "/x/benchbar", "no")
}

func loginctlCalls(e *env) [][]string {
	var out [][]string
	for _, s := range e.starts() {
		if len(s.Exec) > 0 && s.Exec[0] == "loginctl" {
			out = append(out, s.Args)
		}
	}
	return out
}

func TestAdoptLingerWarnsAndRecordsWithoutYes(t *testing.T) {
	e := newEnv(t)
	e.useProbe(lingerOff())
	if code := e.run("adopt-distro"); code != 0 {
		t.Fatalf("exit %d, a WARN is not a failure\n%s", code, e.stdout())
	}
	if !strings.Contains(e.stdout(), "[WARN] Linger: ") || !strings.Contains(e.stdout(), "fix: wsl.exe -d Ubuntu-24.04 -- loginctl enable-linger akash") {
		t.Errorf("output:\n%s", e.stdout())
	}
	if len(loginctlCalls(e)) != 0 {
		t.Error("linger changed without --yes")
	}
	if !e.configExists() {
		t.Error("a WARN still records the distro")
	}
}

func TestAdoptLingerFixWithYes(t *testing.T) {
	e := newEnv(t)
	e.useProbe(lingerOff())
	after := filepath.Join(e.root, "after.txt")
	os.WriteFile(after, []byte(probeText(goodConf, "systemd", "akash", "/x/benchbar", "yes")), 0o644)
	t.Setenv("FAKE_WSL_PROBE_AFTER", after)
	if code := e.run("adopt-distro", "--yes"); code != 0 {
		t.Fatalf("exit %d\n%s", code, e.stdout())
	}
	calls := loginctlCalls(e)
	if len(calls) != 1 {
		t.Fatalf("loginctl calls: %v", calls)
	}
	want := []string{"-d", "Ubuntu-24.04", "--exec", "loginctl", "--no-ask-password", "enable-linger", "akash"}
	if strings.Join(calls[0], " ") != strings.Join(want, " ") {
		t.Errorf("args %q\nwant %q", calls[0], want)
	}
	if !strings.Contains(e.stdout(), "After the change:\n  [OK] Linger") || !strings.Contains(e.stdout(), "5 ok, 0 warn, 0 fail") {
		t.Errorf("output:\n%s", e.stdout())
	}
}

func TestAdoptLingerYesNeverTouchesOtherFailures(t *testing.T) {
	e := newEnv(t)
	e.useProbe(probeText("", "init", "akash", "/x/benchbar", "no"))
	if code := e.run("adopt-distro", "--yes"); code != 1 {
		t.Fatalf("exit %d", code)
	}
	for _, s := range e.starts() {
		if len(s.Exec) > 0 && s.Exec[0] != "/bin/sh" && s.Exec[0] != "loginctl" {
			t.Errorf("unexpected call %q", s.Exec)
		}
	}
}

func TestAdoptLingerPrompt(t *testing.T) {
	for _, tc := range []struct {
		answer string
		want   int
	}{{"y\n", 1}, {"Y\n", 1}, {"n\n", 0}, {"\n", 0}, {"", 0}} {
		e := newEnv(t)
		e.useProbe(lingerOff())
		e.StdinIsTerminal = true
		e.Stdin = strings.NewReader(tc.answer)
		if code := e.run("adopt-distro"); code != 0 {
			t.Fatalf("exit %d", code)
		}
		if !strings.Contains(e.stdout(), "Enable linger for akash in Ubuntu-24.04 now? [y/N] ") {
			t.Errorf("no prompt in:\n%s", e.stdout())
		}
		if got := len(loginctlCalls(e)); got != tc.want {
			t.Errorf("answer %q: %d loginctl calls, want %d", tc.answer, got, tc.want)
		}
	}
}

func TestAdoptNoPromptWithoutTerminal(t *testing.T) {
	e := newEnv(t)
	e.useProbe(lingerOff())
	e.Stdin = strings.NewReader("y\n")
	e.run("adopt-distro")
	if strings.Contains(e.stdout(), "[y/N]") || len(loginctlCalls(e)) != 0 {
		t.Errorf("prompted without a terminal:\n%s", e.stdout())
	}
}

func TestAdoptJSON(t *testing.T) {
	e := newEnv(t)
	e.useProbe(lingerOff())
	in := strings.NewReader("y\n")
	e.Stdin, e.StdinIsTerminal = in, true
	if code := e.run("adopt-distro", "--json"); code != 0 {
		t.Fatalf("exit %d", code)
	}
	if in.Len() != 2 {
		t.Error("--json read from stdin")
	}
	if len(loginctlCalls(e)) != 0 {
		t.Error("--json changed linger without --yes")
	}
	var r adoptJSON
	if err := json.Unmarshal(e.out.Bytes(), &r); err != nil {
		t.Fatalf("%v\n%s", err, e.stdout())
	}
	if r.Distro != "Ubuntu-24.04" || !r.Recorded || len(r.Checks) != 5 {
		t.Errorf("%+v", r)
	}
	ids := []string{"distro", "wsl2", "systemd", "benchbar", "linger"}
	for i, c := range r.Checks {
		if c.ID != ids[i] {
			t.Errorf("check %d is %q, want %q", i, c.ID, ids[i])
		}
	}
	if r.Checks[4].Status != "warn" || !strings.HasSuffix(r.Checks[4].Fix, "enable-linger akash") {
		t.Errorf("%+v", r.Checks[4])
	}
	if strings.Contains(e.stdout(), "Recorded") || strings.Contains(e.stdout(), "WSL DISTRO") {
		t.Errorf("text mixed into JSON:\n%s", e.stdout())
	}
}

func TestAdoptJSONFailNotRecorded(t *testing.T) {
	e := newEnv(t)
	e.useProbe(probeText("", "init", "akash", "", "no"))
	if code := e.run("adopt-distro", "--json"); code != 1 {
		t.Fatalf("exit %d", code)
	}
	var r adoptJSON
	if err := json.Unmarshal(e.out.Bytes(), &r); err != nil {
		t.Fatal(err)
	}
	if r.Recorded || e.configExists() {
		t.Error("recorded despite FAIL")
	}
}

func TestAdoptJSONUnregisteredHasChecks(t *testing.T) {
	e := newEnv(t)
	e.run("adopt-distro", "Nope", "--json")
	var r adoptJSON
	if err := json.Unmarshal(e.out.Bytes(), &r); err != nil || len(r.Checks) != 1 || r.Checks[0].Status != "fail" {
		t.Errorf("%v %+v\n%s", err, r, e.stdout())
	}
}

func TestParseProbeToleratesCRLF(t *testing.T) {
	r := parseProbe("pid1=systemd\r\nuser=akash\r\nlinger=yes\r\nbenchbar=/x\r\nwslconf_b64=" +
		base64.StdEncoding.EncodeToString([]byte(goodConf)) + "\r\n")
	if r.pid1 != "systemd" || r.user != "akash" || r.linger != "yes" || r.bench != "/x" || r.wslConf != goodConf {
		t.Errorf("%+v", r)
	}
}

func TestAdoptSystemdBootSectionExists(t *testing.T) {
	e := newEnv(t)
	e.useProbe(probeText("[boot]\ncommand=service x start\n", "init", "akash", "/x/benchbar", "yes"))
	e.run("adopt-distro")
	want := "fix: set systemd=true under [boot] in /etc/wsl.conf (wsl.exe -d Ubuntu-24.04 -- sudo nano /etc/wsl.conf), then wsl.exe --terminate Ubuntu-24.04"
	if !strings.Contains(e.stdout(), want) || strings.Contains(e.stdout(), "printf") {
		t.Errorf("output:\n%s", e.stdout())
	}
}

func TestAdoptNoDistroAtAllSuggestsInstall(t *testing.T) {
	e := newEnv(t)
	e.distros.list = nil
	e.run("adopt-distro")
	if !strings.Contains(e.stdout(), "fix: wsl.exe --install -d Ubuntu-24.04") {
		t.Errorf("output:\n%s", e.stdout())
	}
}
