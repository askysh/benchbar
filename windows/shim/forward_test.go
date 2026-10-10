package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"
)

const wantWrapper = `PATH="$HOME/.local/bin:$PATH"; command -v "$0" >/dev/null 2>&1 || exit 127; exec "$0" "$@"`

// fakeBlob is what the fake writes after echoing stdin.
var fakeBlob = []byte("bin\r\nline\nnul\x00end é 日本 \U0001F600 \xff\xfe\r\n")

var trickyArgs = []string{
	"plain", "with space", `dq"inside`, `'single'`, "it's", "$HOME", "`id`",
	`back\slash`, `trailing\`, `trail\\`, `quote\"end`, "", `%PATH%`,
	"é", "日本", "\U0001F600", "a;b|c&d>e", "--flag=val ue", "*", "~",
}

func TestForwardArgvShape(t *testing.T) {
	e := newEnv(t)
	if code := e.run("status", "--json"); code != 0 {
		t.Fatalf("exit %d, stderr %q", code, e.stderr())
	}
	st := e.starts()
	if len(st) != 1 {
		t.Fatalf("want one wsl.exe call, got %d", len(st))
	}
	want := []string{"/bin/sh", "-c", wantWrapper, "benchbar", "status", "--json"}
	if !reflect.DeepEqual(st[0].Exec, want) {
		t.Errorf("exec = %q\nwant   %q", st[0].Exec, want)
	}
	if st[0].Distro != "Ubuntu-24.04" || st[0].Cd != "~" {
		t.Errorf("distro %q cd %q", st[0].Distro, st[0].Cd)
	}
	if st[0].WSLUTF8 != "1" {
		t.Errorf("WSL_UTF8 = %q", st[0].WSLUTF8)
	}
	wantArgs := append([]string{"-d", "Ubuntu-24.04", "--cd", "~", "--exec"}, want...)
	if !reflect.DeepEqual(st[0].Args, wantArgs) {
		t.Errorf("args = %q\nwant   %q", st[0].Args, wantArgs)
	}
}

func TestForwardHelpAndVersionAreForwarded(t *testing.T) {
	for _, args := range [][]string{{"--version"}, {"help"}, {"mcp"}, {"up"}, {"down"}, {"status", "--json"}, {"doctor", "--json"}, {}} {
		e := newEnv(t)
		e.run(args...)
		st := e.starts()
		if len(st) != 1 {
			t.Fatalf("%v: %d wsl.exe calls", args, len(st))
		}
		got := st[0].Exec[4:]
		if len(got) != len(args) || (len(args) > 0 && !reflect.DeepEqual(got, args)) {
			t.Errorf("%v forwarded as %q", args, got)
		}
	}
}

func TestShimSubcommandsOnlyAsFirstArgument(t *testing.T) {
	e := newEnv(t)
	e.run("status", "wslconfig")
	e.run("path")
	e.run("path", "--bench-dir", "/x")
	if got := len(e.starts()); got != 3 {
		t.Errorf("want 3 forwards, got %d", got)
	}
}

func TestShimVersion(t *testing.T) {
	e := newEnv(t)
	if code := e.run("--shim-version"); code != 0 {
		t.Fatal(code)
	}
	if got, want := e.stdout(), "benchbar.exe "+version+"\n"; got != want {
		t.Errorf("got %q want %q", got, want)
	}
	if len(e.starts()) != 0 {
		t.Error("--shim-version must not call wsl.exe")
	}
}

func TestForwardCliPathFromConfig(t *testing.T) {
	e := newEnv(t)
	e.writeConfig(`{"cli_path": "/opt/bb/benchbar"}`)
	e.run("where")
	st := e.starts()
	if len(st) != 1 || st[0].Exec[3] != "/opt/bb/benchbar" {
		t.Errorf("starts = %+v", st)
	}
}

func TestForwardExitCodes(t *testing.T) {
	for _, n := range []int{0, 1, 2, 7, 130, 255} {
		t.Run(fmt.Sprint(n), func(t *testing.T) {
			e := newEnv(t)
			t.Setenv("FAKE_WSL_MODE", fmt.Sprintf("exit:%d", n))
			if code := e.run("up"); code != n {
				t.Errorf("exit %d, want %d", code, n)
			}
			if e.stderr() != "" {
				t.Errorf("stderr %q", e.stderr())
			}
		})
	}
}

