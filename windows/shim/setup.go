package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// The setup commands take a brand new Windows user to a ready distro:
//
//	benchbar.exe setup check --json [--probe] [--distro NAME]
//	benchbar.exe setup run ACTION [--distro NAME] [--user NAME] --jsonl

const (
	defaultSetupDistro = "Ubuntu-24.04"
	minBuild           = 19045 // Windows 10 22H2: wsl --install --no-distribution needs a build later than 2004
	setupSchema        = 1
	setupUsage         = "usage: benchbar.exe setup check [--json] [--probe] [--distro NAME] | setup run ACTION [--distro NAME] [--user NAME] [--force] --jsonl"
)

var (
	distroNameRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)
	userNameRE   = regexp.MustCompile(`^[a-z_][a-z0-9_-]{0,31}$`)
)

// cmdSetup handles `setup check` and `setup run`. Any other word after
// setup goes to the CLI, which may have its own setup command.
func cmdSetup(sys *System, args []string) int {
	if len(args) == 0 {
		return cmdForward(sys, append([]string{"setup"}, args...))
	}
	switch args[0] {
	case "check":
		return cmdSetupCheck(sys, args[1:])
	case "run":
		return cmdSetupRun(sys, args[1:])
	}
	return cmdForward(sys, append([]string{"setup"}, args...))
}

// setupDistro is the distro setup works on: the flag, else the configured
// one, else the one Ubuntu 24.04 distro that is already there, else
// Ubuntu-24.04. The name must be plain, so it can never carry a quote or an
// option into a command. mayStart says whether looking inside a stopped
// distro is allowed (setup check does that only with --probe).
func setupDistro(sys *System, flag string, mayStart bool) (string, error) {
	name := flag
	if name == "" {
		cfg, err := loadConfig(sys)
		if err != nil {
			return "", err
		}
		name = cfg.str("distro")
	}
	if name == "" {
		name = existingUbuntu(sys, mayStart)
	}
	if name == "" {
		name = defaultSetupDistro
	}
	if !distroNameRE.MatchString(name) {
		return "", fmt.Errorf("%q is not a usable distro name (letters, digits, . _ - only)", name)
	}
	return name, nil
}

// existingUbuntu is the name of the one usable WSL 2 distro when it is
// Ubuntu 24.04 (so setup does not install a second one), or "". A distro
// that is not called Ubuntu is never looked into. A stopped one is not
// started unless mayStart.
func existingUbuntu(sys *System, mayStart bool) string {
	list, err := sys.Distros.Distros()
	if err != nil {
		return ""
	}
	var usable []Distro
	for _, d := range list {
		if !isToolDistro(d.Name) {
			usable = append(usable, d)
		}
	}
	if len(usable) != 1 || usable[0].Version != 2 || !distroNameRE.MatchString(usable[0].Name) ||
		!strings.HasPrefix(strings.ToLower(usable[0].Name), "ubuntu") {
		return ""
	}
	d := usable[0]
	if strings.EqualFold(d.Name, defaultSetupDistro) {
		return d.Name
	}
	if !mayStart && !distroRunning(sys, d.Name) {
		return ""
	}
	res, err := wslExec(sys, "", "-d", d.Name, "--exec", "/bin/sh", "-c", `. /etc/os-release 2>/dev/null; printf '%s %s' "$ID" "$VERSION_ID"`)
	if err != nil || res.Code != 0 || strings.TrimSpace(res.Stdout) != supportedOSID+" "+supportedOSVer {
		return ""
	}
	return d.Name
}

func setupDir(sys *System) string {
	if sys.ConfigDir == "" {
		return ""
	}
	return filepath.Join(sys.ConfigDir, "setup")
}

// --- running wsl.exe -------------------------------------------------------

type wslResult struct {
	Stdout string
	Stderr string
	Code   int
}

// text is stdout and stderr together, for messages.
func (r wslResult) text() string {
	return strings.TrimSpace(strings.TrimSpace(r.Stdout) + "\n" + strings.TrimSpace(r.Stderr))
}

