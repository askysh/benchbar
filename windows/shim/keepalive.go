package main

import (
	"bytes"
	"context"
	"encoding/csv"
	"encoding/json"
	"encoding/xml"
	"fmt"
	"html"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf16"
)

const (
	taskName      = "BenchBar Keepalive"
	runLockName   = `Local\BenchBarKeepalive`
	logLimit      = 1 << 20
	backoffStart  = 10 * time.Second
	backoffMax    = 5 * time.Minute
	backoffResets = 10 * time.Minute
)

func xmlText(s string) string {
	var b bytes.Buffer
	xml.EscapeText(&b, []byte(s))
	return b.String()
}

// keepaliveXML is the task definition: at logon of the current user, no
// admin, hidden, restarted a minute after a failure.
func keepaliveXML(user, exe, distro string) string {
	args := fmt.Sprintf(`--headless "%s" keepalive run --distro "%s"`, exe, distro)
	return `<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Keeps the WSL distro ` + xmlText(distro) + ` running so BenchBar benches stay up.</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>` + xmlText(user) + `</UserId>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>` + xmlText(user) + `</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>true</Hidden>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>999</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>conhost.exe</Command>
      <Arguments>` + xmlText(args) + `</Arguments>
    </Exec>
  </Actions>
</Task>
`
}

// utf16LE is the encoding Task Scheduler wants for an XML file: with a BOM.
func utf16LE(s string) []byte {
	u := utf16.Encode([]rune(s))
	b := make([]byte, 0, 2+len(u)*2)
	b = append(b, 0xFF, 0xFE)
	for _, c := range u {
		b = append(b, byte(c), byte(c>>8))
	}
	return b
}

var argumentsRE = regexp.MustCompile(`(?s)<Arguments>(.*?)</Arguments>`)

// splitCommandLine splits on spaces outside double quotes.
func splitCommandLine(s string) []string {
	var out []string
	var cur strings.Builder
	inQuote, has := false, false
	for _, r := range s {
		switch {
		case r == '"':
			inQuote, has = !inQuote, true
		case r == ' ' && !inQuote:
			if has {
				out = append(out, cur.String())
				cur.Reset()
				has = false
			}
		default:
			cur.WriteRune(r)
			has = true
		}
	}
	if has {
		out = append(out, cur.String())
	}
	return out
}

// parseTaskArguments reads the exe path and distro out of the task's action.
func parseTaskArguments(taskXML string) (exe, distro string, ok bool) {
	m := argumentsRE.FindStringSubmatch(taskXML)
	if m == nil {
		return "", "", false
	}
	toks := splitCommandLine(html.UnescapeString(m[1]))
	for i, t := range toks {
		switch {
		case t == "--headless" && i+1 < len(toks):
			exe = toks[i+1]
		case t == "--distro" && i+1 < len(toks):
			distro = toks[i+1]
		}
	}
	return exe, distro, exe != ""
}

type keepaliveInfo struct {
	Installed  bool    `json:"installed"`
	Task       string  `json:"task"`
	Exe        string  `json:"exe"`
	Distro     string  `json:"distro"`
	ExeExists  bool    `json:"exe_exists"`
	Status     string  `json:"status"`
	LastResult string  `json:"last_result"`
	RunPid     int     `json:"run_pid"`
	RunAlive   bool    `json:"run_alive"`
	Checks     []Check `json:"checks"`
}