func TestForwardOutOfRangeExitIsOne(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("exit codes above 255 exist only on Windows")
	}
	for _, mode := range []string{"exit:1000", "exit:-1"} {
		e := newEnv(t)
		t.Setenv("FAKE_WSL_MODE", mode)
		if code := e.run("up"); code != 1 {
			t.Errorf("%s: exit %d, want 1", mode, code)
		}
	}
}

func TestForwardExit127Message(t *testing.T) {
	e := newEnv(t)
	t.Setenv("FAKE_WSL_MODE", "exit:127")
	if code := e.run("up"); code != 1 {
		t.Errorf("exit %d, want 1", code)
	}
	want := `benchbar.exe: benchbar was not found in WSL distro "Ubuntu-24.04". fix: install it inside the distro: ` +
		`wsl.exe -d Ubuntu-24.04 -- bash -c "curl -fsSL https://raw.githubusercontent.com/askysh/benchbar/main/install.sh | bash"` + "\n"
	if e.stderr() != want {
		t.Errorf("stderr\n got %q\nwant %q", e.stderr(), want)
	}
	if strings.Contains(e.stderr(), "\u2014") {
		t.Error("em dash in message")
	}
}

func TestForwardWSLMissing(t *testing.T) {
	e := newEnv(t)
	e.WSLPath = func() (string, error) { return filepath.Join(e.root, "no-such-wsl.exe"), nil }
	if code := e.run("up"); code != 1 {
		t.Errorf("exit %d, want 1", code)
	}
	if !strings.Contains(e.stderr(), "benchbar.exe: cannot run wsl.exe") {
		t.Errorf("stderr %q", e.stderr())
	}
}

func TestConfiguredDistroNotRegistered(t *testing.T) {
	e := newEnv(t)
	e.writeConfig(`{"distro": "Debian"}`)
	if code := e.run("up"); code != 1 {
		t.Errorf("exit %d", code)
	}
	want := `benchbar.exe: WSL distro "Debian" is not installed. fix: benchbar.exe adopt-distro <NAME> (wsl.exe --list --verbose shows the names)` + "\n"
	if e.stderr() != want {
		t.Errorf("stderr %q", e.stderr())
	}
	if len(e.starts()) != 0 {
		t.Error("wsl.exe must not run")
	}
}

func TestNoDistroInstalled(t *testing.T) {
	e := newEnv(t)
	e.distros.list = nil
	if code := e.run("up"); code != 1 {
		t.Errorf("exit %d", code)
	}
	want := "benchbar.exe: no WSL distro is installed. fix: wsl.exe --install -d Ubuntu-24.04\n"
	if e.stderr() != want {
		t.Errorf("stderr %q", e.stderr())
	}
	if len(e.starts()) != 0 {
		t.Error("wsl.exe must not run")
	}
}

func TestDistroResolution(t *testing.T) {
	other := Distro{Name: "Debian", Version: 2}
	cases := []struct {
		name   string
		config string
		list   []Distro
		err    error
		want   string // distro passed to -d; "" means no -d
	}{
		{"default from registry", ``, []Distro{other, ubuntu}, nil, "Ubuntu-24.04"},
		{"config beats default", `{"distro":"Debian"}`, []Distro{other, ubuntu}, nil, "Debian"},
		{"case insensitive, registry spelling", `{"distro":"ubuntu-24.04"}`, []Distro{ubuntu}, nil, "Ubuntu-24.04"},
		{"no default flag, skip docker", ``, []Distro{{Name: "docker-desktop", Version: 2}, other}, nil, "Debian"},
		{"registry unreadable, config name kept", `{"distro":"Whatever"}`, nil, fmt.Errorf("denied"), "Whatever"},
		{"registry unreadable, no name", ``, nil, fmt.Errorf("denied"), ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			e := newEnv(t)
			e.distros.list, e.distros.err = c.list, c.err
			if c.config != "" {
				e.writeConfig(c.config)
			}
			if code := e.run("up"); code != 0 {
				t.Fatalf("exit %d, stderr %q", code, e.stderr())
			}
			st := e.starts()
			if len(st) != 1 {
				t.Fatalf("%d calls", len(st))
			}
			if st[0].Distro != c.want {
				t.Errorf("distro %q, want %q", st[0].Distro, c.want)
			}
			hasD := false
			for _, a := range st[0].Args {
				if a == "-d" {
					hasD = true
				}
			}
			if hasD != (c.want != "") {
				t.Errorf("-d present = %v, args %q", hasD, st[0].Args)
			}
		})
	}
}