func decodeOut(b []byte) string {
	text, _ := decodeText(b)
	return strings.ReplaceAll(string(text), "\x00", "")
}

// wslExec runs wsl.exe and waits, at most wslTimeoutFor(args). stdin is fed
// when it is not empty. An error means wsl.exe did not run or did not answer
// in time (a *wslTimeoutError); a non zero exit is in Code.
func wslExec(sys *System, stdin string, args ...string) (wslResult, error) {
	return wslExecTimeout(sys, wslTimeoutFor(args), stdin, args...)
}

// wslExecTimeout is wslExec with a chosen deadline. At the deadline wsl.exe
// is ended (and the job object takes what it started), so nothing is left
// behind.
func wslExecTimeout(sys *System, d time.Duration, stdin string, args ...string) (wslResult, error) {
	ctx, cancel := context.WithTimeout(sys.Ctx, d)
	defer cancel()
	cmd, err := wslCommandContext(ctx, sys, args...)
	if err != nil {
		return wslResult{}, err
	}
	var o, e bytes.Buffer
	cmd.Stdout, cmd.Stderr = &o, &e
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	if err := cmd.Start(); err != nil {
		return wslResult{}, err
	}
	defer attachKillOnClose(cmd.Process.Pid)()
	werr := cmd.Wait()
	res := wslResult{Stdout: decodeOut(o.Bytes()), Stderr: decodeOut(e.Bytes())}
	if werr != nil {
		if ctx.Err() == context.DeadlineExceeded {
			return res, &wslTimeoutError{d}
		}
		var ee *exec.ExitError
		if !errors.As(werr, &ee) {
			return res, werr
		}
		res.Code = ee.ExitCode()
	}
	return res, nil
}

// --- the report ------------------------------------------------------------

type setupStep struct {
	ID         string  `json:"id"`
	Status     string  `json:"status"` // ok, missing, warn, fail
	Title      string  `json:"title"`
	Detail     string  `json:"detail"`
	Action     *string `json:"action"`
	NeedsAdmin bool    `json:"needs_admin"`
	// Blocking is true when the step must be ok before the setup is ready.
	// An advisory step (linger, keepalive, wslconfig, shim_path) is never
	// missing or failed: it is warn at worst and never changes ready.
	Blocking bool `json:"blocking"`
	// CLIVersion is only set on the cli step, when the CLI in the distro
	// reports a release that differs from benchbar.exe: the installed
	// version. It is left out when unknown, so a step with the status
	// missing and a CLI version is an update, not an install.
	CLIVersion string `json:"cli_version,omitempty"`
}

type setupReport struct {
	SchemaVersion int         `json:"schema_version"`
	Distro        string      `json:"distro"`
	Ready         bool        `json:"ready"`
	RebootPending bool        `json:"reboot_pending"`
	Steps         []setupStep `json:"steps"`
}

func strp(s string) *string { return &s }

type stepDef struct {
	id       string
	title    string
	blocking bool
	admin    bool // static: the action needs the UAC prompt
	fn       func() setupStep
}

// checker holds what the steps share, so each fact is read once.
type checker struct {
	sys       *System
	distro    string
	probe     bool
	target    target
	statusRan bool
	wslWorks  bool
	statusErr error // wsl.exe --status did not answer in time

	registered bool
	probed     bool
	pr         probeResult
	unchecked  bool
	reboot     bool
}

func (c *checker) step(id, status, detail string, action string) setupStep {
	s := setupStep{ID: id, Status: status, Detail: detail}
	if action != "" {
		s.Action = strp(action)
		s.NeedsAdmin = action == "wsl_enable"
	}
	return s
}

func (c *checker) wslStatus() bool {
	if c.statusRan {
		return c.wslWorks
	}
	c.statusRan = true
	res, err := wslExec(c.sys, "", "--status")
	c.wslWorks = err == nil && res.Code == 0
	if isWslTimeout(err) {
		c.statusErr = err
	}
	return c.wslWorks
}

