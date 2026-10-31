package main

import (
	"archive/zip"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// reportEnv is a PC where WSL answers. running and cli say whether the
// distro runs and has benchbar; the CLI's zip holds the bytes cliZip.
func reportEnv(t *testing.T, running, cli bool, cliZip []byte) *env {
	t.Helper()
	e := newEnv(t)
	e.readyEnv()
	e.User = `PC\tester`
	list := "\r\n"
	if running {
		list = "Ubuntu-24.04\r\n"
	}
	rules := []map[string]any{
		rule("--list --running --quiet", 0, list),
		rule("--list --verbose", 0, "  NAME            STATE           VERSION\n* Ubuntu-24.04    Running         2\n"),
		rule("--status", 0, "Default Distribution: Ubuntu-24.04\nDefault Version: 2\n"),
		rule("--version", 0, "WSL version: 2.4.8.0\nKernel version: 5.15.167.4\n"),
		rule("/usr/bin/id -un", 0, "alice\n"),
	}
	if cli {
		rules = append(rules,
			map[string]any{"match": "report --json", "exit": 0,
				"stdout": `{"schema_version":1,"cli_version":"0.8.0","zip":"/tmp/benchbar-report-20260101-000000.zip","redactions":2}` + "\n"},
			map[string]any{"match": "/bin/cat /tmp/benchbar-report", "exit": 0, "stdout_b64": base64.StdEncoding.EncodeToString(cliZip)},
			rule("command -v", 0, "/home/alice/.local/bin/benchbar\n"),
		)
	} else {
		rules = append(rules, rule("command -v", 1, ""))
	}
	rules = append(rules, rule("--cd ~", 0, probeOut("alice", "1000", "systemd", "yes", setupGoodConf, "/home/alice/.local/bin/benchbar", "benchbar 0.8.0")))
	e.script(rules...)
	return e
}

type reportOut struct {
	SchemaVersion int           `json:"schema_version"`
	Zip           string        `json:"zip"`
	Included      []string      `json:"included"`
	Skipped       []skippedPart `json:"skipped"`
	IssueURL      string        `json:"issue_url"`
}

func (e *env) reportJSON(args ...string) reportOut {
	e.t.Helper()
	e.out.Reset()
	if code := e.run(append([]string{"report-windows", "--json"}, args...)...); code != 0 {
		e.t.Fatalf("exit %d: %s", code, e.stderr())
	}
	var r reportOut
	if err := json.Unmarshal(e.out.Bytes(), &r); err != nil {
		e.t.Fatalf("%v\n%s", err, e.stdout())
	}
	return r
}

func zipFiles(t *testing.T, path string) map[string][]byte {
	t.Helper()
	zr, err := zip.OpenReader(path)
	if err != nil {
		t.Fatal(err)
	}
	defer zr.Close()
	out := map[string][]byte{}
	for _, f := range zr.File {
		rc, err := f.Open()
		if err != nil {
			t.Fatal(err)
		}
		out[f.Name], _ = io.ReadAll(rc)
		rc.Close()
	}
	return out
}

func skippedReason(r reportOut, part string) string {
	for _, s := range r.Skipped {
		if s.Part == part {
			return s.Reason
		}
	}
	return ""
}

func TestReportWindowsWithoutWSL(t *testing.T) {
	e := newEnv(t)
	e.User = `PC\tester`
	e.WSLPath = func() (string, error) { return "", errors.New("not found") }
	e.distros.list = nil
	r := e.reportJSON()
	if r.SchemaVersion != 1 || !strings.HasSuffix(r.Zip, ".zip") || !strings.HasPrefix(r.Zip, filepath.Join(e.ConfigDir, "reports")) {
		t.Fatalf("%+v", r)
	}
	if !strings.HasPrefix(filepath.Base(r.Zip), "benchbar-windows-report-20260102-030405") {
		t.Errorf("name %s", r.Zip)
	}
	files := zipFiles(t, r.Zip)
	for _, want := range []string{"summary.txt", "setup-check.json", "wsl-status.txt", "wsl-list.txt"} {
		if _, ok := files[want]; !ok {
			t.Errorf("no %s in %v", want, r.Included)
		}
	}
	if _, ok := files["cli-report.zip"]; ok {
		t.Error("a CLI report without WSL")
	}
	if skippedReason(r, "cli_report") != "WSL is not installed" {
		t.Errorf("%+v", r.Skipped)
	}
	sum := string(files["summary.txt"])
	for _, want := range []string{"benchbar.exe: dev", "Windows: Windows 11 Pro, build 26100", "WSL version: not available", "distro used: Ubuntu-24.04 (WSL not found)"} {
		if !strings.Contains(sum, want) {
			t.Errorf("summary lacks %q:\n%s", want, sum)
		}
	}
	if len(e.events()) != 0 {
		t.Errorf("wsl.exe ran: %+v", e.starts())
	}
	var check setupReport
	if err := json.Unmarshal(files["setup-check.json"], &check); err != nil || check.Distro != "Ubuntu-24.04" {
		t.Errorf("setup-check.json: %v %s", err, files["setup-check.json"])
	}
}

func TestReportWindowsStoppedDistroIsNotStarted(t *testing.T) {
	e := reportEnv(t, false, true, nil)
	r := e.reportJSON()
	if skippedReason(r, "cli_report") != "the distro is stopped" {
		t.Errorf("%+v", r.Skipped)
	}
	for _, ev := range e.starts() {
		j := strings.Join(ev.Args, " ")
		if ev.Distro != "" || strings.Contains(j, "--exec") || strings.Contains(j, "--install") {
			t.Errorf("a stopped distro was touched: %q", j)
		}
	}
	if hasArg(e.events(), "--shutdown") || hasArg(e.events(), "--unregister") {
		t.Error("forbidden wsl.exe call")
	}
	if len(e.elevator().calls) != 0 {
		t.Error("report-windows must never elevate")
	}
	if !strings.Contains(string(zipFiles(t, r.Zip)["summary.txt"]), "(stopped)") {
		t.Error("summary does not say stopped")
	}
}

func TestReportWindowsDistroNotInstalled(t *testing.T) {
	e := reportEnv(t, false, false, nil)
	e.distros.list = nil
	r := e.reportJSON("--distro", "Debian")
	if skippedReason(r, "cli_report") != "the distro Debian is not installed" {
		t.Errorf("%+v", r.Skipped)
	}
}

func TestReportWindowsRunningWithCLI(t *testing.T) {
	var cz bytes.Buffer
	zw := zip.NewWriter(&cz)
	w, _ := zw.Create("doctor.json")
	w.Write([]byte(`{"x":1}`))
	zw.Close()
	e := reportEnv(t, true, true, cz.Bytes())
	r := e.reportJSON("--bench", "/home/alice/frappe-bench", "--context", "wizard: Check Your PC", "--tray-version", "0.8.1")
	if len(r.Skipped) != 0 {
		t.Fatalf("skipped %+v", r.Skipped)
	}
	files := zipFiles(t, r.Zip)
	if !bytes.Equal(files["cli-report.zip"], cz.Bytes()) {
		t.Error("cli-report.zip is not the CLI's zip")
	}
	if got := strings.Join(r.Included, ","); got != "summary.txt,wsl-status.txt,wsl-list.txt,setup-check.json,cli-report.zip" {
		t.Errorf("included %s", got)
	}
	sum := string(files["summary.txt"])
	for _, want := range []string{"tray: 0.8.1", "benchbar CLI: 0.8.0", "WSL version: WSL version: 2.4.8.0", "WSL default distro: Ubuntu-24.04",
		"distro used: Ubuntu-24.04 (running)", "context: wizard: Check Your PC"} {
		if !strings.Contains(sum, want) {
			t.Errorf("summary lacks %q:\n%s", want, sum)
		}
	}
	// the bench path reaches the CLI as one argument, and the zip is read with cat
	found := false
	for _, ev := range e.starts() {
		x := strings.Join(ev.Args, " ")
		if strings.Contains(x, "report") && strings.Contains(x, "--bench-dir /home/alice/frappe-bench") && strings.Contains(x, "--out /tmp") {
			found = true
		}
	}
	if !found {
		t.Errorf("calls: %+v", e.starts())
	}
	if !hasArg(e.events(), "/bin/cat /tmp/benchbar-report-20260101-000000.zip") {
		t.Error("the CLI zip was not read with cat")
	}
}

func TestReportWindowsRunningWithoutCLI(t *testing.T) {
	e := reportEnv(t, true, false, nil)
	r := e.reportJSON()
	if skippedReason(r, "cli_report") != "benchbar is not installed in the distro" {
		t.Errorf("%+v", r.Skipped)
	}
}

func TestReportWindowsCLIFailureIsSkippedNotFatal(t *testing.T) {
	e := reportEnv(t, true, true, nil)
	e.script(
		rule("--list --running --quiet", 0, "Ubuntu-24.04\r\n"),
		rule("/usr/bin/id -un", 0, "alice\n"),
		rule("report --json", 3, ""),
		rule("command -v", 0, "x"),
	)
	r := e.reportJSON()
	if !strings.Contains(skippedReason(r, "cli_report"), "exit code 3") {
		t.Errorf("%+v", r.Skipped)
	}
	if _, ok := zipFiles(t, r.Zip)["summary.txt"]; !ok {
		t.Error("no summary")
	}
}

func TestReportWindowsRedactsEveryTextPart(t *testing.T) {
	e := reportEnv(t, true, false, nil)
	inc := filepath.Join(e.root, "tray-error.log")
	body := "failed in " + e.ProfileDir + `\AppData\Local\BenchBar\tray.log` + "\n" +
		`C:\Users\tester\Desktop\x.txt and c:/users/Tester/y` + "\n" +
		"user tester ran /home/alice/frappe-bench and alice@host\n" +
		`\\wsl.localhost\Ubuntu-24.04\home\alice\.bashrc` + "\n" +
		"MARIADB_ROOT_PASSWORD=hunter2 and password: \"s3cret pw\" and token = abc123\n"
	if err := os.WriteFile(inc, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	e.writeConfig(`{"distro":"Ubuntu-24.04"}`)
	r := e.reportJSON("--include", inc, "--context", "tester at "+e.ProfileDir)
	files := zipFiles(t, r.Zip)
	for name, data := range files {
		if name == "cli-report.zip" {
			continue
		}
		s := string(data)
		for _, bad := range []string{"tester", "Tester", "alice", "hunter2", "s3cret", "abc123", e.ProfileDir} {
			if strings.Contains(s, bad) {
				t.Errorf("%s still holds %q:\n%s", name, bad, s)
			}
		}
	}
	got := string(files["included/tray-error.log"])
	for _, want := range []string{`C:\Users\<user>\AppData\Local\BenchBar\tray.log`, "user <user> ran /home/<user>/frappe-bench", `\home\<user>\.bashrc`, "MARIADB_ROOT_PASSWORD=<redacted>"} {
		if !strings.Contains(got, want) {
			t.Errorf("redacted file lacks %q:\n%s", want, got)
		}
	}
	// the JSON stays valid after redaction, and the report holds no environment dump
	var check setupReport
	if err := json.Unmarshal(files["setup-check.json"], &check); err != nil {
		t.Errorf("setup-check.json: %v", err)
	}
	for name, data := range files {
		if strings.Contains(string(data), "PATH=") && name != "included/tray-error.log" {
			t.Errorf("%s looks like an environment dump", name)
		}
	}
	if strings.Contains(r.IssueURL, "tester") || strings.Contains(r.IssueURL, "alice") {
		t.Errorf("name in the URL: %s", r.IssueURL)
	}
}

func TestReportWindowsIssueURL(t *testing.T) {
	e := reportEnv(t, true, false, nil)
	r := e.reportJSON("--context", "wizard: Check Your PC", "--tray-version", "0.8.1")
	if !strings.HasPrefix(r.IssueURL, "https://github.com/askysh/benchbar/issues/new?template=bug_report_windows.yml&") {
		t.Fatalf("%s", r.IssueURL)
	}
	if strings.Contains(r.IssueURL, "+") || strings.Contains(r.IssueURL, " ") {
		t.Errorf("not encoded: %s", r.IssueURL)
	}
	u, err := url.Parse(r.IssueURL)
	if err != nil {
		t.Fatal(err)
	}
	q := u.Query()
	want := map[string]string{
		"template": "bug_report_windows.yml",
		"title":    "[Windows] wizard: Check Your PC",
		"versions": "benchbar.exe dev, tray 0.8.1, CLI not available",
		"windows":  "Windows 11 Pro, build 26100, " + runtime.GOARCH,
		"distro":   "Ubuntu-24.04, WSL 2.4.8, running",
		"what":     "While: wizard: Check Your PC\n\n\n",
	}
	for k, v := range want {
		if q.Get(k) != v {
			t.Errorf("%s = %q, want %q", k, q.Get(k), v)
		}
	}
	for _, bad := range []string{`\`, "/home", "/mnt", "C:", e.root} {
		if strings.Contains(q.Get("versions")+q.Get("windows")+q.Get("distro")+q.Get("what"), bad) {
			t.Errorf("path-like text %q in the URL fields", bad)
		}
	}
}

func TestReportWindowsIssueURLStaysShort(t *testing.T) {
	e := reportEnv(t, false, false, nil)
	r := e.reportJSON("--context", strings.Repeat("é long ", 600))
	if len(r.IssueURL) >= 4000 {
		t.Errorf("%d characters", len(r.IssueURL))
	}
	if !strings.Contains(r.IssueURL, "versions=") {
		t.Error("lost the version fields")
	}
}

func TestReportWindowsKeepsTheNewestTen(t *testing.T) {
	e := reportEnv(t, false, false, nil)
	dir := filepath.Join(e.ConfigDir, "reports")
	os.MkdirAll(dir, 0o755)
	for i := 1; i <= 12; i++ {
		os.WriteFile(filepath.Join(dir, fmt.Sprintf("benchbar-windows-report-202512%02d-101010.zip", i)), []byte("old"), 0o644)
	}
	os.WriteFile(filepath.Join(dir, "notes.txt"), []byte("mine"), 0o644)
	os.WriteFile(filepath.Join(dir, "benchbar-report-other.zip"), []byte("not ours"), 0o644)
	r := e.reportJSON()
	var zips []string
	for _, n := range e.ListDirReal(dir) {
		if reportNameRE.MatchString(n) {
			zips = append(zips, n)
		}
	}
	if len(zips) != 10 {
		t.Fatalf("%d report zips: %v", len(zips), zips)
	}
	if _, err := os.Stat(r.Zip); err != nil {
		t.Error("the new report was removed")
	}
	if _, err := os.Stat(filepath.Join(dir, "benchbar-windows-report-20251203-101010.zip")); err == nil {
		t.Error("an old report was kept")
	}
	if _, err := os.Stat(filepath.Join(dir, "benchbar-windows-report-20251212-101010.zip")); err != nil {
		t.Error("a newer report was removed")
	}
	for _, keep := range []string{"notes.txt", "benchbar-report-other.zip"} {
		if _, err := os.Stat(filepath.Join(dir, keep)); err != nil {
			t.Errorf("%s was removed", keep)
		}
	}
}

func (e *env) ListDirReal(dir string) []string { return listDir(dir) }

func TestReportWindowsSameSecondKeepsBoth(t *testing.T) {
	e := reportEnv(t, false, false, nil)
	a := e.reportJSON()
	b := e.reportJSON()
	if a.Zip == b.Zip {
		t.Error("the second report overwrote the first")
	}
}

func TestReportWindowsIncludes(t *testing.T) {
	e := reportEnv(t, false, false, nil)
	big := filepath.Join(e.root, "a", "big.log")
	os.MkdirAll(filepath.Dir(big), 0o755)
	data := append(bytes.Repeat([]byte("old line\n"), 200000), []byte("THE LAST LINE\n")...)
	os.WriteFile(big, data, 0o644)
	small := filepath.Join(e.root, "b", "big.log") // the same name
	os.MkdirAll(filepath.Dir(small), 0o755)
	os.WriteFile(small, []byte("small\n"), 0o644)
	r := e.reportJSON("--include", big, "--include="+small, "--include", filepath.Join(e.root, "missing.log"), "--include", e.root)
	files := zipFiles(t, r.Zip)
	got := files["included/big.log"]
	if len(got) > reportIncludeMax+200 || !bytes.HasSuffix(got, []byte("THE LAST LINE\n")) || !bytes.Contains(got, []byte("kept the last")) {
		t.Errorf("tail: %d bytes", len(got))
	}
	if string(files["included/big-2.log"]) != "small\n" {
		t.Errorf("second file: %q", files["included/big-2.log"])
	}
	if len(r.Skipped) < 2 {
		t.Errorf("skipped %+v", r.Skipped)
	}
	reasons := ""
	for _, s := range r.Skipped {
		reasons += s.Part + ";"
	}
	if !strings.Contains(reasons, "include:missing.log") {
		t.Errorf("%s", reasons)
	}
}

func TestReportWindowsPlainOutput(t *testing.T) {
	e := reportEnv(t, false, false, nil)
	if code := e.run("report-windows", "--context", "x"); code != 0 {
		t.Fatalf("%d %s", code, e.stderr())
	}
	out := e.stdout()
	if !strings.Contains(out, "Report written: "+filepath.Join(e.ConfigDir, "reports")) || !strings.Contains(out, "https://github.com/askysh/benchbar/issues/new?template=bug_report_windows.yml") {
		t.Errorf("%s", out)
	}
}

func TestReportWindowsUsageErrors(t *testing.T) {
	for _, args := range [][]string{
		{"report-windows", "--nope"},
		{"report-windows", "extra"},
		{"report-windows", "--bench", "relative/path"},
		{"report-windows", "--distro", "a b"},
		{"report-windows", "--include"},
	} {
		e := reportEnv(t, false, false, nil)
		if code := e.run(args...); code != 1 {
			t.Errorf("%v: exit %d", args, code)
		}
		if _, err := os.Stat(filepath.Join(e.ConfigDir, "reports")); err == nil {
			t.Errorf("%v: wrote a report", args)
		}
	}
	e := reportEnv(t, false, false, nil)
	e.ConfigDir = ""
	if code := e.run("report-windows"); code != 1 {
		t.Errorf("no LOCALAPPDATA: exit %d", code)
	}
}

func TestReportWindowsBrokenConfigDoesNotStopIt(t *testing.T) {
	e := reportEnv(t, false, false, nil)
	e.writeConfig("{not json")
	r := e.reportJSON()
	if _, err := os.Stat(r.Zip); err != nil {
		t.Error(err)
	}
}

func TestReportWindowsClockIsUsedForTheName(t *testing.T) {
	e := reportEnv(t, false, false, nil)
	e.Now = func() time.Time { return time.Date(2027, 3, 4, 5, 6, 7, 0, time.UTC) }
	if r := e.reportJSON(); filepath.Base(r.Zip) != "benchbar-windows-report-20270304-050607.zip" {
		t.Errorf("%s", r.Zip)
	}
}

func TestFixProductName(t *testing.T) {
	if got := fixProductName("Windows 10 Pro", 26100); got != "Windows 11 Pro" {
		t.Error(got)
	}
	if got := fixProductName("Windows 10 Pro", 19045); got != "Windows 10 Pro" {
		t.Error(got)
	}
}