func queryKeepalive(sys *System) keepaliveInfo {
	info := keepaliveInfo{Task: taskName}
	rec := readPidRecord(sys)
	info.RunPid = rec.Pid
	info.RunAlive = isKeepaliveProcess(sys, rec)
	c := Check{ID: "keepalive", Label: "Keepalive"}
	notInstalled := Check{ID: "keepalive", Label: "Keepalive", Status: "warn",
		Message: "not installed", Fix: "benchbar.exe keepalive install"}

	out, code, err := sys.Tasks.Schtasks("/Query", "/TN", taskName, "/XML")
	if err != nil {
		c.Status, c.Message = "warn", fmt.Sprintf("cannot run schtasks.exe: %v", err)
		c.Fix = `schtasks.exe /Query /TN "BenchBar Keepalive"`
		info.Checks = []Check{c}
		return info
	}
	if code != 0 {
		info.Checks = []Check{notInstalled}
		return info
	}
	info.Installed = true
	exe, distro, ok := parseTaskArguments(out)
	info.Exe, info.Distro = exe, distro
	info.ExeExists = ok && sys.FileExists(exe)

	if out, code, err := sys.Tasks.Schtasks("/Query", "/TN", taskName, "/FO", "CSV", "/V", "/NH"); err == nil && code == 0 {
		r := csv.NewReader(strings.NewReader(out))
		r.LazyQuotes, r.FieldsPerRecord = true, -1
		if rec, err := r.Read(); err == nil && len(rec) > 6 {
			info.Status, info.LastResult = rec[3], rec[6]
		}
	}

	c.Fix = "benchbar.exe keepalive install"
	switch {
	case !ok:
		c.Status, c.Message = "warn", "installed, but its action is not a BenchBar keepalive"
	case !info.ExeExists:
		c.Status, c.Message = "warn", fmt.Sprintf("installed, but %s does not exist", exe)
	default:
		c.Status, c.Fix = "ok", ""
		c.Message = fmt.Sprintf("installed for %s via %s", distro, exe)
		if info.Status != "" {
			c.Message += fmt.Sprintf(" (status %s, last result %s)", info.Status, info.LastResult)
		}
		if info.RunAlive {
			c.Message += fmt.Sprintf("; run process pid %d is alive", info.RunPid)
		} else {
			c.Message += "; run process is not running"
		}
	}
	info.Checks = []Check{c}
	return info
}

func cmdKeepalive(sys *System, args []string) int {
	usage := "usage: benchbar.exe keepalive install|remove|status|run [--distro D]"
	if len(args) == 0 {
		errorf(sys, "%s", usage)
		return 1
	}
	sub := args[0]
	p, err := parseFlags(args[1:], []string{"--json"}, []string{"--distro"})
	if err == nil && len(p.pos) > 0 {
		err = fmt.Errorf("unexpected argument %s", p.pos[0])
	}
	if err != nil {
		errorf(sys, "%v. %s", err, usage)
		return 1
	}
	switch sub {
	case "status":
		return keepaliveStatus(sys, p.bools["--json"])
	case "remove":
		return keepaliveRemove(sys)
	case "install", "run":
		t, err := resolveTarget(sys, p.vals["--distro"])
		if err != nil {
			errorf(sys, "%v", err)
			return 1
		}
		if t.prob != nil {
			t.prob.print(sys)
			return 1
		}
		if t.distro == "" || strings.Contains(t.distro, `"`) {
			errorf(sys, "no usable distro name; pass --distro NAME")
			return 1
		}
		if sub == "install" {
			return keepaliveInstall(sys, t.distro)
		}
		return keepaliveRun(sys, t.distro)
	}
	errorf(sys, "unknown keepalive command %q. %s", sub, usage)
	return 1
}

func keepaliveStatus(sys *System, asJSON bool) int {
	info := queryKeepalive(sys)
	if asJSON {
		printJSON(sys.Stdout, info)
	} else {
		printChecks(sys.Stdout, info.Checks)
	}
	if hasFail(info.Checks) {
		return 1
	}
	return 0
}