func (c *checker) defs() []stepDef {
	return []stepDef{
		{"windows_build", "Windows version", true, false, c.windowsBuild},
		{"virtualization", "Virtualization", true, false, c.virtualization},
		{"wsl_feature", "Windows Subsystem for Linux", true, true, c.wslFeature},
		{"reboot", "Restart Windows", true, false, c.rebootStep},
		{"wsl_version", "WSL version", true, false, c.wslVersion},
		{"distro", "Linux distro", true, false, c.distroStep},
		{"distro_os", "Linux version", true, false, c.distroOS},
		{"distro_user", "Linux user", true, false, c.distroUser},
		{"systemd", "systemd", true, false, c.systemdStep},
		{"cli", "BenchBar command line tool", true, false, c.cliStep},
		{"linger", "Keep benches running", false, false, c.lingerStep},
		{"keepalive", "Keep the distro awake", false, false, c.keepaliveStep},
		{"wslconfig", "WSL idle settings", false, false, c.wslconfigStep},
		{"shim_path", "benchbar.exe on PATH", false, false, c.pathStep},
	}
}

func (c *checker) windowsBuild() setupStep {
	b, err := c.sys.Host.WindowsBuild()
	switch {
	case err != nil:
		return c.step("windows_build", "warn", "cannot read the Windows build: "+err.Error(), "")
	case b < minBuild:
		return c.step("windows_build", "fail", fmt.Sprintf("Windows build %d is too old, WSL 2 needs Windows 10 version 22H2 (build %d) or Windows 11: update Windows in Settings > Windows Update", b, minBuild), "")
	}
	return c.step("windows_build", "ok", fmt.Sprintf("Windows build %d", b), "")
}

func (c *checker) virtualization() setupStep {
	on, err := c.sys.Host.VirtualizationEnabled()
	switch {
	case err != nil:
		return c.step("virtualization", "warn", "cannot tell if virtualization is on: "+err.Error(), "")
	case on:
		return c.step("virtualization", "ok", "virtualization is enabled in the firmware", "")
	case c.wslStatus():
		// WSL answers, so the machine can run it whatever the flag says
		return c.step("virtualization", "ok", "Windows does not report firmware virtualization, but WSL runs", "")
	}
	// IsProcessorFeaturePresent can say no while a hypervisor already runs, so
	// this does not stop the setup. If WSL then fails with 0x80370102, the
	// message of the failing step names the firmware setting.
	return c.step("virtualization", "warn", "Windows does not report firmware virtualization (this can be wrong). If WSL does not start later, turn on Intel VT-x or AMD SVM (AMD-V) in the BIOS or UEFI settings", "")
}

func (c *checker) wslFeature() setupStep {
	if rebootMarkerPending(c.sys) {
		c.reboot = true
		return c.step("wsl_feature", "ok", "WSL is enabled and waits for a restart of Windows", "")
	}
	if c.wslStatus() {
		return c.step("wsl_feature", "ok", "wsl.exe --status answers", "")
	}
	if c.statusErr != nil {
		// no answer is not "not installed": do not offer to install anything
		return c.step("wsl_feature", "fail", c.statusErr.Error(), "")
	}
	return c.step("wsl_feature", "missing", "WSL is not installed or does not answer; Windows will ask for permission to turn it on", "wsl_enable")
}

func (c *checker) rebootStep() setupStep {
	if c.reboot || rebootMarkerPending(c.sys) {
		c.reboot = true
		return c.step("reboot", "missing", "Windows must restart before WSL can start a Linux distro. Choose Restart in the Start menu, not Shut down: with Fast Startup, Shut down does not count as a restart", "reboot")
	}
	return c.step("reboot", "ok", "no restart is pending", "")
}

var versionRE = regexp.MustCompile(`(\d+)\.(\d+)\.(\d+)`)

// wslVersionOK reports whether `wsl.exe --version` output names a WSL that
// runs systemd (0.67.6 and later, the Store build).
func wslVersionOK(out string) (string, bool) {
	line, _, _ := strings.Cut(strings.TrimSpace(out), "\n")
	m := versionRE.FindStringSubmatch(line)
	if m == nil {
		return "", false
	}
	n := func(s string) int { v, _ := strconv.Atoi(s); return v }
	maj, min, pat := n(m[1]), n(m[2]), n(m[3])
	ok := maj > 0 || min > 67 || (min == 67 && pat >= 6)
	return m[0], ok
}

