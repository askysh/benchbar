package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	testFamily   = "Test.BenchBar_abc123xyz"
	testLocal    = `C:\Users\u\AppData\Local`
	testAlias    = testLocal + `\Microsoft\WindowsApps\benchbar.exe`
	testAliasDir = testLocal + `\Microsoft\WindowsApps`
	testVersion  = `C:\Program Files\WindowsApps\Test.BenchBar_0.9.0.0_x64__abc123xyz\benchbar.exe`
	testOldVer   = `C:\Program Files\WindowsApps\Test.BenchBar_0.8.9.0_x64__abc123xyz\benchbar.exe`
	testPrograms = testLocal + `\Programs\BenchBar\benchbar.exe`
)

// packaged turns the fake PC into a Store install: the alias exists (only
// Lstat sees it, as on Windows) and the folders are real temp folders.
func (e *env) packaged() {
	e.Package = PackageInfo{Packaged: true, Family: testFamily}
	e.LocalAppData = testLocal
	e.ExePath = testVersion
	e.LegacyConfigDir = filepath.Join(e.root, "LocalAppData", "BenchBar")
	e.ConfigDir = packagedDataDir(filepath.Join(e.root, "LocalAppData"), testFamily)
	e.setLstat(testAlias)
}

func (e *env) setLstat(paths ...string) {
	set := map[string]bool{}
	for _, p := range paths {
		set[p] = true
	}
	e.LstatExists = func(p string) bool { return set[p] }
}

func TestDetectPackageOnThisHost(t *testing.T) {
	// the tests do not run in a package
	if p := detectPackage(); p.Packaged || p.Family != "" {
		t.Errorf("%+v", p)
	}
}

func TestPackagedDataDir(t *testing.T) {
	got := packagedDataDir(filepath.Join("L"), "Fam_x")
	want := filepath.Join("L", "Packages", "Fam_x", "LocalCache", "Local", "BenchBar")
	if got != want {
		t.Errorf("%q", got)
	}
}

