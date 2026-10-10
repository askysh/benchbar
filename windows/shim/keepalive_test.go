package main

import (
	"bytes"
	"context"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"unicode/utf16"
)

const (
	testExe   = `C:\tools\benchbar\benchbar.exe`
	testUser  = `PC\tester`
	statusCSV = `"PC","\BenchBar Keepalive","N/A","Running","Interactive only","10-10-2026 19:39:23","267009","N/A","conhost.exe --headless "C:\tools\benchbar\benchbar.exe" keepalive run --distro "Ubuntu-24.04"","C:\tools\benchbar","N/A","Enabled","Disabled"` + "\r\r\n"
)

func taskXMLOutput(args string) string {
	return "<?xml version=\"1.0\" encoding=\"UTF-16\"?>\r\r\n<Task version=\"1.3\" xmlns=\"http://schemas.microsoft.com/windows/2004/02/mit/task\">\r\r\n" +
		"  <Actions Context=\"Author\">\r\r\n    <Exec>\r\r\n      <Command>conhost.exe</Command>\r\r\n      <Arguments>" + args + "</Arguments>\r\r\n    </Exec>\r\r\n  </Actions>\r\r\n</Task>\r\r\n"
}

func installedArgs() string {
	return `--headless "` + testExe + `" keepalive run --distro "Ubuntu-24.04"`
}

func (e *env) taskHandler(xmlOut, csvOut string) {
	e.tasks.handler = func(a []string) (string, int, error) {
		if a[0] == "/Query" {
			for _, x := range a {
				if x == "/XML" {
					return xmlOut, 0, nil
				}
			}
			return csvOut, 0, nil
		}
		return "", 0, nil
	}
}

func (e *env) taskNotInstalled() {
	e.tasks.handler = func(a []string) (string, int, error) {
		return "ERROR: The system cannot find the file specified.\r\n", 1, nil
	}
}

func decodeUTF16LE(t *testing.T, b []byte) string {
	t.Helper()
	if len(b) < 2 || b[0] != 0xFF || b[1] != 0xFE {
		t.Fatal("no UTF-16LE BOM")
	}
	b = b[2:]
	u := make([]uint16, len(b)/2)
	for i := range u {
		u[i] = uint16(b[2*i]) | uint16(b[2*i+1])<<8
	}
	return string(utf16.Decode(u))
}

func TestKeepaliveXMLContent(t *testing.T) {
	x := keepaliveXML(testUser, testExe, "Ubuntu-24.04")
	for _, want := range []string{
		`<LogonTrigger>`,
		`<UserId>PC\tester</UserId>`,
		`<LogonType>InteractiveToken</LogonType>`,
		`<RunLevel>LeastPrivilege</RunLevel>`,
		`<Hidden>true</Hidden>`,
		`<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>`,
		`<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>`,
		`<StartWhenAvailable>true</StartWhenAvailable>`,
		`<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>`,
		`<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>`,
		`<Interval>PT1M</Interval>`,
		`<Count>999</Count>`,
		`<AllowHardTerminate>true</AllowHardTerminate>`,
		`<Command>conhost.exe</Command>`,
		`<Arguments>--headless &#34;C:\tools\benchbar\benchbar.exe&#34; keepalive run --distro &#34;Ubuntu-24.04&#34;</Arguments>`,
	} {
		if !strings.Contains(x, want) {
			t.Errorf("missing %s", want)
		}
	}
	if strings.Contains(x, "\u2014") {
		t.Error("em dash in XML")
	}
}