func keepaliveInstall(sys *System, distro string) int {
	f, err := os.CreateTemp("", "benchbar-keepalive-*.xml")
	if err != nil {
		errorf(sys, "cannot write the task file: %v", err)
		return 1
	}
	defer os.Remove(f.Name())
	_, err = f.Write(utf16LE(keepaliveXML(sys.User, sys.ExePath, distro)))
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		errorf(sys, "cannot write the task file: %v", err)
		return 1
	}
	if out, code, err := sys.Tasks.Schtasks("/Create", "/TN", taskName, "/XML", f.Name(), "/F"); err != nil || code != 0 {
		errorf(sys, "schtasks.exe could not create the task: %s", schtasksDetail(out, err))
		return 1
	}
	fmt.Fprintf(sys.Stdout, "Installed the task %q for %s.\n", taskName, distro)
	// a run for another distro (or an older exe) would keep going and hold the lock
	stopped, err := stopRun(sys)
	if err != nil {
		errorf(sys, "%v", err)
		return 1
	}
	if stopped != 0 {
		sys.Tasks.Schtasks("/End", "/TN", taskName)
	}
	if out, code, err := sys.Tasks.Schtasks("/Run", "/TN", taskName); err != nil || code != 0 {
		errorf(sys, "the task is installed but did not start: %s", schtasksDetail(out, err))
		return 1
	}
	fmt.Fprintln(sys.Stdout, "Started it. It also starts at every logon.")
	return 0
}

func keepaliveRemove(sys *System) int {
	installed := true
	if _, code, err := sys.Tasks.Schtasks("/Query", "/TN", taskName); err == nil && code != 0 {
		installed = false
	}
	if installed {
		sys.Tasks.Schtasks("/End", "/TN", taskName)
		if out, code, err := sys.Tasks.Schtasks("/Delete", "/TN", taskName, "/F"); err != nil || code != 0 {
			errorf(sys, "schtasks.exe could not delete the task: %s", schtasksDetail(out, err))
			return 1
		}
		fmt.Fprintf(sys.Stdout, "Removed the task %q.\n", taskName)
	} else {
		fmt.Fprintln(sys.Stdout, "The task is not installed.")
	}
	// /End stops only the task's console; the run process outlives it
	if _, err := stopRun(sys); err != nil {
		errorf(sys, "%v", err)
		return 1
	}
	return 0
}

// pidRecord is the keepalive.pid file: which process holds the run, and when
// it was created, since a pid number can be reused later by another process.
type pidRecord struct {
	Pid     int    `json:"pid"`
	Created uint64 `json:"created"`
}

func pidFile(sys *System) string { return filepath.Join(sys.ConfigDir, "keepalive.pid") }

// readPidRecord returns the zero record for a missing or unreadable file. An
// old plain number has no creation time and so never matches a process.
func readPidRecord(sys *System) pidRecord {
	var r pidRecord
	if sys.ConfigDir == "" {
		return r
	}
	data, err := os.ReadFile(pidFile(sys))
	if err != nil {
		return r
	}
	if json.Unmarshal(data, &r) != nil {
		if n, err := strconv.Atoi(strings.TrimSpace(string(data))); err == nil {
			return pidRecord{Pid: n}
		}
		return pidRecord{}
	}
	return r
}

// isKeepaliveProcess is true only for the process the record names: alive,
// program benchbar.exe, same creation time.
func isKeepaliveProcess(sys *System, r pidRecord) bool {
	if r.Pid <= 0 || r.Created == 0 || !sys.Procs.Alive(r.Pid) {
		return false
	}
	img, err := sys.Procs.Image(r.Pid)
	if err != nil || !strings.EqualFold(img[strings.LastIndexAny(img, `\/`)+1:], "benchbar.exe") {
		return false
	}
	created, err := sys.Procs.Created(r.Pid)
	return err == nil && created == r.Created
}

// stopRun ends the process in the pid file, if it is the one that wrote it,
// and removes the file. It reports the pid it ended, or 0.
func stopRun(sys *System) (int, error) {
	if sys.ConfigDir == "" {
		return 0, nil
	}
	rec := readPidRecord(sys)
	stopped := 0
	if isKeepaliveProcess(sys, rec) {
		if err := sys.Procs.Terminate(rec.Pid); err != nil {
			return 0, fmt.Errorf("cannot stop the keepalive run process (pid %d): %v", rec.Pid, err)
		}
		fmt.Fprintf(sys.Stdout, "Stopped the keepalive run process (pid %d).\n", rec.Pid)
		stopped = rec.Pid
	}
	os.Remove(pidFile(sys))
	return stopped, nil
}

