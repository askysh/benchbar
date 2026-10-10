package main

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestQuoteArg(t *testing.T) {
	plain := []string{"Ubuntu-24.04", "Debian", "my_distro.1", "Débian"}
	for _, s := range plain {
		if got := quoteArg(s); got != s {
			t.Errorf("quoteArg(%q) = %q, want it unquoted", s, got)
		}
	}
	for _, s := range []string{"My Distro", "a&b", "a;b", "it's", "a(b)", "a$b", "a`b", "100%", "", "a|b", "a>b"} {
		if got := quoteArg(s); !strings.HasPrefix(got, `"`) || !strings.HasSuffix(got, `"`) {
			t.Errorf("quoteArg(%q) = %q, want double quotes", s, got)
		}
	}
	if got := quoteArg(`a"b`); got != `"a\"b"` {
		t.Errorf("embedded quote: %q", got)
	}
}

func TestFixCommandsQuoteDistroNames(t *testing.T) {
	mine := Distro{Name: "My Distro", Version: 1, Default: true}

	e := newEnv(t)
	e.distros.list = []Distro{mine}
	e.useProbe(probeText("", "init", "akash", "", "no"))
	e.run("adopt-distro")
	out := e.stdout()
	for _, want := range []string{
		`fix: wsl.exe --set-version "My Distro" 2`,
		`sudo sh -c "printf '`,
		`>> /etc/wsl.conf"; wsl.exe --terminate "My Distro"`,
		`wsl.exe -d "My Distro" -- sudo sh -c`,
		`wsl.exe -d "My Distro" -- bash -c "curl`,
		`wsl.exe -d "My Distro" -- loginctl enable-linger akash`,
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
	if strings.Contains(out, "-d My Distro") || strings.Contains(out, "terminate My Distro") {
		t.Errorf("unquoted name in:\n%s", out)
	}

	e2 := newEnv(t)
	e2.distros.list = []Distro{{Name: "My Distro", Version: 2, Default: true}}
	e2.useProbe(probeText("[boot]\nx=1\n", "init", "u", "/b", "yes"))
	e2.run("adopt-distro")
	if !strings.Contains(e2.stdout(), `(wsl.exe -d "My Distro" -- sudo nano /etc/wsl.conf), then wsl.exe --terminate "My Distro"`) {
		t.Errorf("output:\n%s", e2.stdout())
	}

	e3 := newEnv(t)
	e3.distros.list = []Distro{mine}
	e3.run("doctor")
	if !strings.Contains(e3.stdout(), `fix: wsl.exe --set-version "My Distro" 2`) {
		t.Errorf("doctor output:\n%s", e3.stdout())
	}

	e4 := newEnv(t)
	e4.distros.list = []Distro{{Name: "My Distro", Version: 2, Default: true}}
	t.Setenv("FAKE_WSL_MODE", "exit:127")
	e4.run("up")
	if !strings.Contains(e4.stderr(), `fix: install it inside the distro: wsl.exe -d "My Distro" -- bash -c`) {
		t.Errorf("stderr %q", e4.stderr())
	}
}

func TestMissingCustomCLIPathIsNotAnInstallProblem(t *testing.T) {
	e := newEnv(t)
	e.writeConfig(`{"cli_path":"/opt/x/benchbar"}`)
	cfg := filepath.Join(e.ConfigDir, "config.json")
	want := `fix: correct or remove "cli_path" (/opt/x/benchbar) in ` + cfg

	e.useProbe(probeText(goodConf, "systemd", "akash", "", "yes"))
	e.run("adopt-distro")
	if !strings.Contains(e.stdout(), want) || strings.Contains(e.stdout(), "curl") {
		t.Errorf("adopt output:\n%s", e.stdout())
	}

	t.Setenv("FAKE_WSL_MODE", "exit:127")
	e.err.Reset()
	if code := e.run("up"); code != 1 {
		t.Errorf("exit %d", code)
	}
	if !strings.Contains(e.stderr(), "/opt/x/benchbar was not found") || !strings.Contains(e.stderr(), want) || strings.Contains(e.stderr(), "curl") {
		t.Errorf("stderr %q", e.stderr())
	}
}

func TestMissingDefaultCLIGetsTheInstaller(t *testing.T) {
	for _, cfg := range []string{``, `{"cli_path":"benchbar"}`} {
		e := newEnv(t)
		if cfg != "" {
			e.writeConfig(cfg)
		}
		e.useProbe(probeText(goodConf, "systemd", "akash", "", "yes"))
		e.run("adopt-distro")
		if !strings.Contains(e.stdout(), "fix: wsl.exe -d Ubuntu-24.04 -- bash -c \"curl") || strings.Contains(e.stdout(), "cli_path") {
			t.Errorf("config %q, adopt output:\n%s", cfg, e.stdout())
		}
		t.Setenv("FAKE_WSL_MODE", "exit:127")
		e.run("up")
		if !strings.Contains(e.stderr(), "fix: install it inside the distro: wsl.exe -d Ubuntu-24.04") {
			t.Errorf("config %q, stderr %q", cfg, e.stderr())
		}
	}
}

func TestKeepaliveForAnotherDistroWarns(t *testing.T) {
	args := `--headless "` + testExe + `" keepalive run --distro "Debian"`
	want := "keepalive keeps Debian alive, but BenchBar uses Ubuntu-24.04"

	e := newEnv(t)
	e.healthyWindows()
	e.taskHandler(taskXMLOutput(args), statusCSV)
	e.FileExists = func(p string) bool { return p == testExe }
	e.run("doctor")
	if !strings.Contains(e.stdout(), "[WARN] Keepalive: "+want) || !strings.Contains(e.stdout(), "fix: benchbar.exe keepalive install") {
		t.Errorf("doctor output:\n%s", e.stdout())
	}

	e2 := newEnv(t)
	e2.taskHandler(taskXMLOutput(args), statusCSV)
	e2.FileExists = func(p string) bool { return p == testExe }
	e2.run("keepalive", "status")
	if !strings.Contains(e2.stdout(), "[WARN] Keepalive: "+want) {
		t.Errorf("status output:\n%s", e2.stdout())
	}

	// same distro, other spelling: no warning
	e3 := newEnv(t)
	e3.taskHandler(taskXMLOutput(strings.Replace(args, "Debian", "ubuntu-24.04", 1)), statusCSV)
	e3.FileExists = func(p string) bool { return p == testExe }
	e3.run("keepalive", "status")
	if strings.Contains(e3.stdout(), "BenchBar uses") {
		t.Errorf("warned for the same distro:\n%s", e3.stdout())
	}
}