func TestKeepaliveXMLEscapes(t *testing.T) {
	x := keepaliveXML(`DOM\a<b>&c`, `C:\R&D <x>\benchbar.exe`, "Ubu&ntu")
	for _, want := range []string{`DOM\a&lt;b&gt;&amp;c`, `C:\R&amp;D &lt;x&gt;\benchbar.exe`, `Ubu&amp;ntu`} {
		if !strings.Contains(x, want) {
			t.Errorf("missing %s in\n%s", want, x)
		}
	}
	// still well formed, and the arguments come back as they went in
	d := xml.NewDecoder(strings.NewReader(x))
	d.CharsetReader = func(label string, r io.Reader) (io.Reader, error) { return r, nil }
	var args string
	in := false
	for {
		tok, err := d.Token()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatalf("not well formed: %v", err)
		}
		switch v := tok.(type) {
		case xml.StartElement:
			in = v.Name.Local == "Arguments"
		case xml.CharData:
			if in {
				args += string(v)
			}
		case xml.EndElement:
			in = false
		}
	}
	if want := `--headless "C:\R&D <x>\benchbar.exe" keepalive run --distro "Ubu&ntu"`; args != want {
		t.Errorf("arguments %q want %q", args, want)
	}
	exe, distro, ok := parseTaskArguments(x)
	if !ok || exe != `C:\R&D <x>\benchbar.exe` || distro != "Ubu&ntu" {
		t.Errorf("parse: %q %q %v", exe, distro, ok)
	}
}

func TestUTF16LE(t *testing.T) {
	s := "<a>caf\u00e9 \U0001F600</a>\r\n"
	b := utf16LE(s)
	if b[0] != 0xFF || b[1] != 0xFE {
		t.Fatalf("BOM % x", b[:2])
	}
	if got := decodeUTF16LE(t, b); got != s {
		t.Errorf("round trip %q", got)
	}
}

func TestKeepaliveInstall(t *testing.T) {
	e := newEnv(t)
	var xmlSeen string
	var file string
	e.tasks.handler = func(a []string) (string, int, error) {
		if a[0] == "/Create" {
			file = a[4]
			data, err := os.ReadFile(a[4])
			if err != nil {
				t.Errorf("task file unreadable: %v", err)
			}
			xmlSeen = decodeUTF16LE(t, data)
		}
		return "SUCCESS", 0, nil
	}
	if code := e.run("keepalive", "install"); code != 0 {
		t.Fatalf("exit %d: %s", code, e.stderr())
	}
	if len(e.tasks.calls) != 2 {
		t.Fatalf("calls %v", e.tasks.calls)
	}
	c := e.tasks.calls[0]
	if len(c) != 6 || c[0] != "/Create" || c[1] != "/TN" || c[2] != "BenchBar Keepalive" || c[3] != "/XML" || c[5] != "/F" {
		t.Errorf("create call %q", c)
	}
	if got := strings.Join(e.tasks.calls[1], "|"); got != "/Run|/TN|BenchBar Keepalive" {
		t.Errorf("run call %q", got)
	}
	if !strings.Contains(xmlSeen, `<UserId>PC\tester</UserId>`) || !strings.Contains(xmlSeen, `&#34;`+testExe+`&#34;`) ||
		!strings.Contains(xmlSeen, `--distro &#34;Ubuntu-24.04&#34;`) {
		t.Errorf("xml:\n%s", xmlSeen)
	}
	if _, err := os.Stat(file); err == nil {
		t.Error("temp task file left behind")
	}
}

func TestKeepaliveInstallWithDistroFlag(t *testing.T) {
	e := newEnv(t)
	e.distros.list = []Distro{ubuntu, {Name: "Debian", Version: 2}}
	var seen string
	e.tasks.handler = func(a []string) (string, int, error) {
		if a[0] == "/Create" {
			data, _ := os.ReadFile(a[4])
			seen = decodeUTF16LE(t, data)
		}
		return "", 0, nil
	}
	if code := e.run("keepalive", "install", "--distro", "debian"); code != 0 {
		t.Fatalf("exit %d: %s", code, e.stderr())
	}
	if !strings.Contains(seen, `--distro &#34;Debian&#34;`) {
		t.Errorf("xml:\n%s", seen)
	}
}

func TestKeepaliveInstallFailureStops(t *testing.T) {
	e := newEnv(t)
	e.tasks.handler = func(a []string) (string, int, error) {
		return "ERROR: Access is denied.", 1, nil
	}
	if code := e.run("keepalive", "install"); code != 1 {
		t.Errorf("exit %d", code)
	}
	if len(e.tasks.calls) != 1 {
		t.Errorf("calls %v", e.tasks.calls)
	}
	if !strings.Contains(e.stderr(), "Access is denied") {
		t.Errorf("stderr %q", e.stderr())
	}
}