func TestBadConfigStopsForward(t *testing.T) {
	e := newEnv(t)
	e.writeConfig(`[1,2]`)
	if code := e.run("up"); code != 1 {
		t.Errorf("exit %d", code)
	}
	if !strings.Contains(e.stderr(), "config.json is not a JSON object") {
		t.Errorf("stderr %q", e.stderr())
	}
}

// subprocess runs this test binary as the shim.
type shimRun struct {
	stdout []byte
	stderr string
	code   int
}

func registryEnv(distros ...Distro) string {
	b, _ := json.Marshal(registrySpec{Distros: distros})
	return "BENCHBAR_TEST_REGISTRY=" + string(b)
}

func shimCommand(t *testing.T, extra []string, args ...string) *exec.Cmd {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(exe, args...)
	cmd.Env = append(os.Environ(),
		"BENCHBAR_SHIM_TEST_MAIN=1",
		"BENCHBAR_TEST_WSL="+fakeWSL,
		"LOCALAPPDATA="+t.TempDir(),
		registryEnv(ubuntu))
	cmd.Env = append(cmd.Env, extra...)
	return cmd
}

func runShimProc(t *testing.T, extra []string, stdin []byte, args ...string) shimRun {
	t.Helper()
	cmd := shimCommand(t, extra, args...)
	var out, errb bytes.Buffer
	cmd.Stdin, cmd.Stdout, cmd.Stderr = bytes.NewReader(stdin), &out, &errb
	err := cmd.Run()
	code := 0
	if ee, ok := err.(*exec.ExitError); ok {
		code = ee.ExitCode()
	} else if err != nil {
		t.Fatal(err)
	}
	return shimRun{out.Bytes(), errb.String(), code}
}

func TestQuotingKeepsEveryArgument(t *testing.T) {
	record := filepath.Join(t.TempDir(), "rec.jsonl")
	r := runShimProc(t, []string{"FAKE_WSL_MODE=exit:0", "FAKE_WSL_RECORD=" + record}, nil, trickyArgs...)
	if r.code != 0 {
		t.Fatalf("exit %d stderr %q", r.code, r.stderr)
	}
	st := readEvents(t, record)
	if len(st) != 1 {
		t.Fatalf("%d calls", len(st))
	}
	want := append([]string{"/bin/sh", "-c", wantWrapper, "benchbar"}, trickyArgs...)
	if !reflect.DeepEqual(st[0].Exec, want) {
		for i := range want {
			if i >= len(st[0].Exec) || st[0].Exec[i] != want[i] {
				t.Errorf("arg %d: got %q want %q", i, st[0].Exec[min(i, len(st[0].Exec)-1)], want[i])
			}
		}
	}
}

// TestQuotingThroughShell runs the real /bin/sh wrapper under the fake and
// a stand-in benchbar, so $0 and "$@" handling is checked end to end.
func TestQuotingThroughShell(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("needs /bin/sh")
	}
	home := t.TempDir()
	bin := filepath.Join(home, ".local", "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	script := "#!/bin/sh\nprintf '%s\\0' \"$@\"\n"
	if err := os.WriteFile(filepath.Join(bin, "benchbar"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	r := runShimProc(t, []string{"FAKE_WSL_MODE=run", "HOME=" + home}, nil, trickyArgs...)
	if r.code != 0 {
		t.Fatalf("exit %d stderr %q", r.code, r.stderr)
	}
	got := strings.Split(string(r.stdout), "\x00")
	got = got[:len(got)-1]
	if !reflect.DeepEqual(got, trickyArgs) {
		t.Errorf("got  %q\nwant %q", got, trickyArgs)
	}
}

func TestShellWrapperExit127WhenCLIMissing(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("needs /bin/sh")
	}
	home := t.TempDir()
	r := runShimProc(t, []string{"FAKE_WSL_MODE=run", "HOME=" + home}, nil, "up")
	if r.code != 1 {
		t.Errorf("exit %d, want 1", r.code)
	}
	if !strings.Contains(r.stderr, `benchbar was not found in WSL distro "Ubuntu-24.04"`) {
		t.Errorf("stderr %q", r.stderr)
	}
}

func TestShellWrapperPassesCLIExitCode(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("needs /bin/sh")
	}
	home := t.TempDir()
	bin := filepath.Join(home, ".local", "bin")
	os.MkdirAll(bin, 0o755)
	os.WriteFile(filepath.Join(bin, "benchbar"), []byte("#!/bin/sh\nexit 2\n"), 0o755)
	r := runShimProc(t, []string{"FAKE_WSL_MODE=run", "HOME=" + home}, nil, "install", "--yes")
	if r.code != 2 {
		t.Errorf("exit %d, want 2", r.code)
	}
}

