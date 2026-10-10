//go:build wslintegration && windows

package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// These tests run the real benchbar.exe against a real WSL distro:
//
//	set BENCHBAR_TEST_DISTRO=Ubuntu-24.04
//	go test -tags wslintegration -run Integration ./...

type integration struct {
	t      *testing.T
	exe    string
	distro string
	local  string
}

func newIntegration(t *testing.T, cliPath string) *integration {
	t.Helper()
	distro := os.Getenv("BENCHBAR_TEST_DISTRO")
	if distro == "" {
		t.Skip("BENCHBAR_TEST_DISTRO is not set")
	}
	exe := filepath.Join(t.TempDir(), "benchbar.exe")
	if out, err := exec.Command("go", "build", "-o", exe, ".").CombinedOutput(); err != nil {
		t.Fatalf("build: %v\n%s", err, out)
	}
	in := &integration{t: t, exe: exe, distro: distro, local: t.TempDir()}
	cfg := map[string]string{"distro": distro}
	if cliPath != "" {
		cfg["cli_path"] = cliPath
	}
	data, _ := json.Marshal(cfg)
	dir := filepath.Join(in.local, "BenchBar")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "config.json"), data, 0o644); err != nil {
		t.Fatal(err)
	}
	return in
}

func (in *integration) cmd(args ...string) *exec.Cmd {
	cmd := exec.Command(in.exe, args...)
	cmd.Env = append(os.Environ(), "LOCALAPPDATA="+in.local)
	return cmd
}

func (in *integration) run(stdin string, args ...string) (stdout, stderr string, code int) {
	in.t.Helper()
	cmd := in.cmd(args...)
	var out, errb bytes.Buffer
	cmd.Stdin, cmd.Stdout, cmd.Stderr = strings.NewReader(stdin), &out, &errb
	err := cmd.Run()
	if ee, ok := err.(*exec.ExitError); ok {
		code = ee.ExitCode()
	} else if err != nil {
		in.t.Fatal(err)
	}
	return out.String(), errb.String(), code
}

func TestIntegrationStatusJSON(t *testing.T) {
	in := newIntegration(t, "")
	out, errs, code := in.run("", "status", "--json")
	t.Logf("exit %d", code)
	var v map[string]any
	if err := json.Unmarshal([]byte(out), &v); err != nil {
		t.Fatalf("not JSON: %v\nstdout: %s\nstderr: %s", err, out, errs)
	}
	if _, ok := v["schema_version"]; !ok {
		t.Errorf("no schema_version in %s", out)
	}
}

func TestIntegrationUnknownCommandExitsOne(t *testing.T) {
	in := newIntegration(t, "")
	_, _, code := in.run("", "definitely-not-a-command")
	if code != 1 {
		t.Errorf("exit %d, want 1", code)
	}
}

func TestIntegrationExitCodesThroughTheRealHop(t *testing.T) {
	in := newIntegration(t, "/bin/sh")
	for _, n := range []int{0, 1, 2} {
		_, errs, code := in.run("", "-c", fmt.Sprintf("exit %d", n))
		if code != n {
			t.Errorf("exit %d, want %d (stderr %q)", code, n, errs)
		}
	}
}

func TestIntegrationQuotingThroughTheRealWSL(t *testing.T) {
	in := newIntegration(t, "/usr/bin/printf")
	out, errs, code := in.run("", append([]string{`%s\n`}, trickyArgs...)...)
	if code != 0 {
		t.Fatalf("exit %d, stderr %q", code, errs)
	}
	got := strings.Split(strings.TrimSuffix(out, "\n"), "\n")
	if len(got) != len(trickyArgs) {
		t.Fatalf("got %d lines, want %d:\n%q", len(got), len(trickyArgs), out)
	}
	for i, want := range trickyArgs {
		if got[i] != want {
			t.Errorf("arg %d: got %q want %q", i, got[i], want)
		}
	}
}

func TestIntegrationMCP(t *testing.T) {
	in := newIntegration(t, "")
	cmd := in.cmd("mcp")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	var errb bytes.Buffer
	cmd.Stderr = &errb
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer cmd.Process.Kill()

	lines := make(chan string, 8)
	go func() {
		r := bufio.NewReader(stdout)
		for {
			line, err := r.ReadString('\n')
			if line != "" {
				lines <- line
			}
			if err != nil {
				close(lines)
				return
			}
		}
	}()
	read := func() map[string]any {
		t.Helper()
		select {
		case line, ok := <-lines:
			if !ok {
				t.Fatalf("mcp closed early, stderr %q", errb.String())
			}
			var v map[string]any
			if err := json.Unmarshal([]byte(line), &v); err != nil {
				t.Fatalf("not JSON: %q", line)
			}
			return v
		case <-time.After(90 * time.Second):
			t.Fatalf("no response, stderr %q", errb.String())
		}
		return nil
	}
	send := func(s string) {
		if _, err := io.WriteString(stdin, s+"\n"); err != nil {
			t.Fatal(err)
		}
	}

	send(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"shim-test","version":"0"}}}`)
	init := read()
	info, _ := init["result"].(map[string]any)["serverInfo"].(map[string]any)
	if info["name"] != "benchbar" {
		t.Errorf("serverInfo %v", info)
	}
	send(`{"jsonrpc":"2.0","method":"notifications/initialized"}`)
	send(`{"jsonrpc":"2.0","id":2,"method":"tools/list"}`)
	list := read()
	tools, _ := list["result"].(map[string]any)["tools"].([]any)
	found := false
	for _, x := range tools {
		if m, ok := x.(map[string]any); ok && m["name"] == "benchbar_status" {
			found = true
		}
	}
	if !found {
		t.Errorf("benchbar_status not in tools/list: %v", list)
	}
	stdin.Close()
	done := make(chan struct{})
	go func() { cmd.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(30 * time.Second):
		t.Error("mcp did not exit after stdin closed")
	}
}

func wslconfigDigest() string {
	data, err := os.ReadFile(filepath.Join(os.Getenv("USERPROFILE"), ".wslconfig"))
	if err != nil {
		return "absent"
	}
	return fmt.Sprintf("%x", sha256.Sum256(data))
}

func TestIntegrationWslconfigIsReadOnly(t *testing.T) {
	in := newIntegration(t, "")
	before := wslconfigDigest()
	defer func() {
		if after := wslconfigDigest(); after != before {
			t.Errorf(".wslconfig changed: %s -> %s", before, after)
		}
	}()
	for _, args := range [][]string{{"wslconfig"}, {"wslconfig", "--json"}} {
		out, errs, code := in.run("", args...)
		if code != 0 {
			t.Errorf("%v: exit %d, stderr %q", args, code, errs)
		}
		if args[len(args)-1] == "--json" {
			var v map[string]any
			if err := json.Unmarshal([]byte(out), &v); err != nil {
				t.Errorf("not JSON: %v\n%s", err, out)
			}
		}
	}
}
