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
	want := `wsl.exe -d Ubuntu-24.04 -- bash -c "set -o pipefail; mkdir -p ~/.cache/benchbar-install && cd ~/.cache/benchbar-install && curl --proto '=https' --tlsv1.2 -fsSL -o install.sh https://raw.githubusercontent.com/askysh/benchbar/v0.8.1/install.sh && { curl --proto '=https' --tlsv1.2 -fsSL https://github.com/askysh/benchbar/releases/download/v0.8.1/SHA256SUMS | grep -x '.\{64\}  install.sh' | sha256sum -c - || { echo 'install.sh was not run: it does not match the SHA256SUMS of v0.8.1, or those could not be read' >&2; exit 1; }; } && bash install.sh --version v0.8.1"`
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

// A release build never runs an installer its release does not list, and the
// line holds nothing that cmd or PowerShell would expand inside bash -c "...".
func TestInstallerPipeOfARelease(t *testing.T) {
	withVersion(t, "0.9.1")
	line := installerPipe()
	if strings.ContainsAny(line, "\"$`") {
		t.Errorf("a double quote, dollar sign or backtick in the line: %s", line)
	}
	for _, want := range []string{
		"-o install.sh https://raw.githubusercontent.com/askysh/benchbar/v0.9.1/install.sh",
		"https://github.com/askysh/benchbar/releases/download/v0.9.1/SHA256SUMS | grep -x",
		"sha256sum -c -",
		"&& bash install.sh --version v0.9.1",
	} {
		if !strings.Contains(line, want) {
			t.Errorf("the line lacks %q:\n%s", want, line)
		}
	}
	if strings.Contains(line, "| bash") {
		t.Errorf("an installer is piped into bash unchecked: %s", line)
	}
}