func TestStdinAndStdoutPassThroughByteExact(t *testing.T) {
	var in bytes.Buffer
	for i := 0; i < 1024; i++ {
		for b := 0; b < 256; b++ {
			in.WriteByte(byte(b))
		}
		in.WriteString("\r\n\n\r")
	}
	record := filepath.Join(t.TempDir(), "rec.jsonl")
	r := runShimProc(t, []string{
		"FAKE_WSL_MODE=echo-stdin", "FAKE_WSL_RECORD_STDIN=1", "FAKE_WSL_RECORD=" + record,
	}, in.Bytes(), "mcp")
	if r.code != 0 {
		t.Fatalf("exit %d stderr %q", r.code, r.stderr)
	}
	want := append(append([]byte{}, in.Bytes()...), fakeBlob...)
	if !bytes.Equal(r.stdout, want) {
		t.Errorf("stdout differs: got %d bytes, want %d", len(r.stdout), len(want))
	}
	for _, ev := range readEvents(t, record) {
		if ev.Event == "stdin" {
			got, _ := base64.StdEncoding.DecodeString(ev.Stdin)
			if !bytes.Equal(got, in.Bytes()) {
				t.Errorf("fake saw %d stdin bytes, want %d", len(got), in.Len())
			}
			return
		}
	}
	t.Error("no stdin event recorded")
}

func TestSubprocessExitCodes(t *testing.T) {
	for _, n := range []int{0, 1, 2, 7} {
		r := runShimProc(t, []string{fmt.Sprintf("FAKE_WSL_MODE=exit:%d", n)}, nil, "up")
		if r.code != n {
			t.Errorf("exit %d, want %d", r.code, n)
		}
	}
}

func TestConfigKeepsUnknownKeys(t *testing.T) {
	e := newEnv(t)
	e.writeConfig(`{"distro":"A","cli_path":"/x/benchbar","future":{"a":[1,2,{"b":null}]},"n":3}`)
	cfg, err := loadConfig(e.System)
	if err != nil {
		t.Fatal(err)
	}
	cfg.setStr("distro", "B")
	if err := cfg.save(); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(e.ConfigDir, "config.json"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.HasSuffix(data, []byte("}\n")) || !bytes.Contains(data, []byte("\n  \"distro\": \"B\"")) {
		t.Errorf("not 2-space JSON with a newline:\n%s", data)
	}
	m := e.readConfig()
	if string(m["cli_path"]) != `"/x/benchbar"` || string(m["n"]) != "3" {
		t.Errorf("known keys lost: %s", data)
	}
	var fut map[string][]any
	if err := json.Unmarshal(m["future"], &fut); err != nil || len(fut["a"]) != 3 {
		t.Errorf("unknown key changed: %s", m["future"])
	}
	left, _ := filepath.Glob(filepath.Join(e.ConfigDir, "*.tmp*"))
	if len(left) != 0 {
		t.Errorf("temp files left: %v", left)
	}
}

func TestConfigCreatesFolder(t *testing.T) {
	e := newEnv(t)
	cfg, err := loadConfig(e.System)
	if err != nil {
		t.Fatal(err)
	}
	cfg.setStr("distro", "Ubuntu-24.04")
	if err := cfg.save(); err != nil {
		t.Fatal(err)
	}
	if string(e.readConfig()["distro"]) != `"Ubuntu-24.04"` {
		t.Error("distro not written")
	}
}

func TestConfigWithBOM(t *testing.T) {
	e := newEnv(t)
	e.writeConfig("\xEF\xBB\xBF{\"distro\":\"Debian\"}")
	cfg, err := loadConfig(e.System)
	if err != nil || cfg.str("distro") != "Debian" {
		t.Errorf("cfg %v err %v", cfg, err)
	}
}

func TestExitCodeFunction(t *testing.T) {
	if exitCode(nil) != 0 {
		t.Error("nil")
	}
	if got := exitCode(fmt.Errorf("start failed")); got != 1 {
		t.Errorf("plain error: %d", got)
	}
}