func TestKeepaliveStatusInstalled(t *testing.T) {
	for _, args := range []string{installedArgs(), strings.ReplaceAll(installedArgs(), `"`, "&quot;")} {
		e := newEnv(t)
		e.taskHandler(taskXMLOutput(args), statusCSV)
		e.FileExists = func(p string) bool { return p == testExe }
		if code := e.run("keepalive", "status"); code != 0 {
			t.Fatalf("exit %d", code)
		}
		want := "  [OK] Keepalive: installed for Ubuntu-24.04 via " + testExe + " (status Running, last result 267009); run process is not running\n"
		if e.stdout() != want {
			t.Errorf("got  %q\nwant %q", e.stdout(), want)
		}
		if got := strings.Join(e.tasks.calls[0], " "); got != "/Query /TN BenchBar Keepalive /XML" {
			t.Errorf("first call %q", got)
		}
		if got := strings.Join(e.tasks.calls[1], " "); got != "/Query /TN BenchBar Keepalive /FO CSV /V /NH" {
			t.Errorf("second call %q", got)
		}
	}
}

func TestKeepaliveStatusExeMissing(t *testing.T) {
	e := newEnv(t)
	e.taskHandler(taskXMLOutput(installedArgs()), statusCSV)
	if code := e.run("keepalive", "status"); code != 0 {
		t.Fatalf("exit %d", code)
	}
	if !strings.Contains(e.stdout(), "[WARN] Keepalive: installed, but "+testExe+" does not exist") ||
		!strings.Contains(e.stdout(), "fix: benchbar.exe keepalive install") {
		t.Errorf("output %q", e.stdout())
	}
}

func TestKeepaliveStatusNotInstalled(t *testing.T) {
	e := newEnv(t)
	e.taskNotInstalled()
	if code := e.run("keepalive", "status"); code != 0 {
		t.Fatalf("exit %d", code)
	}
	if want := "  [WARN] Keepalive: not installed\n     fix: benchbar.exe keepalive install\n"; e.stdout() != want {
		t.Errorf("got %q", e.stdout())
	}
}

func TestKeepaliveStatusSchtasksMissing(t *testing.T) {
	e := newEnv(t)
	e.tasks.handler = func(a []string) (string, int, error) { return "", -1, errors.New("not found") }
	e.run("keepalive", "status")
	if !strings.Contains(e.stdout(), "[WARN] Keepalive: cannot run schtasks.exe") {
		t.Errorf("output %q", e.stdout())
	}
}

func TestKeepaliveStatusJSON(t *testing.T) {
	e := newEnv(t)
	e.taskHandler(taskXMLOutput(installedArgs()), statusCSV)
	e.FileExists = func(p string) bool { return p == testExe }
	if code := e.run("keepalive", "status", "--json"); code != 0 {
		t.Fatal(code)
	}
	var info keepaliveInfo
	if err := json.Unmarshal(e.out.Bytes(), &info); err != nil {
		t.Fatalf("%v\n%s", err, e.stdout())
	}
	if !info.Installed || info.Task != "BenchBar Keepalive" || info.Exe != testExe || info.Distro != "Ubuntu-24.04" ||
		!info.ExeExists || info.Status != "Running" || info.LastResult != "267009" || len(info.Checks) != 1 {
		t.Errorf("%+v", info)
	}
}

