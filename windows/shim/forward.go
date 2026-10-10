package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
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
	path, err := sys.WSLPath()
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(path, args...)
	cmd.Env = append(sys.Environ(), "WSL_UTF8=1")
	return cmd, nil
}

// forward runs the CLI in the distro with the shim's own standard handles.
func forward(sys *System, t target, args []string) int {
	cmd, err := wslCommand(sys, forwardArgs(t.distro, t.cli, args)...)
	if err != nil {
		errorf(sys, "wsl.exe was not found: %v", err)
		return 1
	}
	cmd.Stdin, cmd.Stdout, cmd.Stderr = sys.Stdin, sys.Stdout, sys.Stderr
	code, err := runInterruptible(cmd)
	if err != nil {
		errorf(sys, "cannot run wsl.exe: %v", err)
		return 1
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
	cmd, err := wslCommand(sys, a...)
	if err != nil {
		return false
	}
	return cmd.Run() == nil
}

// runInterruptible starts cmd, waits for it and never returns before it
// exits. Ctrl+C is not the shim's to act on: on Windows the console already
// delivers it to wsl.exe; elsewhere it is passed on.
func runInterruptible(cmd *exec.Cmd) (int, error) {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, os.Interrupt)
	defer signal.Stop(ch)
	if err := cmd.Start(); err != nil {
		return 1, err
	}
	defer attachKillOnClose(cmd.Process.Pid)()
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	for {
		select {
		case <-ch:
			relayInterrupt(cmd.Process)
		case err := <-done:
			return exitCode(err), nil
		}
	}
}

// exitCode keeps 0..255 and turns anything else (wsl.exe failures such as
// 0xFFFFFFFF) into 1.
func exitCode(err error) int {
	if err == nil {
		return 0
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		if c := ee.ExitCode(); c >= 0 && c <= 255 {
			return c
		}
	}
	return 1
}
