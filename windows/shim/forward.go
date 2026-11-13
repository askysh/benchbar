package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"strings"
)

// wrapper puts ~/.local/bin on PATH (the installer puts the CLI there; a
// non-login shell may not) and runs the CLI named by $0 with the rest.
const wrapper = `PATH="$HOME/.local/bin:$PATH"; command -v "$0" >/dev/null 2>&1 || exit 127; exec "$0" "$@"`

func cmdForward(sys *System, args []string) int {
	t, err := resolveTarget(sys, "")
	if err != nil {
		errorf(sys, "%v", err)
		return 1
	}
	if t.prob != nil {
		t.prob.print(sys)
		return 1
	}
	return forward(sys, t, args)
}

func forwardArgs(distro, cli string, args []string) []string {
	var a []string
	if distro != "" {
		a = append(a, "-d", distro)
	}
	a = append(a, "--cd", "~", "--exec", "/bin/sh", "-c", wrapper, cli)
	return append(a, args...)
}

func wslCommand(sys *System, args ...string) (*exec.Cmd, error) {
	cmd, err := wslCommandContext(context.Background(), sys, args...)
	if err != nil {
		return nil, err
	}
	// no deadline binds this call (a streamed long action or the user's own
	// command), so a wait delay must not cut its output
	cmd.WaitDelay = 0
	return cmd, nil
}

// wslCommandContext is wslCommand that ends the process when ctx ends. Only
// the shim's own calls use a context: a command the user forwards never has
// a deadline. Only these deadline bound calls get a WaitDelay.
func wslCommandContext(ctx context.Context, sys *System, args ...string) (*exec.Cmd, error) {
	path, err := sys.WSLPath()
	if err != nil {
		return nil, err
	}
	cmd := exec.CommandContext(ctx, path, args...)
	cmd.Env = append(sys.Environ(), "WSL_UTF8=1")
	// a pipe that something else holds open must not block Wait for good
	cmd.WaitDelay = wslWaitDelay
	return cmd, nil
}

// forwardedEnv are the only variables the forwarder hands to the CLI in the
// distro. The BenchBar tray sets them in the child's environment for one
// run, so a password never sits on a command line.
var forwardedEnv = []string{
	"ADMIN_PASSWORD",
	"MARIADB_ROOT_PASSWORD",
	"BENCHBAR_SUDO",
	"BENCHBAR_SUDO_PASSWORD",
	"BENCHBAR_NONINTERACTIVE",
}

// proxyEnv are the proxy settings of the Windows side. Linux tools (curl,
// git, apt) read the lower case spelling, so both are passed on, and the
// names are compared with their case here, since Windows treats the two
// spellings as one variable.
var proxyEnv = []string{
	"HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY",
	"http_proxy", "https_proxy", "no_proxy",
}

// withForwardedEnv returns env with WSLENV extended by the forwarded names
// that are set. It changes the child's copy only, never the user's own
// WSLENV. Values are never read here; WSL copies them across.
func withForwardedEnv(sys *System, env []string) []string {
	return withEnvNames(sys, env, forwardedEnv, proxyEnv)
}

// withEnvNames is withForwardedEnv for chosen lists: nameList is compared
// without case, exactList with it.
func withEnvNames(sys *System, env []string, nameList, exactList []string) []string {
	var names []string
	for _, n := range nameList {
		if sys.Getenv(n) != "" {
			names = append(names, n)
		}
	}
	for _, n := range exactList {
		if sys.Getenv(n) != "" {
			names = append(names, n)
		}
	}
	if len(names) == 0 {
		return env
	}
	current := ""
	out := make([]string, 0, len(env)+1)
	for _, kv := range env {
		if k, v, ok := strings.Cut(kv, "="); ok && strings.EqualFold(k, "WSLENV") {
			current = v
			continue
		}
		out = append(out, kv)
	}
	have := map[string]bool{}
	haveExact := map[string]bool{}
	var parts []string
	for _, p := range strings.Split(current, ":") {
		if p == "" {
			continue
		}
		parts = append(parts, p)
		base, _, _ := strings.Cut(p, "/")
		have[strings.ToUpper(base)] = true
		haveExact[base] = true
	}
	for _, n := range names {
		if isExactName(n, exactList) {
			if !haveExact[n] {
				parts = append(parts, n)
			}
		} else if !have[n] {
			parts = append(parts, n)
		}
	}
	return append(out, "WSLENV="+strings.Join(parts, ":"))
}