func (c *checker) wslVersion() setupStep {
	res, err := wslExec(c.sys, "", "--version")
	if isWslTimeout(err) {
		return c.step("wsl_version", "fail", err.Error(), "")
	}
	if err != nil || res.Code != 0 {
		return c.step("wsl_version", "missing", "this is the old built in WSL, the current one comes from the Microsoft Store (wsl.exe --update)", "wsl_update")
	}
	v, ok := wslVersionOK(res.Stdout)
	if !ok {
		return c.step("wsl_version", "missing", "WSL version "+orUnknown(v)+" is too old for systemd (wsl.exe --update)", "wsl_update")
	}
	return c.step("wsl_version", "ok", "WSL version "+v, "")
}

func orUnknown(s string) string {
	if s == "" {
		return "unknown"
	}
	return s
}

// runningNames are the distros that run now. The quiet list holds names
// only, so it does not depend on the language of Windows.
func runningNames(sys *System) []string {
	res, err := wslExec(sys, "", "--list", "--running", "--quiet")
	if err != nil || res.Code != 0 {
		return nil
	}
	var names []string
	for _, l := range strings.Split(res.Stdout, "\n") {
		if l = strings.TrimSpace(l); l != "" {
			names = append(names, l)
		}
	}
	return names
}

func (c *checker) distroStep() setupStep {
	list, err := c.sys.Distros.Distros()
	if err != nil {
		return c.step("distro", "missing", "cannot read the WSL registry: "+err.Error(), "distro_install")
	}
	var info *Distro
	for i := range list {
		if strings.EqualFold(list[i].Name, c.distro) {
			info = &list[i]
		}
	}
	if info == nil {
		return c.step("distro", "missing", c.distro+" is not installed", "distro_install")
	}
	c.registered = true
	if info.Version != 2 {
		return c.step("distro", "fail", fmt.Sprintf("%s runs as WSL %d, benches need WSL 2. Fix: wsl.exe --set-version %s 2 (or benchbar.exe setup run distro_wsl2; it stops the distro)", info.Name, info.Version, quoteArg(info.Name)), "distro_wsl2")
	}
	run := c.probe
	if !run {
		for _, n := range runningNames(c.sys) {
			if strings.EqualFold(n, info.Name) {
				run = true
			}
		}
	}
	if !run {
		return c.step("distro", "ok", info.Name+" is installed and stopped, so the steps inside it are not checked (use --probe to start it and check)", "")
	}
	pr, err := runProbeScript(c.sys, info.Name, c.target.cli, setupProbeScript)
	if err != nil {
		return c.step("distro", "fail", fmt.Sprintf("%s is installed but a command in it failed: %v", info.Name, err), "")
	}
	c.probed, c.pr = true, pr
	return c.step("distro", "ok", info.Name+" is installed and runs WSL 2", "")
}

// notChecked is the row of a step that needs the distro while it is stopped.
func (c *checker) notChecked(id string) setupStep {
	c.unchecked = true
	return c.step(id, "warn", "not checked: the distro is stopped (run setup check --probe to start it and check)", "")
}

// distroOS checks the distro is Ubuntu 24.04, the one release BenchBar
// supports. A distro whose release cannot be read is a warning, not a stop.
func (c *checker) distroOS() setupStep {
	if !c.probed {
		return c.notChecked("distro_os")
	}
	if c.pr.osID == "" {
		return c.step("distro_os", "warn", "cannot read /etc/os-release in "+c.distro+", so the Linux release is not checked", "")
	}
	if msg := osProblem(c.distro, c.pr); msg != "" {
		return c.step("distro_os", "fail", msg+". Fix: "+osFix(), "")
	}
	return c.step("distro_os", "ok", "Ubuntu "+c.pr.osVer, "")
}

