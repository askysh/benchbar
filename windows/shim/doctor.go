package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
)

func distroCheck(t target) Check {
	c := Check{ID: "distro", Label: "WSL distro"}
	switch {
	case t.prob != nil:
		c.Status, c.Message, c.Fix = "fail", t.prob.Msg, t.prob.Fix
	case t.info == nil:
		c.Status = "warn"
		c.Message = "cannot read the WSL registry, so the distro is not checked"
		c.Fix = listDistros
	case t.info.Version != 2:
		c.Status = "fail"
		c.Message = fmt.Sprintf("%s runs as WSL %d, benches need WSL 2", t.distro, t.info.Version)
		c.Fix = fmt.Sprintf("wsl.exe --set-version %s 2", quoteArg(t.distro))
	default:
		c.Status = "ok"
		c.Message = t.distro + " is registered and runs WSL 2"
	}
	return c
}

// windowsChecks are the checks of the Windows side: PATH, the distro,
// .wslconfig, the keepalive, the tray and the CLI version.
func windowsChecks(sys *System, t target) []Check {
	checks := []Check{pathCheck(sys), distroCheck(t)}
	if f, rep, err := readWslconfig(sys); err != nil {
		checks = append(checks, Check{ID: "wslconfig", Label: ".wslconfig", Status: "warn", Message: err.Error(), Fix: `type "%USERPROFILE%\.wslconfig"`})
	} else {
		checks = append(checks, idleCheck(rep))
		checks = append(checks, networkChecks(f)...)
	}
	ka := queryKeepalive(sys)
	if t.prob == nil {
		checkKeepaliveTarget(&ka, t.distro)
		if c, ok := cliVersionCheck(sys, t); ok {
			checks = append(checks, c)
		}
	}
	checks = append(checks, ka.Checks...)
	checks = append(checks, trayChecks(sys)...)
	checks = append(checks, installRecordChecks(sys, ka)...)
	return checks
}

// cmdDoctor prints the Windows checks, then the CLI's own doctor.
func cmdDoctor(sys *System, rest []string) int {
	t, err := resolveTarget(sys, "")
	if err != nil {
		errorf(sys, "%v", err)
		return 1
	}
	checks := windowsChecks(sys, t)

	fmt.Fprint(sys.Stdout, "\nWINDOWS\n")
	printChecks(sys.Stdout, checks)
	fmt.Fprintln(sys.Stdout)

	if t.prob != nil {
		t.prob.print(sys)
		return 1
	}
	code := forward(sys, t, append([]string{"doctor"}, rest...))
	if code == 0 && hasFail(checks) {
		return 1
	}
	return code
}

// machineFlags ask the CLI for output that a program reads: stdout must then
// hold that output and nothing else.
var machineFlags = []string{"--json", "--jsonl", "--for-agent", "--fix-hints"}

// windowsCheckJSON is one Windows check in the document, with the field names
// of the CLI's own checks (level and fix_command are the contract, status
// and fix the older names).
type windowsCheckJSON struct {
	ID         string `json:"id"`
	Label      string `json:"label"`
	Level      string `json:"level"`
	Message    string `json:"message"`
	FixCommand string `json:"fix_command"`
	Status     string `json:"status"`
	Fix        string `json:"fix"`
}

func windowsChecksJSON(checks []Check) []windowsCheckJSON {
	out := make([]windowsCheckJSON, 0, len(checks))
	for _, c := range checks {
		out = append(out, windowsCheckJSON{c.ID, c.Label, c.Status, c.Message, c.Fix, c.Status, c.Fix})
	}
	return out
}

