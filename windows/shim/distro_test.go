package main

import (
	"strings"
	"testing"
)

func withVersion(t *testing.T, v string) {
	t.Helper()
	old := version
	version = v
	t.Cleanup(func() { version = old })
}

func TestInstallerPinnedToRelease(t *testing.T) {
	withVersion(t, "0.8.1")
	if got, want := installerURL(), "https://raw.githubusercontent.com/askysh/benchbar/v0.8.1/install.sh"; got != want {
		t.Errorf("url %q, want %q", got, want)
	}
	want := `wsl.exe -d Ubuntu-24.04 -- bash -c "curl -fsSL https://raw.githubusercontent.com/askysh/benchbar/v0.8.1/install.sh | bash -s -- --version v0.8.1"`
	if got := installerCommand("Ubuntu-24.04"); got != want {
		t.Errorf("command\n got %q\nwant %q", got, want)
	}
}

func TestInstallerMainForDevBuilds(t *testing.T) {
	for _, v := range []string{"dev", "0123456789ab", "0.0.0-pr12", "0.8.1-beta", ""} {
		withVersion(t, v)
		if got, want := installerURL(), "https://raw.githubusercontent.com/askysh/benchbar/main/install.sh"; got != want {
			t.Errorf("%q: url %q, want %q", v, got, want)
		}
		if strings.Contains(installerPipe(), "--version") {
			t.Errorf("%q: a dev build must not pin a version: %s", v, installerPipe())
		}
	}
}