func TestOwnVersionedPath(t *testing.T) {
	cases := []struct {
		name     string
		packaged bool
		path     string
		want     bool
	}{
		{"current version", true, testVersion, true},
		{"old version", true, testOldVer, true},
		{"other case and slashes", true, strings.ToLower(strings.ReplaceAll(testOldVer, `\`, "/")), true},
		{"alias", true, testAlias, false},
		{"other publisher", true, `C:\Program Files\WindowsApps\Test.BenchBar_1.0.0.0_x64__other\benchbar.exe`, false},
		{"other package", true, `C:\Program Files\WindowsApps\Other.App_1.0.0.0_x64__abc123xyz\benchbar.exe`, false},
		{"not under WindowsApps", true, `C:\x\Test.BenchBar_1.0.0.0_x64__abc123xyz\benchbar.exe`, false},
		{"unpackaged", false, testVersion, false},
	}
	for _, c := range cases {
		e := newEnv(t)
		if c.packaged {
			e.Package = PackageInfo{Packaged: true, Family: testFamily}
		}
		if got := e.ownVersionedPath(c.path); got != c.want {
			t.Errorf("%s: %v", c.name, got)
		}
	}
}

func TestImportLegacyConfig(t *testing.T) {
	const old = `{"distro":"Debian","cli_path":"/x"}`
	cases := []struct {
		name     string
		packaged bool
		legacy   string // content, "" for no file
		existing string // content already in the new folder
		want     string // expected content of the new file, "" for none
	}{
		{"packaged imports once", true, old, "", old},
		{"packaged keeps its own", true, old, `{"distro":"Mine"}`, `{"distro":"Mine"}`},
		{"packaged without an old file", true, "", "", ""},
		{"not packaged does nothing", false, old, "", ""},
	}
	for _, c := range cases {
		e := newEnv(t)
		e.packaged()
		if !c.packaged {
			e.Package = PackageInfo{}
			e.ConfigDir = filepath.Join(e.root, "other")
		}
		legacyFile := filepath.Join(e.LegacyConfigDir, "config.json")
		if c.legacy != "" {
			os.MkdirAll(e.LegacyConfigDir, 0o755)
			os.WriteFile(legacyFile, []byte(c.legacy), 0o644)
		}
		if c.existing != "" {
			os.MkdirAll(e.ConfigDir, 0o755)
			os.WriteFile(filepath.Join(e.ConfigDir, "config.json"), []byte(c.existing), 0o644)
		}
		e.run("path", "status")
		got, _ := os.ReadFile(filepath.Join(e.ConfigDir, "config.json"))
		if string(got) != c.want {
			t.Errorf("%s: new file %q, want %q", c.name, got, c.want)
		}
		if c.legacy != "" {
			if b, _ := os.ReadFile(legacyFile); string(b) != c.legacy {
				t.Errorf("%s: the old file changed: %q", c.name, b)
			}
		}
		// a second run imports nothing new
		os.WriteFile(legacyFile, []byte(`{"distro":"Later"}`), 0o644)
		before, _ := os.ReadFile(filepath.Join(e.ConfigDir, "config.json"))
		e.run("path", "status")
		after, _ := os.ReadFile(filepath.Join(e.ConfigDir, "config.json"))
		if c.packaged && c.legacy != "" && string(before) != string(after) {
			t.Errorf("%s: imported twice", c.name)
		}
	}
}

func TestImportLegacyConfigNeverWritesTheOldFolder(t *testing.T) {
	e := newEnv(t)
	e.packaged()
	os.MkdirAll(e.LegacyConfigDir, 0o755)
	os.WriteFile(filepath.Join(e.LegacyConfigDir, "config.json"), []byte(`{"distro":"Debian"}`), 0o644)
	e.run("path", "status")
	if err := updateConfig(e.System, func(c *configFile) { c.setStr("distro", "Ubuntu-24.04") }); err != nil {
		t.Fatal(err)
	}
	entries, _ := os.ReadDir(e.LegacyConfigDir)
	if len(entries) != 1 {
		t.Errorf("the old folder changed: %v", entries)
	}
	if b, _ := os.ReadFile(filepath.Join(e.LegacyConfigDir, "config.json")); string(b) != `{"distro":"Debian"}` {
		t.Errorf("old file: %s", b)
	}
	if got := e.readConfig()["distro"]; string(got) != `"Ubuntu-24.04"` {
		t.Errorf("new file: %s", got)
	}
}

func TestImportLegacyConfigTakesTheLock(t *testing.T) {
	e := newEnv(t)
	e.packaged()
	os.MkdirAll(e.LegacyConfigDir, 0o755)
	os.WriteFile(filepath.Join(e.LegacyConfigDir, "config.json"), []byte(`{"a":1}`), 0o644)
	var seen []string
	e.Locks = lockSpy{inner: e.locks, seen: &seen}
	importLegacyConfig(e.System)
	if len(seen) != 1 || seen[0] != configLockName {
		t.Errorf("locks taken: %v", seen)
	}
}

type lockSpy struct {
	inner Locker
	seen  *[]string
}

func (l lockSpy) TryLock(name string) (func(), bool, error) {
	*l.seen = append(*l.seen, name)
	return l.inner.TryLock(name)
}

func TestPathChecksBothStates(t *testing.T) {
	user := func(dirs ...string) string { return strings.Join(dirs, ";") }
	cases := []struct {
		name     string
		packaged bool
		user     string
		lstat    []string
		files    []string // found by Stat
		status   string
		msgHas   string
		fixHas   string
	}{
		{"packaged: alias first", true, user(testAliasDir), []string{testAlias}, nil, "ok", testAlias, ""},
		{"packaged: alias missing", true, user(testAliasDir), nil, nil, "warn", "alias is missing", "App execution aliases, turn on BenchBar"},
		{"packaged: folder not on PATH", true, user(`C:\a`), []string{testAlias}, nil, "warn", testAliasDir + " is not on PATH", "App execution aliases, turn on BenchBar"},
		{"packaged: other copy first", true, user(`C:\tools`, testAliasDir), []string{testAlias, `C:\tools\benchbar.exe`}, nil, "warn", `another copy comes first: C:\tools\benchbar.exe`, `remove C:\tools from PATH`},
		{"packaged: never asks for path install", true, user(`C:\a`), []string{testAlias}, nil, "warn", "is not on PATH", ""},
		{"not packaged: own folder", false, user(`C:\tools\benchbar`), nil, []string{testExe}, "ok", `C:\tools\benchbar`, ""},
		{"not packaged: Store alias first", false, user(testAliasDir, `C:\tools\benchbar`), []string{testAlias}, []string{testExe}, "warn", "the Microsoft Store install", "benchbar.exe path install"},
		{"not packaged: other copy first", false, user(`C:\tools`, `C:\tools\benchbar`), []string{testAlias}, []string{`C:\tools\benchbar.exe`, testExe}, "warn", `another copy comes first: C:\tools\benchbar.exe (this one`, "benchbar.exe path install"},
	}
	for _, c := range cases {
		e := newEnv(t)
		e.LocalAppData = testLocal
		e.pathSetup(`C:\Windows`, c.user, c.files...)
		e.Getenv = envMap(map[string]string{"LOCALAPPDATA": testLocal})
		e.setLstat(c.lstat...)
		if c.packaged {
			e.Package = PackageInfo{Packaged: true, Family: testFamily}
			e.ExePath = testVersion
		} else {
			e.ExePath = testExe
		}
		k := pathCheck(e.System)
		if k.Status != c.status || !strings.Contains(k.Message, c.msgHas) || !strings.Contains(k.Fix, c.fixHas) {
			t.Errorf("%s: %+v", c.name, k)
		}
		if c.packaged && strings.Contains(k.Fix, "path install") {
			t.Errorf("%s: a packaged copy must not send people to path install: %+v", c.name, k)
		}
		if !c.packaged && strings.Contains(k.Message, "WindowsApps\\Test") {
			t.Errorf("%s: %q", c.name, k.Message)
		}
	}
}

func TestPathInstallAndRemoveWhenPackaged(t *testing.T) {
	for _, sub := range []string{"install", "remove"} {
		e := newEnv(t)
		e.packaged()
		e.pathSetup(`C:\Windows`, `C:\a`)
		e.setLstat(testAlias)
		if code := e.run("path", sub); code != 0 {
			t.Fatalf("%s: exit %d", sub, code)
		}
		want := "The Microsoft Store install provides benchbar through its app execution alias, so there is nothing to change on PATH.\n"
		if e.stdout() != want {
			t.Errorf("%s: %q", sub, e.stdout())
		}
		if e.paths.setCalls != 0 || e.bcast.n != 0 || e.paths.user.Value != `C:\a` {
			t.Errorf("%s changed the PATH: %+v", sub, e.paths)
		}
	}
	// the same commands still work unpackaged
	e := newEnv(t)
	e.pathSetup(`C:\Windows`, `C:\a`)
	e.ExePath = testExe
	e.run("path", "install")
	if e.paths.setCalls != 1 {
		t.Error("unpackaged path install must write")
	}
}

func TestSetupPathStepWhenPackaged(t *testing.T) {
	e := newEnv(t)
	e.packaged()
	e.readyEnv()
	e.ExePath = testVersion
	e.pathSetup(`C:\Windows`, testAliasDir)
	e.Getenv = envMap(map[string]string{"LOCALAPPDATA": testLocal})
	rep := e.report()
	var step setupStep
	for _, s := range rep.Steps {
		if s.ID == "shim_path" {
			step = s
		}
	}
	if step.Status != "ok" || step.Action != nil {
		t.Errorf("%+v", step)
	}
	if !rep.Packaged || rep.DataDir != e.ConfigDir {
		t.Errorf("packaged %v, data_dir %q", rep.Packaged, rep.DataDir)
	}
	e.pathSetup(`C:\Windows`, `C:\a`)
	e.Getenv = envMap(map[string]string{"LOCALAPPDATA": testLocal})
	for _, s := range e.report().Steps {
		if s.ID == "shim_path" && (s.Status != "warn" || s.Action != nil || !strings.Contains(s.Detail, "App execution aliases")) {
			t.Errorf("%+v", s)
		}
	}
}

func TestSetupCheckJSONFields(t *testing.T) {
	for _, packaged := range []bool{true, false} {
		e := newEnv(t)
		e.readyEnv()
		if packaged {
			e.packaged()
		}
		e.out.Reset()
		e.run("setup", "check", "--json")
		var raw map[string]json.RawMessage
		if err := json.Unmarshal(e.out.Bytes(), &raw); err != nil {
			t.Fatal(err)
		}
		if string(raw["packaged"]) != map[bool]string{true: "true", false: "false"}[packaged] {
			t.Errorf("packaged %s", raw["packaged"])
		}
		var dir string
		json.Unmarshal(raw["data_dir"], &dir)
		if dir != e.ConfigDir {
			t.Errorf("data_dir %q, want %q", dir, e.ConfigDir)
		}
	}
}

func TestReportUsesTheOneDataFolder(t *testing.T) {
	for _, packaged := range []bool{true, false} {
		e := reportEnv(t, true, false, nil)
		if packaged {
			e.packaged()
		}
		r := e.reportJSON()
		if !strings.HasPrefix(r.Zip, filepath.Join(e.ConfigDir, "reports")) {
			t.Errorf("packaged=%v: zip %q is not under %q", packaged, r.Zip, e.ConfigDir)
		}
		if _, err := os.Stat(r.Zip); err != nil {
			t.Errorf("the printed path does not exist: %v", err)
		}
		var doc map[string]any
		json.Unmarshal(e.out.Bytes(), &doc)
		if doc["packaged"] != packaged || doc["data_dir"] != e.ConfigDir {
			t.Errorf("packaged=%v: %v", packaged, doc)
		}
		sum := string(zipFiles(t, r.Zip)["summary.txt"])
		if !strings.Contains(sum, "data folder: ") {
			t.Errorf("summary:\n%s", sum)
		}
		if packaged != strings.Contains(sum, "install: Microsoft Store package "+testFamily) {
			t.Errorf("summary:\n%s", sum)
		}
	}
}

func TestAdoptPrintsTheRealConfigPath(t *testing.T) {
	e := newEnv(t)
	e.packaged()
	if got, want := configPath(e.System), filepath.Join(e.ConfigDir, "config.json"); got != want {
		t.Errorf("%q", got)
	}
	if strings.Contains(configPath(e.System), "LocalAppData"+string(filepath.Separator)+"BenchBar") {
		t.Error("the printed path is the redirected one")
	}
}

func keepaliveEnv(t *testing.T, packaged bool) *env {
	e := newEnv(t)
	e.LocalAppData = testLocal
	e.Getenv = envMap(map[string]string{})
	e.ExePath = testExe
	if packaged {
		e.Package = PackageInfo{Packaged: true, Family: testFamily}
		e.ExePath = testVersion
		e.setLstat(testAlias)
	}
	return e
}

func TestKeepaliveInstallProgram(t *testing.T) {
	for _, packaged := range []bool{true, false} {
		e := keepaliveEnv(t, packaged)
		var xmlSeen string
		e.tasks.handler = func(a []string) (string, int, error) {
			if a[0] == "/Create" {
				data, _ := os.ReadFile(a[4])
				xmlSeen = decodeUTF16LE(t, data)
			}
			return "SUCCESS", 0, nil
		}
		if code := e.run("keepalive", "install"); code != 0 {
			t.Fatalf("packaged=%v: exit %d: %s", packaged, code, e.stderr())
		}
		want := testExe
		if packaged {
			want = testAlias
		}
		if !strings.Contains(xmlSeen, `&#34;`+want+`&#34;`) {
			t.Errorf("packaged=%v: xml:\n%s", packaged, xmlSeen)
		}
		if packaged && strings.Contains(xmlSeen, "WindowsApps\\Test.BenchBar") {
			t.Error("the versioned folder is in the task")
		}
	}
}

func TestKeepaliveInstallRefusesWithoutAlias(t *testing.T) {
	e := keepaliveEnv(t, true)
	e.setLstat()
	if code := e.run("keepalive", "install"); code != 1 {
		t.Fatalf("exit %d", code)
	}
	if !strings.Contains(e.stderr(), "alias is missing") || !strings.Contains(e.stderr(), "App execution aliases, turn on BenchBar") {
		t.Errorf("stderr %q", e.stderr())
	}
	if len(e.tasks.calls) != 0 {
		t.Errorf("the task was touched: %v", e.tasks.calls)
	}
}

func TestKeepaliveStatusTable(t *testing.T) {
	cases := []struct {
		name     string
		packaged bool
		exe      string
		exists   []string // Stat sees these
		msgHas   string
		fixHas   string
	}{
		{"packaged: alias", true, testAlias, nil, "installed for Ubuntu-24.04 via " + testAlias + ", but its run process is not running", "keepalive install"},
		{"packaged: current versioned folder is stale", true, testVersion, []string{testVersion}, "a versioned folder of the Store package", "keepalive install"},
		{"packaged: old versioned folder is stale, not missing", true, testOldVer, nil, "a versioned folder of the Store package", "keepalive install"},
		{"packaged: another copy", true, `C:\other\benchbar.exe`, []string{`C:\other\benchbar.exe`}, "not this benchbar.exe (" + testAlias + ")", "keepalive install"},
		{"not packaged: own exe", false, testExe, []string{testExe}, "installed for Ubuntu-24.04 via " + testExe, "keepalive install"},
		{"not packaged: versioned folder is plain missing", false, testOldVer, nil, "does not exist", "keepalive install"},
	}
	for _, c := range cases {
		e := keepaliveEnv(t, c.packaged)
		e.taskHandler(taskXMLOutput(`--headless "`+c.exe+`" keepalive run --distro "Ubuntu-24.04"`), statusCSV)
		set := map[string]bool{}
		for _, p := range c.exists {
			set[p] = true
		}
		e.FileExists = func(p string) bool { return set[p] }
		if c.exe == testAlias {
			// Stat cannot open an alias: only Lstat sees it
			e.setLstat(testAlias)
		}
		if code := e.run("keepalive", "status"); code != 0 {
			t.Fatalf("%s: exit %d", c.name, code)
		}
		if !strings.Contains(e.stdout(), c.msgHas) || !strings.Contains(e.stdout(), "fix: benchbar.exe "+c.fixHas) {
			t.Errorf("%s: %q", c.name, e.stdout())
		}
	}
}

func TestKeepaliveStatusAliasIsHealthyWithARunProcess(t *testing.T) {
	e := keepaliveEnv(t, true)
	e.taskHandler(taskXMLOutput(`--headless "`+testAlias+`" keepalive run --distro "Ubuntu-24.04"`), statusCSV)
	e.procs.add(5000, testVersion)
	os.MkdirAll(e.ConfigDir, 0o755)
	os.WriteFile(pidFile(e.System), []byte(`{"pid":5000,"created":5000000}`), 0o644)
	e.run("keepalive", "status")
	if !strings.HasPrefix(e.stdout(), "  [OK] Keepalive: installed for Ubuntu-24.04 via "+testAlias) {
		t.Errorf("%q", e.stdout())
	}
}

func TestKeepaliveRemoveGuard(t *testing.T) {
	cases := []struct {
		name      string
		packaged  bool
		exe       string
		exists    bool
		wantLeave bool
	}{
		{"packaged: its alias", true, testAlias, true, false},
		{"packaged: an old versioned folder of the family", true, testOldVer, true, false},
		{"packaged: another copy", true, `C:\other\benchbar.exe`, true, true},
		{"not packaged: another copy", false, `C:\other\benchbar.exe`, true, true},
		{"not packaged: the Store alias is another copy", false, testAlias, true, true},
	}
	for _, c := range cases {
		e := keepaliveEnv(t, c.packaged)
		e.taskHandler(taskXMLOutput(`--headless "`+c.exe+`" keepalive run --distro "Ubuntu-24.04"`), statusCSV)
		e.FileExists = func(p string) bool { return c.exists && p == c.exe }
		e.setLstat(testAlias, c.exe)
		if code := e.run("keepalive", "remove"); code != 0 {
			t.Fatalf("%s: exit %d", c.name, code)
		}
		deleted := false
		for _, call := range e.tasks.calls {
			if call[0] == "/Delete" {
				deleted = true
			}
		}
		if deleted == c.wantLeave {
			t.Errorf("%s: deleted=%v\n%s", c.name, deleted, e.stdout())
		}
	}
}

func TestTwoInstallsCheck(t *testing.T) {
	cases := []struct {
		name     string
		packaged bool
		present  bool
		want     bool
	}{
		{"packaged and the installer copy exists", true, true, true},
		{"packaged alone", true, false, false},
		{"installer copy alone", false, true, false},
	}
	for _, c := range cases {
		e := newEnv(t)
		e.LocalAppData = testLocal
		if c.packaged {
			e.Package = PackageInfo{Packaged: true, Family: testFamily}
		}
		if c.present {
			e.setLstat(testPrograms)
		}
		got := twoInstallsCheck(e.System)
		if (len(got) == 1) != c.want {
			t.Fatalf("%s: %+v", c.name, got)
		}
		if c.want && (got[0].Status != "warn" || !strings.Contains(got[0].Message, "two BenchBar installs") ||
			!strings.Contains(got[0].Fix, "install.ps1))) -Uninstall")) {
			t.Errorf("%s: %+v", c.name, got[0])
		}
	}
}

func TestDoctorShowsTwoInstallsWhenPackaged(t *testing.T) {
	e := newEnv(t)
	e.packaged()
	e.pathSetup(`C:\Windows`, testAliasDir)
	e.Getenv = envMap(map[string]string{"LOCALAPPDATA": testLocal})
	e.setLstat(testAlias, testPrograms)
	e.script(rule("--list --running --quiet", 0, "Ubuntu-24.04\r\n"))
	e.run("doctor")
	if !strings.Contains(e.stdout(), "[WARN] Installs: two BenchBar installs are on this PC") {
		t.Errorf("%q", e.stdout())
	}
	if strings.Contains(e.stdout(), "another copy comes first") {
		t.Errorf("a false PATH warning: %q", e.stdout())
	}
}

func TestTrayChecksSkippedWhenPackaged(t *testing.T) {
	for _, packaged := range []bool{true, false} {
		e := newEnv(t)
		e.ExePath = testExe
		e.FileExists = func(p string) bool { return strings.HasSuffix(p, trayExe) }
		e.Getenv = envMap(map[string]string{})
		if packaged {
			e.Package = PackageInfo{Packaged: true, Family: testFamily}
		}
		if got := trayChecks(e.System); (len(got) == 0) != packaged {
			t.Errorf("packaged=%v: %+v", packaged, got)
		}
	}
}

func TestUpdateAdviceNamesTheStoreWhenPackaged(t *testing.T) {
	e := newEnv(t)
	if got := updateFix(e.System); got != "benchbar.exe self-update" {
		t.Errorf("%q", got)
	}
	e.Package = PackageInfo{Packaged: true, Family: testFamily}
	if got := updateFix(e.System); !strings.Contains(got, "Microsoft Store") || strings.Contains(got, "self-update") {
		t.Errorf("%q", got)
	}
	version = "0.8.2"
	defer func() { version = "dev" }()
	lines := []string{"curl: (22) The requested URL returned error: 404"}
	if got := curlHint(22, lines, "Ubuntu-24.04", true); !strings.Contains(got, "Microsoft Store") || strings.Contains(got, "releases page") {
		t.Errorf("%q", got)
	}
	if got := curlHint(22, lines, "Ubuntu-24.04", false); !strings.Contains(got, "releases page") {
		t.Errorf("%q", got)
	}
}