func (c *checker) distroUser() setupStep {
	if !c.probed {
		return c.notChecked("distro_user")
	}
	if c.pr.uid == "" || c.pr.uid == "0" {
		return c.step("distro_user", "missing", "the default user of "+c.distro+" is root; BenchBar needs a normal user with sudo", "distro_user")
	}
	return c.step("distro_user", "ok", "default user "+c.pr.user, "")
}

func (c *checker) systemdStep() setupStep {
	if !c.probed {
		return c.notChecked("systemd")
	}
	conf := parseINI([]byte(c.pr.wslConf))
	v, _ := conf.get("boot", "systemd")
	on := strings.EqualFold(v, "true")
	switch {
	case on && c.pr.pid1 == "systemd":
		return c.step("systemd", "ok", "enabled in /etc/wsl.conf and running as PID 1", "")
	case on:
		return c.step("systemd", "missing", fmt.Sprintf("enabled in /etc/wsl.conf, but PID 1 is %q: the distro must restart", c.pr.pid1), "systemd")
	}
	return c.step("systemd", "missing", "[boot] systemd=true is not set in /etc/wsl.conf", "systemd")
}

func (c *checker) cliStep() setupStep {
	if !c.probed {
		return c.notChecked("cli")
	}
	if c.pr.bench != "" {
		return c.cliInstalled()
	}
	if c.target.cli != "" && c.target.cli != "benchbar" {
		return c.step("cli", "missing", missingCLIFix(c.target), "")
	}
	return c.step("cli", "missing", "benchbar is not on the PATH inside "+c.distro, "cli_install")
}

// cliInstalled is the cli step when benchbar is there. A release build of
// the shim wants the CLI of the same release: an older one is not ok, and
// cli_install brings it up to date. A newer one only warns, since nothing
// here should take a CLI back to an older release.
func (c *checker) cliInstalled() setupStep {
	detail := orUnknown(c.pr.cliVer) + " at " + c.pr.bench
	if c.target.cli != "" && c.target.cli != "benchbar" {
		return c.step("cli", "ok", detail, "")
	}
	cli, older, newer := cliSkew(c.pr.cliVer)
	switch {
	case older:
		s := c.step("cli", "missing", fmt.Sprintf("benchbar %s in %s does not match benchbar.exe %s: update it with benchbar.exe setup run cli_install", cli, c.distro, version), "cli_install")
		s.CLIVersion = cli
		return s
	case newer:
		s := c.step("cli", "warn", fmt.Sprintf("benchbar %s in %s is newer than benchbar.exe %s: update benchbar.exe to the same release", cli, c.distro, version), "")
		s.CLIVersion = cli
		return s
	}
	return c.step("cli", "ok", detail, "")
}

func (c *checker) lingerStep() setupStep {
	if !c.probed {
		return c.notChecked("linger")
	}
	switch c.pr.linger {
	case "yes":
		return c.step("linger", "ok", "enabled for "+c.pr.user, "")
	case "no":
		return c.step("linger", "warn", "off for "+c.pr.user+": benches stop when the last session ends", "linger")
	}
	return c.step("linger", "warn", "cannot read the linger setting of "+c.pr.user, "linger")
}

func (c *checker) keepaliveStep() setupStep {
	info := queryKeepalive(c.sys)
	checkKeepaliveTarget(&info, c.distro)
	k := info.Checks[0]
	if k.Status == "ok" {
		return c.step("keepalive", "ok", k.Message, "")
	}
	return c.step("keepalive", "warn", k.Message, "keepalive")
}

func (c *checker) wslconfigStep() setupStep {
	_, rep, err := readWslconfig(c.sys)
	if err != nil {
		return c.step("wslconfig", "warn", err.Error(), "")
	}
	k := idleCheck(rep)
	if k.Status == "ok" {
		return c.step("wslconfig", "ok", k.Message, "")
	}
	return c.step("wslconfig", "warn", k.Message, "wslconfig")
}

func (c *checker) pathStep() setupStep {
	k := pathCheck(c.sys)
	if k.Status == "ok" {
		return c.step("shim_path", "ok", k.Message, "")
	}
	if k.Fix == "benchbar.exe path install" {
		return c.step("shim_path", "warn", k.Message, "path")
	}
	// no action can fix it: the detail holds the exact command to run
	return c.step("shim_path", "warn", k.Message+": "+k.Fix, "")
}