func TestKeepaliveRemove(t *testing.T) {
	e := newEnv(t)
	e.taskNotInstalled()
	if code := e.run("keepalive", "remove"); code != 0 {
		t.Errorf("exit %d for a task that is not there", code)
	}
	if len(e.tasks.calls) != 1 {
		t.Errorf("calls %v", e.tasks.calls)
	}

	e2 := newEnv(t)
	if code := e2.run("keepalive", "remove"); code != 0 {
		t.Fatalf("exit %d: %s", code, e2.stderr())
	}
	var got []string
	for _, c := range e2.tasks.calls {
		got = append(got, strings.Join(c, " "))
	}
	want := []string{"/Query /TN BenchBar Keepalive", "/End /TN BenchBar Keepalive", "/Delete /TN BenchBar Keepalive /F"}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("calls\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}

	e3 := newEnv(t)
	e3.tasks.handler = func(a []string) (string, int, error) {
		if a[0] == "/Delete" {
			return "ERROR: Access is denied.", 1, nil
		}
		return "", 0, nil
	}
	if code := e3.run("keepalive", "remove"); code != 1 {
		t.Errorf("exit %d, want 1 when delete fails", code)
	}
}

func TestKeepaliveUsage(t *testing.T) {
	e := newEnv(t)
	for _, args := range [][]string{{"keepalive"}, {"keepalive", "bogus"}, {"keepalive", "status", "--nope"}} {
		if code := e.run(args...); code != 1 {
			t.Errorf("%v: exit %d", args, code)
		}
	}
	if len(e.tasks.calls) != 0 {
		t.Error("schtasks must not run for a usage error")
	}
}

func TestNextBackoff(t *testing.T) {
	cases := []struct{ cur, ran, wait, next time.Duration }{
		{10 * time.Second, 0, 10 * time.Second, 20 * time.Second},
		{20 * time.Second, time.Second, 20 * time.Second, 40 * time.Second},
		{160 * time.Second, 0, 160 * time.Second, 5 * time.Minute},
		{5 * time.Minute, 0, 5 * time.Minute, 5 * time.Minute},
		{5 * time.Minute, 10 * time.Minute, 10 * time.Second, 20 * time.Second},
		{80 * time.Second, 9*time.Minute + 59*time.Second, 80 * time.Second, 160 * time.Second},
	}
	for _, c := range cases {
		if w, n := nextBackoff(c.cur, c.ran); w != c.wait || n != c.next {
			t.Errorf("nextBackoff(%v, %v) = %v, %v; want %v, %v", c.cur, c.ran, w, n, c.wait, c.next)
		}
	}
}

func TestKeepaliveRunLoop(t *testing.T) {
	e := newEnv(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	e.Ctx = ctx
	var slept []time.Duration
	e.Sleep = func(ctx context.Context, d time.Duration) {
		slept = append(slept, d)
		if len(slept) == 2 {
			cancel()
		}
	}
	if code := e.run("keepalive", "run"); code != 0 {
		t.Fatalf("exit %d: %s", code, e.stderr())
	}
	if len(slept) != 2 || slept[0] != 10*time.Second || slept[1] != 20*time.Second {
		t.Errorf("sleeps %v", slept)
	}
	st := e.starts()
	if len(st) != 3 {
		t.Fatalf("%d wsl.exe calls", len(st))
	}
	if strings.Join(st[0].Args, " ") != "-d Ubuntu-24.04 --exec /bin/true" {
		t.Errorf("first call %q", st[0].Args)
	}
	for _, s := range st[1:] {
		if strings.Join(s.Args, " ") != "-d Ubuntu-24.04 --exec sleep infinity" {
			t.Errorf("call %q", s.Args)
		}
	}
	data, err := os.ReadFile(filepath.Join(e.ConfigDir, "keepalive.log"))
	if err != nil {
		t.Fatal(err)
	}
	log := string(data)
	for _, want := range []string{"keepalive for Ubuntu-24.04 started", "starting sleep infinity", "ended after", "next start in 10s", "next start in 20s", "stopped"} {
		if !strings.Contains(log, want) {
			t.Errorf("log lacks %q:\n%s", want, log)
		}
	}
	for _, line := range strings.Split(strings.TrimSpace(log), "\n") {
		if !strings.HasPrefix(line, "2026-01-02 03:04:05 ") {
			t.Errorf("bad log line %q", line)
		}
	}
}

func TestKeepaliveRunStopsOnCancelWhileRunning(t *testing.T) {
	e := newEnv(t)
	ctx, cancel := context.WithCancel(context.Background())
	e.Ctx = ctx
	t.Setenv("FAKE_WSL_MODE", "wait-signal")
	t.Setenv("FAKE_WSL_READY", "")
	// the fake only exits on an interrupt; cancelling the context must kill it
	done := make(chan int, 1)
	go func() { done <- e.run("keepalive", "run") }()
	deadline := time.Now().Add(15 * time.Second)
	for len(e.starts()) < 1 && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	cancel()
	select {
	case code := <-done:
		if code != 0 {
			t.Errorf("exit %d", code)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("keepalive run did not stop")
	}
}

func TestKeepaliveLogTruncatesPastOneMB(t *testing.T) {
	e := newEnv(t)
	os.MkdirAll(e.ConfigDir, 0o755)
	path := filepath.Join(e.ConfigDir, "keepalive.log")
	os.WriteFile(path, bytes.Repeat([]byte("old line\n"), 130000), 0o644)
	keepaliveLog{e.System}.printf("fresh %d", 1)
	data, _ := os.ReadFile(path)
	if string(data) != "2026-01-02 03:04:05 fresh 1\n" {
		t.Errorf("log %d bytes: %q", len(data), data[:min(len(data), 80)])
	}
	keepaliveLog{e.System}.printf("second")
	data, _ = os.ReadFile(path)
	if !strings.HasSuffix(string(data), "second\n") || !strings.Contains(string(data), "fresh 1\n") {
		t.Errorf("log %q", data)
	}
}

func (e *env) writePid(pid int, created uint64) string {
	e.t.Helper()
	os.MkdirAll(e.ConfigDir, 0o755)
	p := filepath.Join(e.ConfigDir, "keepalive.pid")
	data := fmt.Sprintf(`{"pid":%d,"created":%d}`+"\n", pid, created)
	if err := os.WriteFile(p, []byte(data), 0o644); err != nil {
		e.t.Fatal(err)
	}
	return p
}

func fileGone(p string) bool { _, err := os.Stat(p); return err != nil }

func TestKeepaliveRemoveTerminatesMatchingRunProcess(t *testing.T) {
	e := newEnv(t)
	e.procs.add(777, `C:\tools\benchbar\BenchBar.exe`)
	e.procs.add(888, `C:\Windows\notepad.exe`)
	p := e.writePid(777, 777000)
	if code := e.run("keepalive", "remove"); code != 0 {
		t.Fatalf("exit %d: %s", code, e.stderr())
	}
	if fmt.Sprint(e.procs.terminated) != "[777]" {
		t.Errorf("terminated %v", e.procs.terminated)
	}
	if !fileGone(p) || !strings.Contains(e.stdout(), "Stopped the keepalive run process (pid 777)") {
		t.Errorf("pid file gone=%v output %q", fileGone(p), e.stdout())
	}
}

func TestKeepaliveRemoveLeavesOtherImagesAlone(t *testing.T) {
	e := newEnv(t)
	e.procs.add(888, `C:\Windows\notepad.exe`)
	p := e.writePid(888, 888000)
	if code := e.run("keepalive", "remove"); code != 0 {
		t.Fatal(code)
	}
	if len(e.procs.terminated) != 0 {
		t.Errorf("terminated %v", e.procs.terminated)
	}
	if !fileGone(p) {
		t.Error("pid file should still be removed")
	}
}

func TestKeepaliveRemoveLeavesReusedPidAlone(t *testing.T) {
	// another benchbar.exe now has the pid; its creation time differs
	e := newEnv(t)
	e.procs.add(777, testExe)
	e.writePid(777, 12345)
	if code := e.run("keepalive", "remove"); code != 0 {
		t.Fatal(code)
	}
	if len(e.procs.terminated) != 0 {
		t.Errorf("killed a process that reused the pid: %v", e.procs.terminated)
	}
}

func TestKeepaliveLegacyPidFileIsNotTrusted(t *testing.T) {
	e := newEnv(t)
	e.procs.add(777, testExe)
	os.MkdirAll(e.ConfigDir, 0o755)
	os.WriteFile(filepath.Join(e.ConfigDir, "keepalive.pid"), []byte("777\n"), 0o644)
	e.run("keepalive", "remove")
	if len(e.procs.terminated) != 0 {
		t.Errorf("terminated %v", e.procs.terminated)
	}
}

func TestKeepaliveRemoveIgnoresStalePidFile(t *testing.T) {
	e := newEnv(t)
	e.taskNotInstalled()
	p := e.writePid(999, 999000) // no such process
	if code := e.run("keepalive", "remove"); code != 0 {
		t.Fatal(code)
	}
	if len(e.procs.terminated) != 0 || !fileGone(p) {
		t.Errorf("terminated %v, pid file gone %v", e.procs.terminated, fileGone(p))
	}
}

func TestKeepaliveRemoveStopsOrphanWhenTaskIsGone(t *testing.T) {
	e := newEnv(t)
	e.taskNotInstalled()
	e.procs.add(777, testExe)
	e.writePid(777, 777000)
	e.run("keepalive", "remove")
	if fmt.Sprint(e.procs.terminated) != "[777]" {
		t.Errorf("terminated %v", e.procs.terminated)
	}
}

func TestKeepaliveInstallReplacesRunningKeepalive(t *testing.T) {
	e := newEnv(t)
	e.distros.list = []Distro{ubuntu, {Name: "Debian", Version: 2}}
	e.procs.add(777, testExe)
	e.writePid(777, 777000)
	if code := e.run("keepalive", "install", "--distro", "Debian"); code != 0 {
		t.Fatalf("exit %d: %s", code, e.stderr())
	}
	if fmt.Sprint(e.procs.terminated) != "[777]" {
		t.Errorf("old run not stopped: %v", e.procs.terminated)
	}
	var names []string
	for _, c := range e.tasks.calls {
		names = append(names, c[0])
	}
	if strings.Join(names, " ") != "/Create /End /Run" {
		t.Errorf("schtasks calls %v", names)
	}
}

func TestKeepaliveInstallLeavesReusedPidAlone(t *testing.T) {
	e := newEnv(t)
	e.procs.add(777, testExe)
	e.writePid(777, 1)
	e.run("keepalive", "install")
	if len(e.procs.terminated) != 0 {
		t.Errorf("terminated %v", e.procs.terminated)
	}
}

func TestKeepaliveRunExitsWhenAnotherHoldsTheLock(t *testing.T) {
	e := newEnv(t)
	e.locks.held[runLockName] = true
	if code := e.run("keepalive", "run"); code != 0 {
		t.Fatalf("exit %d", code)
	}
	if len(e.starts()) != 0 {
		t.Error("a second run started wsl.exe")
	}
	if _, err := os.Stat(filepath.Join(e.ConfigDir, "keepalive.pid")); err == nil {
		t.Error("the second run wrote a pid file")
	}
	log, _ := os.ReadFile(filepath.Join(e.ConfigDir, "keepalive.log"))
	if !strings.Contains(string(log), "another keepalive run holds "+runLockName+", exiting") {
		t.Errorf("log %q", log)
	}
}

func TestKeepaliveRunHoldsTheLockAndWritesJSONPid(t *testing.T) {
	e := newEnv(t)
	e.procs.add(4242, testExe)
	e.writePid(999, 1) // stale file from a dead run
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	e.Ctx = ctx
	p := filepath.Join(e.ConfigDir, "keepalive.pid")
	var during string
	var lockedDuring bool
	e.Sleep = func(ctx context.Context, d time.Duration) {
		data, _ := os.ReadFile(p)
		during = strings.TrimSpace(string(data))
		lockedDuring = e.locks.held[runLockName]
		cancel()
	}
	if code := e.run("keepalive", "run"); code != 0 {
		t.Fatal(code)
	}
	if during != `{"pid":4242,"created":4242000}` {
		t.Errorf("pid file during the run: %q", during)
	}
	if !lockedDuring || e.locks.held[runLockName] {
		t.Errorf("lock held during %v, after %v", lockedDuring, e.locks.held[runLockName])
	}
	if !fileGone(p) {
		t.Error("pid file left after a normal exit")
	}
	if len(e.starts()) != 2 {
		t.Errorf("%d wsl.exe calls", len(e.starts()))
	}
}

func TestKeepaliveStatusReportsRunProcess(t *testing.T) {
	e := newEnv(t)
	e.taskHandler(taskXMLOutput(installedArgs()), statusCSV)
	e.FileExists = func(p string) bool { return p == testExe }
	e.procs.add(777, testExe)
	e.writePid(777, 777000)
	e.run("keepalive", "status")
	if !strings.Contains(e.stdout(), "run process pid 777 is alive") {
		t.Errorf("output %q", e.stdout())
	}
	e.out.Reset()
	e.run("keepalive", "status", "--json")
	var info keepaliveInfo
	json.Unmarshal(e.out.Bytes(), &info)
	if info.RunPid != 777 || !info.RunAlive {
		t.Errorf("%+v", info)
	}
}