func schtasksDetail(out string, err error) string {
	if err != nil {
		return err.Error()
	}
	return strings.TrimSpace(out)
}

// keepaliveLog writes one line per event, and starts over past 1 MB.
type keepaliveLog struct{ sys *System }

func (l keepaliveLog) printf(format string, a ...any) {
	if l.sys.ConfigDir == "" {
		return
	}
	path := filepath.Join(l.sys.ConfigDir, "keepalive.log")
	if os.MkdirAll(l.sys.ConfigDir, 0o755) != nil {
		return
	}
	if st, err := os.Stat(path); err == nil && st.Size() > logLimit {
		os.Truncate(path, 0)
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "%s %s\n", l.sys.Now().Format("2006-01-02 15:04:05"), fmt.Sprintf(format, a...))
}

// runWSL runs wsl.exe with no console input or output until it ends or ctx
// is cancelled.
func runWSL(ctx context.Context, sys *System, args ...string) error {
	cmd, err := wslCommand(sys, args...)
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	defer attachKillOnClose(cmd.Process.Pid)()
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		return err
	case <-ctx.Done():
		cmd.Process.Kill()
		<-done
		return ctx.Err()
	}
}

// keepaliveRun holds the distro open with a sleeping process. If it ends,
// it starts again after a growing wait.
func keepaliveRun(sys *System, distro string) int {
	ctx, stop := signal.NotifyContext(sys.Ctx, os.Interrupt)
	defer stop()
	log := keepaliveLog{sys}
	log.printf("keepalive for %s started", distro)
	release, ok, err := sys.Locks.TryLock(runLockName)
	if err == nil && !ok {
		log.printf("another keepalive run holds %s, exiting", runLockName)
		return 0
	}
	if err != nil {
		log.printf("cannot take %s: %v", runLockName, err)
	} else {
		defer release()
	}
	created, _ := sys.Procs.Created(sys.Pid)
	rec, _ := json.Marshal(pidRecord{Pid: sys.Pid, Created: created})
	if err := writeFileAtomic(pidFile(sys), append(rec, '\n')); err != nil {
		log.printf("cannot write the pid file: %v", err)
	} else {
		defer func() {
			if readPidRecord(sys).Pid == sys.Pid {
				os.Remove(pidFile(sys))
			}
		}()
	}

	if err := runWSL(ctx, sys, "-d", distro, "--exec", "/bin/true"); err != nil && ctx.Err() == nil {
		log.printf("wake up of %s failed: %v", distro, err)
	}
	backoff := backoffStart
	for ctx.Err() == nil {
		began := sys.Now()
		log.printf("starting sleep infinity in %s", distro)
		err := runWSL(ctx, sys, "-d", distro, "--exec", "sleep", "infinity")
		if ctx.Err() != nil {
			break
		}
		ran := sys.Now().Sub(began)
		log.printf("sleep infinity ended after %s (%s)", ran.Round(time.Second), exitText(err))
		var wait time.Duration
		wait, backoff = nextBackoff(backoff, ran)
		log.printf("next start in %s", wait)
		sys.Sleep(ctx, wait)
	}
	log.printf("keepalive for %s stopped", distro)
	return 0
}

// nextBackoff returns how long to wait now and the wait after it: 10 seconds,
// doubling to 5 minutes, back to 10 seconds after a run of 10 minutes.
func nextBackoff(cur, ran time.Duration) (wait, next time.Duration) {
	if ran >= backoffResets {
		cur = backoffStart
	}
	return cur, min(cur*2, backoffMax)
}

func exitText(err error) string {
	if err == nil {
		return "exit 0"
	}
	if ee, ok := err.(*exec.ExitError); ok {
		return fmt.Sprintf("exit %d", ee.ExitCode())
	}
	return err.Error()
}
