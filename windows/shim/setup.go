package main

import (
	"bytes"
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
//
// `setup elevated` is internal: the elevated half of wsl_enable.

const (
	defaultSetupDistro = "Ubuntu-24.04"
	minBuild           = 19041 // Windows 10 version 2004, the first with wsl --install
	setupSchema        = 1
	setupUsage         = "usage: benchbar.exe setup check [--json] [--probe] [--distro NAME] | setup run ACTION [--distro NAME] [--user NAME] --jsonl"
)

var (
	distroNameRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)
	userNameRE   = regexp.MustCompile(`^[a-z_][a-z0-9_-]{0,31}$`)
)

// cmdSetup handles `setup check`, `setup run` and the internal `setup
// elevated`. Any other word after setup goes to the CLI, which may have its
// own setup command.
func cmdSetup(sys *System, args []string) int {
	if len(args) == 0 {
		return cmdForward(sys, append([]string{"setup"}, args...))
	}
	switch args[0] {
	case "check":
		return cmdSetupCheck(sys, args[1:])
	case "run":
		return cmdSetupRun(sys, args[1:])
	case "elevated":
		return cmdSetupElevated(sys, args[1:])
	}
	return cmdForward(sys, append([]string{"setup"}, args...))
}

// setupDistro is the distro setup works on: the flag, else the configured
// one, else Ubuntu-24.04. The name must be plain, so it can never carry a
// quote or an option into a command.
func setupDistro(sys *System, flag string) (string, error) {
	name := flag
	if name == "" {
		cfg, err := loadConfig(sys)
		if err != nil {
			return "", err
		}
		name = cfg.str("distro")
	}
	if name == "" {
		name = defaultSetupDistro
	}
	if !distroNameRE.MatchString(name) {
		return "", fmt.Errorf("%q is not a usable distro name (letters, digits, . _ - only)", name)
	}
	return name, nil
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

// wslExec runs wsl.exe and waits. stdin is fed when it is not empty. An
// error means wsl.exe did not run; a non zero exit is in Code.
func wslExec(sys *System, stdin string, args ...string) (wslResult, error) {
	cmd, err := wslCommand(sys, args...)
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
		return c.step("windows_build", "fail", fmt.Sprintf("Windows build %d is too old, WSL 2 needs Windows 10 version 2004 (build %d) or Windows 11", b, minBuild), "")
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
	return c.step("virtualization", "fail", "virtualization is off: turn on Intel VT-x or AMD-V (SVM) in the BIOS or UEFI settings, then start again", "")
}

func (c *checker) wslFeature() setupStep {
	if rebootMarkerPending(c.sys) {
		c.reboot = true
		return c.step("wsl_feature", "ok", "WSL is enabled and waits for a restart of Windows", "")
	}
	if c.wslStatus() {
		return c.step("wsl_feature", "ok", "wsl.exe --status answers", "")
	}
	return c.step("wsl_feature", "missing", "WSL is not installed or does not answer; Windows will ask for permission to turn it on", "wsl_enable")
}

func (c *checker) rebootStep() setupStep {
	if c.reboot || rebootMarkerPending(c.sys) {
		c.reboot = true
		return c.step("reboot", "missing", "Windows must restart before WSL can start a Linux distro", "reboot")
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
		return c.step("distro", "fail", fmt.Sprintf("%s runs as WSL %d, benches need WSL 2: wsl.exe --set-version %s 2", info.Name, info.Version, info.Name), "")
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
		return c.step("cli", "ok", orUnknown(c.pr.cliVer)+" at "+c.pr.bench, "")
	}
	if c.target.cli != "" && c.target.cli != "benchbar" {
		return c.step("cli", "missing", missingCLIFix(c.target), "")
	}
	return c.step("cli", "missing", "benchbar is not on the PATH inside "+c.distro, "cli_install")
}

func (c *checker) lingerStep() setupStep {
	if !c.probed {
		return c.notChecked("linger")
	}
	switch c.pr.linger {
	case "yes":
		return c.step("linger", "ok", "enabled for "+c.pr.user, "")
	case "no":
		return c.step("linger", "missing", "off for "+c.pr.user+": benches stop when the last session ends", "linger")
	}
	return c.step("linger", "missing", "cannot read the linger setting of "+c.pr.user, "linger")
}

func (c *checker) keepaliveStep() setupStep {
	info := queryKeepalive(c.sys)
	checkKeepaliveTarget(&info, c.distro)
	k := info.Checks[0]
	if k.Status == "ok" {
		return c.step("keepalive", "ok", k.Message, "")
	}
	return c.step("keepalive", "missing", k.Message, "keepalive")
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
		return c.step("shim_path", "missing", k.Message, "path")
	}
	return c.step("shim_path", "missing", k.Message+": "+k.Fix, "")
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
				Detail: "waits for " + blocker, NeedsAdmin: false})
			continue
		}
		s := d.fn()
		s.Title = d.title
		rep.Steps = append(rep.Steps, s)
		if d.blocking && (s.Status == "missing" || s.Status == "fail") {
			blocker = d.id
		}
	}
	rep.RebootPending = c.reboot
	rep.Ready = !c.unchecked
	for _, s := range rep.Steps {
		if s.Status == "missing" || s.Status == "fail" {
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
	distro, err := setupDistro(sys, p.vals["--distro"])
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

func writeRebootMarker(sys *System) error {
	path := rebootMarkerPath(sys)
	if path == "" {
		return errors.New("LOCALAPPDATA is not set")
	}
	data, _ := json.Marshal(rebootMarker{RecordedAt: sys.Now().UTC().Format(time.RFC3339), Reason: "wsl_enable"})
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
