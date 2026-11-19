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
	checks = append(checks, twoInstallsCheck(sys)...)
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
// The CLI's bytes are kept and the key goes in before the closing brace, so
// its key order is not changed. With --jsonl the CLI streams several lines
// (plan, step, progress, then one done line that holds the document's keys):
// the array goes into the done line, or into the last line when there is no
// done line, and every other line stays as it is. Anything else (not JSON,
// an array, two documents in one line) is returned unchanged.
func withWindowsChecks(doc []byte, checks []Check) []byte {
	arr, _ := json.Marshal(windowsChecksJSON(checks))
	if one := bytes.TrimSpace(doc); len(one) >= 2 && one[0] == '{' && one[len(one)-1] == '}' && json.Valid(one) {
		return append(spliceWindowsChecks(one, arr), '\n')
	}
	lines := splitJSONLines(doc)
	if len(lines) == 0 {
		return doc
	}
	target := len(lines) - 1
	for i := len(lines) - 1; i >= 0 && len(lines) > 1; i-- {
		var ev struct {
			Event string `json:"event"`
		}
		if json.Unmarshal(lines[i], &ev) == nil && ev.Event == "done" {
			target = i
			break
		}
	}
	var out []byte
	for i, l := range lines {
		if i == target {
			l = spliceWindowsChecks(l, arr)
		}
		out = append(append(out, l...), '\n')
	}
	return out
}

// splitJSONLines returns the non-empty lines of doc, each trimmed, when
// every one is a JSON object; nil otherwise.
func splitJSONLines(doc []byte) [][]byte {
	var lines [][]byte
	for _, l := range bytes.Split(doc, []byte("\n")) {
		l = bytes.TrimSpace(l)
		if len(l) == 0 {
			continue
		}
		if l[0] != '{' || l[len(l)-1] != '}' || !json.Valid(l) {
			return nil
		}
		lines = append(lines, l)
	}
	return lines
}

// spliceWindowsChecks puts "windows_checks":arr before the closing brace of
// one JSON object.
func spliceWindowsChecks(obj, arr []byte) []byte {
	body := bytes.TrimSpace(obj[1 : len(obj)-1])
	sep := ","
	if len(body) == 0 {
		sep = ""
	}
	out := append([]byte{}, obj[:len(obj)-1]...)
	out = append(out, sep+`"windows_checks":`...)
	out = append(out, arr...)
	return append(out, '}')
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
		c.Fix = updateFix(sys)
	}
	return c, true
}