// buildSetupReport reads the state. Steps run in order; once a blocking one
// is not ok, the rest are reported as waiting and nothing more is read.
func buildSetupReport(sys *System, distro string, probe bool) setupReport {
	c := &checker{sys: sys, distro: distro, probe: probe}
	if t, err := resolveTarget(sys, ""); err == nil {
		c.target = t
	}
	c.target.distro = distro
	if c.target.cli == "" {
		c.target.cli = "benchbar"
	}
	rep := setupReport{SchemaVersion: setupSchema, Distro: distro, Steps: []setupStep{}}
	blocker := ""
	for _, d := range c.defs() {
		if blocker != "" {
			rep.Steps = append(rep.Steps, setupStep{ID: d.id, Status: "missing", Title: d.title,
				Detail: "waits for " + blocker, Blocking: d.blocking})
			continue
		}
		s := d.fn()
		s.Title, s.Blocking = d.title, d.blocking
		rep.Steps = append(rep.Steps, s)
		if d.blocking && (s.Status == "missing" || s.Status == "fail") {
			blocker = d.id
		}
	}
	rep.RebootPending = c.reboot
	rep.Ready = !c.unchecked
	for _, s := range rep.Steps {
		if s.Blocking && (s.Status == "missing" || s.Status == "fail") {
			rep.Ready = false
		}
	}
	return rep
}

func cmdSetupCheck(sys *System, args []string) int {
	p, err := parseFlags(args, []string{"--json", "--probe"}, []string{"--distro"})
	if err == nil && len(p.pos) > 0 {
		err = fmt.Errorf("unexpected argument %s", p.pos[0])
	}
	if err != nil {
		errorf(sys, "%v. %s", err, setupUsage)
		return 1
	}
	distro, err := setupDistro(sys, p.vals["--distro"], p.bools["--probe"])
	if err != nil {
		errorf(sys, "%v", err)
		return 1
	}
	rep := buildSetupReport(sys, distro, p.bools["--probe"])
	if p.bools["--json"] {
		printJSON(sys.Stdout, rep)
		return 0
	}
	for _, s := range rep.Steps {
		fmt.Fprintf(sys.Stdout, "  [%s] %s: %s\n", strings.ToUpper(s.Status), s.Title, s.Detail)
		if s.Action != nil {
			fmt.Fprintf(sys.Stdout, "     action: benchbar.exe setup run %s\n", *s.Action)
		}
	}
	fmt.Fprintf(sys.Stdout, "\n  ready: %v\n", rep.Ready)
	return 0
}

// --- reboot marker ---------------------------------------------------------

// The marker is written by the unelevated process after wsl_enable said a
// restart is needed. It counts as pending until Windows has started after
// the time it records.
type rebootMarker struct {
	RecordedAt string `json:"recorded_at"`
	Reason     string `json:"reason"`
}

func rebootMarkerPath(sys *System) string {
	if d := setupDir(sys); d != "" {
		return filepath.Join(d, "reboot-pending.json")
	}
	return ""
}

func writeRebootMarker(sys *System, reason string) error {
	path := rebootMarkerPath(sys)
	if path == "" {
		return errors.New("LOCALAPPDATA is not set")
	}
	data, _ := json.Marshal(rebootMarker{RecordedAt: sys.Now().UTC().Format(time.RFC3339), Reason: reason})
	return writeFileAtomic(path, append(data, '\n'))
}

func clearRebootMarker(sys *System) {
	if path := rebootMarkerPath(sys); path != "" {
		os.Remove(path)
	}
}

func rebootMarkerPending(sys *System) bool {
	path := rebootMarkerPath(sys)
	if path == "" {
		return false
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	var m rebootMarker
	if json.Unmarshal(data, &m) != nil {
		return false
	}
	at, err := time.Parse(time.RFC3339, m.RecordedAt)
	if err != nil {
		return false
	}
	boot, err := sys.Host.BootTime()
	if err != nil {
		return false
	}
	return boot.Before(at)
}