func isExactName(n string, list []string) bool {
	for _, x := range list {
		if x == n {
			return true
		}
	}
	return false
}

// forward runs the CLI in the distro with the shim's own standard handles.
func forward(sys *System, t target, args []string) int {
	cmd, err := wslCommand(sys, forwardArgs(t.distro, t.cli, linuxPathArgs(args, t.distro))...)
	if err != nil {
		errorf(sys, "wsl.exe was not found: %v", err)
		return 1
	}
	cmd.Stdin, cmd.Stdout, cmd.Stderr = sys.Stdin, sys.Stdout, sys.Stderr
	cmd.Env = withForwardedEnv(sys, cmd.Env)
	code, raw, err := runInterruptible(cmd)
	if err != nil {
		errorf(sys, "cannot run wsl.exe: %v", err)
		return 1
	}
	if raw != nil {
		errorf(sys, "%s", wslFailureLine(*raw))
	}
	if code == 127 && !cliExists(sys, t) {
		where := "the default WSL distro"
		if t.distro != "" {
			where = fmt.Sprintf("WSL distro %q", t.distro)
		}
		fix := missingCLIFix(t)
		if t.cli == "benchbar" {
			fix = "install it inside the distro: " + fix
		}
		(&problem{
			Msg: fmt.Sprintf("%s was not found in %s", t.cli, where),
			Fix: fix,
		}).print(sys)
		return 1
	}
	return code
}

// cliExists asks the distro again, so that a 127 from the CLI itself (a
// command it could not run) is not reported as a missing install.
func cliExists(sys *System, t target) bool {
	var a []string
	if t.distro != "" {
		a = append(a, "-d", t.distro)
	}
	a = append(a, "--exec", "/bin/sh", "-c", `PATH="$HOME/.local/bin:$PATH"; command -v "$0"`, t.cli)
	ctx, cancel := context.WithTimeout(sys.Ctx, wslQuickTimeout)
	defer cancel()
	cmd, err := wslCommandContext(ctx, sys, a...)
	if err != nil {
		return false
	}
	return cmd.Run() == nil
}

// runInterruptible starts cmd, waits for it and never returns before it
// exits. Ctrl+C is not the shim's to act on: on Windows the console already
// delivers it to wsl.exe; elsewhere it is passed on.
//
// raw is set when the exit code is outside 0..255: wsl.exe itself failed,
// not the CLI. The code returned is then 1.
func runInterruptible(cmd *exec.Cmd) (code int, raw *int, err error) {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, os.Interrupt)
	defer signal.Stop(ch)
	if err := cmd.Start(); err != nil {
		return 1, nil, err
	}
	defer attachKillOnClose(cmd.Process.Pid)()
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	for {
		select {
		case <-ch:
			relayInterrupt(cmd.Process)
		case err := <-done:
			return exitCode(err), outOfRange(err), nil
		}
	}
}

// outOfRange is the exit code of a process that ended with one outside
// 0..255 (a failure of wsl.exe itself, such as 0x80370102), or nil.
func outOfRange(err error) *int {
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		if c := ee.ExitCode(); (c < 0 || c > 255) && !isControlCExit(c) {
			return &c
		}
	}
	return nil
}

// statusControlCExit is STATUS_CONTROL_C_EXIT, the code of a process the
// console ended with Ctrl+C.
const statusControlCExit = 0xC000013A

func isControlCExit(c int) bool { return uint32(c) == statusControlCExit }

// exitCode keeps 0..255, turns an end by Ctrl+C into 130 and anything else
// (wsl.exe failures such as 0xFFFFFFFF) into 1.
func exitCode(err error) int {
	if err == nil {
		return 0
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		if c := ee.ExitCode(); c >= 0 && c <= 255 {
			return c
		} else if isControlCExit(c) {
			return 130
		}
	}
	return 1
}
