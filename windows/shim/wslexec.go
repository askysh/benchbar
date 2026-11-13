package main

import (
	"errors"
	"fmt"
	"time"
)

// Deadlines for the wsl.exe calls the shim makes for itself. A command the
// user forwards never gets one.
// wslQuickTimeout is for --status, --list and --version, which do not start
// a distro but can be slow while WSL starts its utility VM.
// wslTerminateTimeout is for --terminate, which waits for the distro to stop.
// wslProbeTimeout is for a call that may boot one. They are variables so a
// test can shorten them.
var (
	wslQuickTimeout     = 60 * time.Second
	wslTerminateTimeout = 60 * time.Second
	wslProbeTimeout     = 90 * time.Second
)

// wslWaitDelay bounds the wait for output pipes after wsl.exe ended or was
// killed, so a pipe that something else holds cannot block Wait.
const wslWaitDelay = 3 * time.Second

// wslTimeoutError says that wsl.exe did not answer in time.
type wslTimeoutError struct{ d time.Duration }

func (e *wslTimeoutError) Error() string {
	return fmt.Sprintf("wsl.exe did not answer in %d s: wait a minute and run benchbar.exe setup check again; if it still does not answer, run wsl.exe --shutdown as the last resort (this stops every WSL distro and everything running in them)", int(e.d.Seconds()))
}

func isWslTimeout(err error) bool {
	var te *wslTimeoutError
	return errors.As(err, &te)
}

// wslTimeoutFor is the deadline of one wsl.exe call: the management
// commands answer without starting a distro, everything else may boot one.
func wslTimeoutFor(args []string) time.Duration {
	if len(args) > 0 {
		switch args[0] {
		case "--status", "--version", "--list":
			return wslQuickTimeout
		case "--terminate":
			return wslTerminateTimeout
		}
	}
	return wslProbeTimeout
}

// wslFailureAdvice names what a known wsl.exe or Windows error code means
// and what to do. It is empty for a code it does not know.
func wslFailureAdvice(code uint32) string {
	switch code {
	case 0x80370102:
		return "virtualization is off: turn on Intel VT-x or AMD SVM (AMD-V) in the BIOS or UEFI settings, then try again"
	case 0x80072ee7, 0x80072efd, 0x80072ee2:
		return "Windows could not reach the network: check the connection, the VPN and the proxy, then try again"
	case 0x80070005, 0x80070422:
		return "a policy or a stopped Windows service blocks it: ask the PC's administrator, or start the service named in the message"
	}
	return ""
}

// hexCode formats an exit code the way Windows documents it.
func hexCode(code int) string { return fmt.Sprintf("0x%08X", uint32(code)) }

// wslInstallAdvice is the advice after a failed elevated wsl.exe install:
// the known meaning of the code, or the way to see the message.
func wslInstallAdvice(code int) string {
	if a := wslFailureAdvice(uint32(code)); a != "" {
		return a
	}
	return "run wsl --install --no-distribution in a terminal opened as administrator to see the message"
}

// wslFailureLine is the one line printed when wsl.exe itself failed, so the
// exit code is not read as the CLI's.
func wslFailureLine(raw int) string {
	return fmt.Sprintf("wsl.exe itself failed (%s): run benchbar.exe setup check", hexCode(raw))
}
