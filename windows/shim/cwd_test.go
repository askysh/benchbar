package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"unicode/utf16"
)

func (e *env) cwd(dir string) { e.Getwd = func() (string, error) { return dir, nil } }

func TestForwardHandsOverTheWindowsFolder(t *testing.T) {
	for _, c := range []struct{ dir, want string }{
		{`C:\work\bench`, `C:\work\bench`},
		{`D:\`, `D:\`},
		{`\\wsl.localhost\Ubuntu-24.04\home\me\frappe-bench`, `\\wsl.localhost\Ubuntu-24.04\home\me\frappe-bench`},
		{`\\wsl$\ubuntu-24.04\home\me`, `\\wsl$\ubuntu-24.04\home\me`},
		{`\\server\share\bench`, `\\server\share\bench`},
		// a folder of another distro is not reachable from this one
		{`\\wsl.localhost\Debian\home\me`, ``},
		{``, ``},
	} {
		e := newEnv(t)
		e.cwd(c.dir)
		e.run("adopt", ".")
		st := e.starts()
		if len(st) != 1 {
			t.Fatalf("%q: %d calls", c.dir, len(st))
		}
		if st[0].ShimCwd != c.want {
			t.Errorf("cwd %q: handed over %q, want %q", c.dir, st[0].ShimCwd, c.want)
		}
		// a folder of another distro: one notice on stderr, nothing on stdout
		wantErr := ""
		if c.dir != "" && c.want == "" {
			wantErr = "benchbar.exe: " + c.dir + " has no path in WSL, running in ~\n"
		}
		if e.stderr() != wantErr || strings.Contains(e.stdout(), "no path in WSL") {
			t.Errorf("cwd %q: stderr %q (want %q), stdout %q", c.dir, e.stderr(), wantErr, e.stdout())
		}
		if has := strings.Contains(st[0].Wslenv, "BENCHBAR_SHIM_CWD"); has != (c.want != "") {
			t.Errorf("cwd %q: WSLENV %q", c.dir, st[0].Wslenv)
		}
		if st[0].Cd != "~" || strings.Join(st[0].Exec[4:], " ") != "adopt ." {
			t.Errorf("cwd %q: cd %q exec %q", c.dir, st[0].Cd, st[0].Exec)
		}
	}
}

func TestForwardSaysSoWhenItCannotReadTheFolder(t *testing.T) {
	e := newEnv(t)
	e.Getwd = func() (string, error) { return "", os.ErrNotExist }
	e.run("status", "--json")
	st := e.starts()
	if len(st) != 1 || st[0].ShimCwd != "" {
		t.Fatalf("calls %+v", st)
	}
	if got := e.stderr(); strings.Count(got, "\n") != 1 || !strings.HasPrefix(got, "benchbar.exe: the current folder cannot be read") || !strings.HasSuffix(got, "running in ~\n") {
		t.Errorf("stderr %q", got)
	}
	if strings.Contains(e.stdout(), "running in") {
		t.Errorf("stdout %q", e.stdout())
	}
}

func TestForwardKeepsTheUsersWSLENVWhenHandingOverTheFolder(t *testing.T) {
	e := newEnv(t)
	e.cwd(`C:\work`)
	t.Setenv("WSLENV", "FOO/p:BAR")
	t.Setenv("ADMIN_PASSWORD", "x")
	e.run("status")
	if got, want := e.starts()[0].Wslenv, "FOO/p:BAR:ADMIN_PASSWORD:BENCHBAR_SHIM_CWD"; got != want {
		t.Errorf("WSLENV %q, want %q", got, want)
	}
}

func TestOtherShimCallsDoNotCarryTheFolder(t *testing.T) {
	e := newEnv(t)
	e.cwd(`C:\work`)
	e.run("adopt-distro", "--json")
	for _, ev := range e.starts() {
		if ev.ShimCwd != "" {
			t.Errorf("folder on %v", ev.Args)
		}
	}
}

// runWrapper runs the real wrapper in /bin/sh with a stand-in wslpath that
// prints out (or fails when out is empty) and a stand-in benchbar that
// prints where it runs and whether the variable is still set.
func runWrapper(t *testing.T, winCwd, wslpathOut, startDir string) (stdout, stderr string) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("needs /bin/sh")
	}
	home := t.TempDir()
	bin := filepath.Join(home, ".local", "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	wslpath := "#!/bin/sh\nexit 1\n"
	if wslpathOut != "" {
		wslpath = "#!/bin/sh\n[ \"$1 $2 $3\" = '-a -u --' ] || exit 2\n[ \"$4\" = '" + winCwd + "' ] || exit 3\nprintf '%s\\n' '" + wslpathOut + "'\n"
	}
	os.WriteFile(filepath.Join(bin, "wslpath"), []byte(wslpath), 0o755)
	os.WriteFile(filepath.Join(bin, "benchbar"), []byte("#!/bin/sh\necho \"$(pwd -P) [${BENCHBAR_SHIM_CWD-unset}] $*\"\n"), 0o755)
	cmd := exec.Command("/bin/sh", "-c", wrapper, "benchbar", "adopt", ".")
	cmd.Dir = startDir
	cmd.Env = []string{"HOME=" + home, "PATH=/usr/bin:/bin", cwdEnv + "=" + winCwd}
	var so, se strings.Builder
	cmd.Stdout, cmd.Stderr = &so, &se
	if err := cmd.Run(); err != nil {
		t.Fatalf("%v: %s%s", err, so.String(), se.String())
	}
	return strings.TrimSpace(so.String()), se.String()
}

func realPath(t *testing.T, p string) string {
	t.Helper()
	r, err := filepath.EvalSymlinks(p)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestWrapperStartsTheCLIInTheForwardedFolder(t *testing.T) {
	target, home := realPath(t, t.TempDir()), realPath(t, t.TempDir())
	got, notice := runWrapper(t, `C:\work\bench`, target, home)
	if want := target + " [unset] adopt ."; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
	if notice != "" {
		t.Errorf("notice on stderr: %q", notice)
	}
}

// a folder with a space, a non ASCII name and a network folder go through the
// real wrapper whole: the variable is quoted, not word split
func TestWrapperKeepsAwkwardFolderNames(t *testing.T) {
	for _, c := range []struct{ name, win, sub string }{
		{"space", `C:\Users\me\My Bench Folder`, "my bench folder"},
		{"non ASCII", `D:\Entwicklung\Büro\日本語`, "büro 日本語"},
		{"UNC share", `\\server\share\my bench`, "unc share"},
		{"wsl.localhost", `\\wsl.localhost\Ubuntu-24.04\home\me\bench dir`, "bench dir"},
	} {
		base := realPath(t, t.TempDir())
		target := filepath.Join(base, c.sub)
		if err := os.MkdirAll(target, 0o755); err != nil {
			t.Fatal(err)
		}
		home := realPath(t, t.TempDir())
		got, notice := runWrapper(t, c.win, target, home)
		if want := target + " [unset] adopt ."; got != want {
			t.Errorf("%s: got %q, want %q", c.name, got, want)
		}
		if notice != "" {
			t.Errorf("%s: notice %q", c.name, notice)
		}
	}
}

// the same folders through the Go side: handed over as they are
func TestForwardHandsOverAwkwardFolderNames(t *testing.T) {
	for _, dir := range []string{`C:\Users\me\My Bench Folder`, `D:\Entwicklung\Büro\日本語`, `\\server\share\my bench`} {
		e := newEnv(t)
		e.cwd(dir)
		e.run("status")
		if st := e.starts(); len(st) != 1 || st[0].ShimCwd != dir || e.stderr() != "" {
			t.Errorf("%q: %+v, stderr %q", dir, st, e.stderr())
		}
	}
}

func TestWrapperStaysInTheHomeFolderWhenTheFolderIsNotThere(t *testing.T) {
	home := realPath(t, t.TempDir())
	for name, out := range map[string]string{
		"wslpath fails":         "",
		"folder does not exist": "/no/such/folder/for/benchbar",
	} {
		got, notice := runWrapper(t, `Z:\gone`, out, home)
		if want := home + " [unset] adopt ."; got != want {
			t.Errorf("%s: got %q, want %q", name, got, want)
		}
		// stdout holds only the CLI's output; the fallback is one line on stderr
		if want := "benchbar.exe: Z:\\gone has no path in WSL, running in ~\n"; notice != want {
			t.Errorf("%s: stderr %q, want %q", name, notice, want)
		}
	}
}

func TestDriveRootsComeFromTheDistro(t *testing.T) {
	e := newEnv(t)
	e.script(
		map[string]any{"match": "for d; do", "stdout": "/c/\n/win/d/\n"},
		map[string]any{"match": "--exec", "exit": 0},
	)
	e.run("adopt", `C:\a`, "--bench-dir=D:/b", `c:\again`, `.\rel`)
	st := e.starts()
	if len(st) != 2 {
		t.Fatalf("%d calls, want the probe and the command", len(st))
	}
	if got := strings.Join(st[0].Exec[len(st[0].Exec)-3:], " "); got != "sh c d" {
		t.Errorf("probe asks for %q", got)
	}
	if got, want := strings.Join(st[1].Exec[4:], "|"), "adopt|/c/a|--bench-dir=/win/d/b|/c/again|./rel"; got != want {
		t.Errorf("args %q, want %q", got, want)
	}
}

func TestDriveRootsFallBackToMnt(t *testing.T) {
	for _, probe := range []map[string]any{
		{"match": "for d; do", "exit": 1},
		{"match": "for d; do", "stdout": "\n"},
		{"match": "for d; do", "stdout": "not a path\n"},
	} {
		e := newEnv(t)
		e.script(probe, map[string]any{"match": "--exec", "exit": 0})
		e.run("adopt", `C:\a`)
		st := e.starts()
		if got := st[len(st)-1].Exec[5]; got != "/mnt/c/a" {
			t.Errorf("%v: %q", probe, got)
		}
	}
}

func TestNoDriveProbeWithoutADrivePath(t *testing.T) {
	e := newEnv(t)
	e.run("adopt", `.\bench`, "--bench-dir", `\\wsl.localhost\Ubuntu-24.04\home\a`, "C:")
	if st := e.starts(); len(st) != 1 {
		t.Errorf("%d wsl.exe calls", len(st))
	}
}

// --- the one list of variables ---------------------------------------------------------

func TestEveryEnvironmentNameTheCLIDocumentsIsForwardedOrExcluded(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "lib", "frappe-local", "commands.sh"))
	if err != nil {
		t.Skip("the CLI sources are not next to the shim")
	}
	listed := map[string]bool{}
	for _, n := range forwardedEnv {
		listed[n] = true
	}
	found := 0
	for _, line := range strings.Split(string(data), "\n") {
		f := strings.Split(line, "~")
		if len(f) < 3 || f[0] != "env" {
			continue
		}
		found++
		if _, no := noForwardEnv[f[2]]; !listed[f[2]] && !no {
			t.Errorf("%s is documented by the CLI (%s) but the shim neither forwards nor excludes it", f[2], f[1])
		}
	}
	if found == 0 {
		t.Error("no env records found in commands.sh")
	}
	for n := range noForwardEnv {
		if listed[n] {
			t.Errorf("%s is both forwarded and excluded", n)
		}
	}
}

func TestEveryForwardedNameReachesWSLENV(t *testing.T) {
	e := newEnv(t)
	t.Setenv("WSLENV", "")
	for _, n := range forwardedEnv {
		t.Setenv(n, "1")
	}
	e.run("status")
	got := ":" + e.starts()[0].Wslenv + ":"
	for _, n := range forwardedEnv {
		if !strings.Contains(got, ":"+n+":") {
			t.Errorf("%s is not in WSLENV %q", n, got)
		}
	}
}

// --- code pages ------------------------------------------------------------------------

func withOEM(t *testing.T, f func([]byte) string) {
	old := oemDecode
	oemDecode = f
	t.Cleanup(func() { oemDecode = old })
}

func TestDecodeConsole(t *testing.T) {
	// CP 850: 0x82 is e acute, 0x81 is u diaeresis
	withOEM(t, func(b []byte) string {
		return strings.NewReplacer("\x82", "é", "\x81", "ü").Replace(string(b))
	})
	u16 := func(s string) []byte {
		out := []byte{0xFF, 0xFE}
		for _, c := range utf16.Encode([]rune(s)) {
			out = append(out, byte(c), byte(c>>8))
		}
		return out
	}
	cases := []struct {
		name string
		in   []byte
		want string
	}{
		{"ascii", []byte(`C:\Users\bob\benchbar.exe`), `C:\Users\bob\benchbar.exe`},
		{"utf8", []byte("C:\\Users\\José\\x"), "C:\\Users\\José\\x"},
		{"oem accent", []byte("C:\\Users\\Jos\x82\\x"), "C:\\Users\\José\\x"},
		{"oem umlaut", []byte("C:\\Users\\M\x81ller"), "C:\\Users\\Müller"},
		{"utf16 with BOM", u16("C:\\Users\\José"), "C:\\Users\\José"},
		{"empty", nil, ""},
	}
	for _, c := range cases {
		if got := decodeConsole(c.in); got != c.want {
			t.Errorf("%s: %q, want %q", c.name, got, c.want)
		}
	}
}

func TestSchtasksOutputOnAnOEMCodePageKeepsTheExePath(t *testing.T) {
	withOEM(t, func(b []byte) string { return strings.ReplaceAll(string(b), "\x82", "é") })
	raw := []byte("<Exec><Command>C:\\Users\\Jos\x82\\benchbar.exe</Command><Arguments>keepalive run</Arguments></Exec>")
	if got := decodeConsole(raw); !strings.Contains(got, `C:\Users\José\benchbar.exe`) {
		t.Errorf("%q", got)
	}
}

func streamLines(t *testing.T, chunks ...[]byte) []string {
	t.Helper()
	var lines []string
	w := &lineWriter{emit: func(s string) { lines = append(lines, s) }}
	for _, c := range chunks {
		if _, err := w.Write(c); err != nil {
			t.Fatal(err)
		}
	}
	w.Flush()
	return lines
}

func TestLineWriterDecodesUTF16OutputOfAnOldWSL(t *testing.T) {
	enc := func(s string) []byte {
		var out []byte
		for _, c := range utf16.Encode([]rune(s)) {
			out = append(out, byte(c), byte(c>>8))
		}
		return out
	}
	text := enc("Installiere: Windows-Subsystem für Linux\r\nFertig 日本\r\n")
	// split in the middle of a UTF-16 unit and of a line
	got := streamLines(t, append([]byte{0xFF, 0xFE}, text[:7]...), text[7:20], text[20:])
	want := []string{"Installiere: Windows-Subsystem für Linux", "Fertig 日本"}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Errorf("got %q, want %q", got, want)
	}
	// without a BOM
	if got := streamLines(t, text); strings.Join(got, "|") != strings.Join(want, "|") {
		t.Errorf("no BOM: %q", got)
	}
}

func TestLineWriterKeepsUTF8AndOEMLines(t *testing.T) {
	withOEM(t, func(b []byte) string { return strings.ReplaceAll(string(b), "\x82", "é") })
	got := streamLines(t, []byte("plain\nUTF-8 é 日本\r"), []byte("OEM caf\x82\n"), []byte("last"))
	want := []string{"plain", "UTF-8 é 日本", "OEM café", "last"}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Errorf("got %q, want %q", got, want)
	}
	if got := streamLines(t, []byte("x")); len(got) != 1 || got[0] != "x" {
		t.Errorf("one byte: %q", got)
	}
}