// cmdDoctorMachine is doctor with --json, --jsonl, --for-agent or
// --fix-hints. Stdout holds the CLI's output and nothing else, with the
// Windows checks inside it: a "windows_checks" array at the end of the
// document, or the fix commands of the Windows checks after the CLI's own.
// --ack, --unack and --prerequisites have documents of their own and pass
// through untouched. The exit code is the CLI's, and 1 when a Windows check
// fails and the CLI's doctor passed.
func cmdDoctorMachine(sys *System, args []string) int {
	if hasAny(args, "--ack", "--unack", "--prerequisites") {
		return cmdForward(sys, append([]string{"doctor"}, args...))
	}
	t, err := resolveTarget(sys, "")
	if err != nil {
		errorf(sys, "%v", err)
		return 1
	}
	if t.prob != nil {
		t.prob.print(sys)
		return 1
	}
	checks := windowsChecks(sys, t)
	var out bytes.Buffer
	cs := *sys
	cs.Stdout = &out
	code := forward(&cs, t, append([]string{"doctor"}, args...))
	if hasAny(args, "--fix-hints") {
		sys.Stdout.Write(withWindowsFixHints(out.Bytes(), checks))
	} else {
		sys.Stdout.Write(withWindowsChecks(out.Bytes(), checks))
	}
	if code == 0 && hasFail(checks) {
		return 1
	}
	return code
}

// withWindowsChecks adds the "windows_checks" array to the CLI's document.
// Anything that is not one JSON object (an error, an empty output) is
// returned as it is.
func withWindowsChecks(doc []byte, checks []Check) []byte {
	trimmed := bytes.TrimSpace(doc)
	if len(trimmed) < 2 || trimmed[0] != '{' || trimmed[len(trimmed)-1] != '}' || !json.Valid(trimmed) {
		return doc
	}
	arr, _ := json.Marshal(windowsChecksJSON(checks))
	body := bytes.TrimSpace(trimmed[1 : len(trimmed)-1])
	sep := ","
	if len(body) == 0 {
		sep = ""
	}
	out := append([]byte{}, trimmed[:len(trimmed)-1]...)
	out = append(out, sep+`"windows_checks":`...)
	out = append(out, arr...)
	return append(out, '}', '\n')
}

// withWindowsFixHints appends the fix command of every failing and warning
// Windows check, failures first, each once, to the CLI's lines.
func withWindowsFixHints(cli []byte, checks []Check) []byte {
	out := append([]byte{}, cli...)
	if len(out) > 0 && out[len(out)-1] != '\n' {
		out = append(out, '\n')
	}
	seen := map[string]bool{}
	for _, l := range strings.Split(string(cli), "\n") {
		seen[strings.TrimSpace(l)] = true
	}
	for _, want := range []string{"fail", "warn"} {
		for _, c := range checks {
			if c.Status == want && c.Fix != "" && !seen[c.Fix] {
				seen[c.Fix] = true
				out = append(out, c.Fix+"\n"...)
			}
		}
	}
	return out
}

// cliVersionCheck compares the CLI in the distro with this benchbar.exe. A
// dev build of the shim, a custom cli_path and a CLI that does not answer
// give no line. The distro is started for it, as the CLI's own doctor does
// right after.
func cliVersionCheck(sys *System, t target) (Check, bool) {
	if !releaseRE.MatchString(version) || (t.cli != "" && t.cli != "benchbar") {
		return Check{}, false
	}
	var a []string
	if t.distro != "" {
		a = append(a, "-d", t.distro)
	}
	a = append(a, "--cd", "~", "--exec", "/bin/sh", "-c",
		`PATH="$HOME/.local/bin:$PATH"; command -v "$0" >/dev/null 2>&1 && "$0" --version 2>/dev/null | head -n 1`, "benchbar")
	res, err := wslExec(sys, "", a...)
	if err != nil || res.Code != 0 {
		return Check{}, false
	}
	cli, older, newer := cliSkew(res.Stdout)
	if cli == "" {
		return Check{}, false
	}
	c := Check{ID: "cli_version", Label: "CLI version", Status: "ok",
		Message: fmt.Sprintf("benchbar %s in the distro matches benchbar.exe %s", cli, version)}
	where := t.distro
	if where == "" {
		where = "the default distro"
	}
	switch {
	case older:
		c.Status = "warn"
		c.Message = fmt.Sprintf("benchbar %s in %s is older than benchbar.exe %s", cli, where, version)
		c.Fix = "benchbar.exe setup run cli_install"
		if t.distro != "" {
			c.Fix += " --distro " + quoteArg(t.distro)
		}
	case newer:
		c.Status = "warn"
		c.Message = fmt.Sprintf("benchbar %s in %s is newer than benchbar.exe %s", cli, where, version)
		c.Fix = "benchbar.exe self-update"
	}
	return c, true
}
