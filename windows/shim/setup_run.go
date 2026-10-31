package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode"
)

// --- the event stream ------------------------------------------------------

type stepEvent struct {
	Event   string `json:"event"`
	ID      string `json:"id"`
	Status  string `json:"status"` // running, done, failed, skipped
	Message string `json:"message"`
}

type logEvent struct {
	Event string `json:"event"`
	Line  string `json:"line"`
}

type doneEvent struct {
	Event          string   `json:"event"`
	Exit           int      `json:"exit"`
	Changed        bool     `json:"changed"`
	RebootRequired bool     `json:"reboot_required"`
	Cancelled      bool     `json:"cancelled"`
	Warnings       []string `json:"warnings"`
	NextActions    []string `json:"next_actions"`
	// UserExisted is set by distro_user only: true when the Linux user was
	// there already, so the typed password was not applied.
	UserExisted *bool `json:"user_existed,omitempty"`
	// ErrorID names why a failed action failed, when the caller can act on
	// it: "distro_running" (see setupError). Absent otherwise.
	ErrorID string `json:"error_id,omitempty"`
}

// errDistroRunning is the error_id of an action that would stop a distro
// that is running, without --force.
const errDistroRunning = "distro_running"

// setupError is a failure with an id for the done event.
type setupError struct{ id, msg string }

func (e *setupError) Error() string { return e.msg }

// emitter writes the event stream: JSON lines, or plain text for a person.
// It sends exactly one done event.
type emitter struct {
	mu       sync.Mutex
	w        io.Writer
	jsonl    bool
	doneSent bool
}

func (e *emitter) write(v any, text string) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.jsonl {
		b, _ := json.Marshal(v)
		e.w.Write(append(b, '\n'))
		return
	}
	fmt.Fprintln(e.w, text)
}

func (e *emitter) step(id, status, msg string) {
	e.write(stepEvent{"step", id, status, msg}, fmt.Sprintf("[%s] %s: %s", status, id, msg))
}

func (e *emitter) log(line string) {
	e.write(logEvent{"log", line}, "    "+line)
}

func (e *emitter) done(d doneEvent) {
	e.mu.Lock()
	if e.doneSent {
		e.mu.Unlock()
		return
	}
	e.doneSent = true
	e.mu.Unlock()
	d.Event = "done"
	if d.Warnings == nil {
		d.Warnings = []string{}
	}
	if d.NextActions == nil {
		d.NextActions = []string{}
	}
	e.write(d, fmt.Sprintf("done: exit %d, changed %v, restart needed %v", d.Exit, d.Changed, d.RebootRequired))
}

// lineWriter turns child output into log events, one per line. A carriage
// return ends a line too, so a progress bar does not become one long line.
type lineWriter struct {
	mu   sync.Mutex
	buf  []byte
	emit func(string)
}

func (w *lineWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.buf = append(w.buf, p...)
	for {
		i := strings.IndexAny(string(w.buf), "\r\n")
		if i < 0 {
			break
		}
		w.line(string(w.buf[:i]))
		w.buf = w.buf[i+1:]
	}
	return len(p), nil
}

func (w *lineWriter) line(s string) {
	s = strings.TrimSpace(strings.ReplaceAll(s, "\x00", ""))
	s = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) && r != '\t' {
			return -1
		}
		return r
	}, s)
	if s != "" {
		w.emit(s)
	}
}

func (w *lineWriter) Flush() {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.line(string(w.buf))
	w.buf = nil
}

// --- actions ---------------------------------------------------------------

// runCtx is what an action works with.
type runCtx struct {
	sys    *System
	em     *emitter
	distro string
	user   string
	force  bool // --force: allow stopping a running distro

	// wasRunning is whether the distro ran before the action touched it,
	// read first because the action's own commands start it.
	wasRunning bool

	// results
	msg         string // the finishing message
	skipped     bool
	changed     bool
	reboot      bool
	warnings    []string
	cancel      bool
	userExisted *bool
}

func (rc *runCtx) warn(s string) { rc.warnings = append(rc.warnings, s) }

type setupAction struct {
	title string
	run   func(*runCtx) error
	next  []string
}

// setupActions is the allow list of `setup run`. reboot is not here: the
// shim never restarts Windows, the tray asks the user.
var setupActions = map[string]setupAction{
	"wsl_enable":     {"Turn on WSL", actWslEnable, nil}, // next depends on reboot_required
	"wsl_update":     {"Update WSL", actWslUpdate, []string{"distro_install"}},
	"distro_install": {"Install the Linux distro", actDistroInstall, []string{"distro_user"}},
	"distro_user":    {"Create the Linux user", actDistroUser, []string{"systemd"}},
	"systemd":        {"Turn on systemd", actSystemd, []string{"cli_install"}},
	"cli_install":    {"Install the BenchBar command line tool", actCLIInstall, []string{"linger"}},
	"linger":         {"Keep benches running", actLinger, []string{"keepalive"}},
	"keepalive":      {"Keep the distro awake", actKeepalive, []string{"wslconfig"}},
	"wslconfig":      {"Set WSL idle settings", actWslconfigApply, []string{"path"}},
	"path":           {"Put benchbar.exe on PATH", actPath, []string{}},
}

func cmdSetupRun(sys *System, args []string) int {
	p, err := parseFlags(args, []string{"--jsonl", "--force"}, []string{"--distro", "--user"})
	em := &emitter{w: sys.Stdout, jsonl: p != nil && p.bools["--jsonl"]}
	fail := func(id, msg string) int {
		if em.jsonl {
			em.step(id, "failed", msg)
			em.done(doneEvent{Exit: 1})
		} else {
			errorf(sys, "%s. %s", msg, setupUsage)
		}
		return 1
	}
	if err != nil {
		return fail("setup", err.Error())
	}
	if len(p.pos) != 1 {
		return fail("setup", "setup run needs exactly one action")
	}
	id := p.pos[0]
	_, ok := setupActions[id]
	if !ok {
		return fail(id, fmt.Sprintf("unknown action %q", id))
	}
	distro, err := setupDistro(sys, p.vals["--distro"])
	if err != nil {
		return fail(id, err.Error())
	}
	user := p.vals["--user"]
	if user == "" {
		user = defaultLinuxUser(sys.User)
	}
	if id == "distro_user" && !validLinuxUser(user) {
		return fail(id, fmt.Sprintf("%q is not a usable Linux user name", user))
	}
	rc := &runCtx{sys: sys, em: em, distro: distro, user: user, force: p.bools["--force"]}
	if id == "wsl_enable" && !sys.Host.IsAdmin() {
		return runWslEnableElevated(rc)
	}
	return runAction(rc, id)
}

// runAction runs one action and sends the step events and the done event.
func runAction(rc *runCtx, id string) int {
	act := setupActions[id]
	rc.em.step(id, "running", act.title)
	if id == "distro_user" || id == "systemd" {
		rc.wasRunning = distroRunning(rc.sys, rc.distro)
	}
	err := act.run(rc)
	exit := 0
	errorID := ""
	var se *setupError
	if errors.As(err, &se) {
		errorID = se.id
	}
	next := act.next
	switch {
	case err != nil:
		exit = 1
		next = nil
		rc.em.step(id, "failed", err.Error())
	case rc.skipped:
		rc.em.step(id, "skipped", rc.msg)
	default:
		rc.em.step(id, "done", rc.msg)
	}
	if id == "wsl_enable" && err == nil {
		next = []string{"wsl_update"}
		if rc.reboot {
			next = []string{"reboot"}
		}
	}
	if id == "distro_install" && err == nil && rc.reboot {
		next = []string{"reboot"}
	}
	if rc.reboot && err == nil && (id == "wsl_enable" || id == "distro_install") {
		if werr := writeRebootMarker(rc.sys, id); werr != nil {
			rc.warn("could not remember that a restart is pending: " + werr.Error())
		}
	}
	rc.em.done(doneEvent{Exit: exit, Changed: rc.changed && err == nil, RebootRequired: rc.reboot && err == nil,
		Cancelled: rc.cancel, Warnings: rc.warnings, NextActions: next, UserExisted: rc.userExisted, ErrorID: errorID})
	return exit
}

// defaultLinuxUser is the Windows user name, lower case, cut to what Linux
// accepts: letters, digits, _ and -, not starting with a digit or a dash.
func defaultLinuxUser(winUser string) string {
	name := winUser
	if i := strings.LastIndexAny(name, `\/`); i >= 0 {
		name = name[i+1:]
	}
	var b strings.Builder
	for _, r := range strings.ToLower(name) {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == '_', r == '-':
			b.WriteRune(r)
		case r == ' ' || r == '.':
			b.WriteRune('_')
		}
	}
	s := b.String()
	if s != "" && (s[0] >= '0' && s[0] <= '9' || s[0] == '-') {
		s = "u" + s
	}
	if len(s) > 32 {
		s = s[:32]
	}
	if s == "" || s == "root" {
		return "bench"
	}
	return s
}

func validLinuxUser(s string) bool { return userNameRE.MatchString(s) && s != "root" }

// run streams a wsl.exe command as log events. It returns the exit code
// and every line the command printed.
func (rc *runCtx) stream(stdin string, args ...string) (int, []string, error) {
	cmd, err := wslCommand(rc.sys, args...)
	if err != nil {
		return 1, nil, err
	}
	var lines []string
	var mu sync.Mutex
	w := &lineWriter{emit: func(s string) {
		mu.Lock()
		if lines = append(lines, s); len(lines) > 400 {
			lines = lines[len(lines)-400:] // keep the newest
		}
		mu.Unlock()
		rc.em.log(s)
	}}
	cmd.Stdout, cmd.Stderr = w, w
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	if err := cmd.Start(); err != nil {
		return 1, nil, err
	}
	stop := attachKillOnClose(cmd.Process.Pid)
	werr := cmd.Wait()
	stop()
	w.Flush()
	if werr == nil {
		return 0, lines, nil
	}
	var ee interface{ ExitCode() int }
	if errors.As(werr, &ee) {
		return ee.ExitCode(), lines, nil
	}
	return 1, lines, werr
}

func lastLine(lines []string) string {
	if len(lines) == 0 {
		return ""
	}
	return lines[len(lines)-1]
}

// rebootCodes are ERROR_SUCCESS_REBOOT_REQUIRED (3010) and
// ERROR_SUCCESS_REBOOT_INITIATED (1641): the installer worked and Windows
// must restart. wsl.exe prints the system text for 3010.
func rebootCode(code int) bool { return code == 3010 || code == 1641 }

var rebootTextRE = regexp.MustCompile(`(?i)(not be effective until the system is rebooted|restart (is|will be) required|reboot (is )?required|restart (your|the) (computer|pc|system)|must (be )?restart)`)

func rebootText(lines []string) bool {
	return rebootTextRE.MatchString(strings.Join(lines, "\n"))
}

// --- wsl_enable ------------------------------------------------------------

func actWslEnable(rc *runCtx) error {
	if res, err := wslExec(rc.sys, "", "--status"); err == nil && res.Code == 0 {
		rc.skipped, rc.msg = true, "WSL is already enabled"
		return nil
	}
	code, lines, err := rc.stream("", "--install", "--no-distribution")
	if err != nil {
		return fmt.Errorf("cannot run wsl.exe: %v", err)
	}
	return rc.wslEnableResult(code, lines)
}

// wslEnableResult reads the outcome of `wsl.exe --install --no-distribution`:
// its exit code, the lines it printed (none when it ran elevated and hidden)
// and, when both are silent about a restart, whether WSL answers now. The
// generic Windows Update and CBS restart flags are not used: an unrelated
// update would block onboarding.
func (rc *runCtx) wslEnableResult(code int, lines []string) error {
	reboot := rebootCode(code)
	if code != 0 && !reboot {
		msg := fmt.Sprintf("wsl.exe --install --no-distribution failed with exit code %d", code)
		if l := lastLine(lines); l != "" {
			msg += ": " + l
		}
		return errors.New(msg)
	}
	rc.changed = true
	rc.msg = "WSL is turned on"
	if !reboot && rebootText(lines) {
		reboot = true
	}
	if !reboot {
		// the install said nothing about a restart; if WSL still does not
		// answer, Windows needs one before it can
		if res, err := wslExec(rc.sys, "", "--status"); err != nil || res.Code != 0 {
			reboot = true
			rc.warn("WSL does not answer yet, so Windows probably needs a restart")
		}
	}
	if reboot {
		rc.reboot = true
		rc.msg = "WSL is turned on; restart Windows to finish"
	}
	return nil
}

// --- wsl_update ------------------------------------------------------------

func wslVersionText(sys *System) string {
	res, err := wslExec(sys, "", "--version")
	if err != nil || res.Code != 0 {
		return ""
	}
	v, _ := wslVersionOK(res.Stdout)
	return v
}

func actWslUpdate(rc *runCtx) error {
	before := wslVersionText(rc.sys)
	rc.em.log("wsl.exe --update restarts WSL when it installs a new version")
	code, lines, err := rc.stream("", "--update")
	if err != nil {
		return fmt.Errorf("cannot run wsl.exe: %v", err)
	}
	if code != 0 {
		msg := fmt.Sprintf("wsl.exe --update failed with exit code %d", code)
		if l := lastLine(lines); l != "" {
			msg += ": " + l
		}
		return errors.New(msg)
	}
	after := wslVersionText(rc.sys)
	rc.changed = before != after
	rc.msg = "WSL is up to date"
	if after != "" {
		rc.msg = "WSL " + after + " is installed"
	}
	return nil
}

// --- distro_install --------------------------------------------------------

func registeredDistro(sys *System, name string) (*Distro, error) {
	list, err := sys.Distros.Distros()
	if err != nil {
		return nil, err
	}
	for i := range list {
		if strings.EqualFold(list[i].Name, name) {
			return &list[i], nil
		}
	}
	return nil, nil
}

// actDistroInstall installs the distro without the first run questions.
//
// `wsl.exe --install -d NAME --no-launch` downloads the distro and registers
// it (current WSL, where the distro is a .wsl archive) without opening a
// window; the default user stays root. The out of box setup that asks for a
// user name runs only "the first time the user opens an interactive shell"
// (Microsoft's custom distro guide), so the non interactive
// `wsl.exe -d NAME -u root --exec /bin/true` below registers nothing new and
// proves the distro starts, and distro_user creates the user afterwards.
func actDistroInstall(rc *runCtx) error {
	d, err := registeredDistro(rc.sys, rc.distro)
	if err != nil {
		return fmt.Errorf("cannot read the WSL registry: %v", err)
	}
	changed := false
	if d == nil {
		code, lines, err := rc.stream("", "--install", "-d", rc.distro, "--no-launch")
		if err != nil {
			return fmt.Errorf("cannot run wsl.exe: %v", err)
		}
		if rebootCode(code) {
			rc.reboot = true
			rc.msg = "restart Windows, then install the distro again"
			return nil
		}
		if code != 0 {
			msg := fmt.Sprintf("wsl.exe --install -d %s failed with exit code %d", rc.distro, code)
			if l := lastLine(lines); l != "" {
				msg += ": " + l
			}
			return errors.New(msg)
		}
		changed = true
		if d, err = registeredDistro(rc.sys, rc.distro); err != nil || d == nil {
			return fmt.Errorf("wsl.exe did not register %s; update WSL (setup run wsl_update) and try again", rc.distro)
		}
	}
	res, err := wslExec(rc.sys, "", "-d", rc.distro, "-u", "root", "--exec", "/bin/true")
	if err != nil || res.Code != 0 {
		detail := res.text()
		if err != nil {
			detail = err.Error()
		}
		return fmt.Errorf("%s is installed but does not start: %s", rc.distro, detail)
	}
	if d.Version != 2 {
		rc.warn(fmt.Sprintf("%s runs as WSL %d; benches need WSL 2 (wsl.exe --set-version %s 2)", d.Name, d.Version, d.Name))
	}
	cfg, err := loadConfig(rc.sys)
	if err == nil {
		if cfg.str("distro") != d.Name {
			changed = true
		}
		cfg.setStr("distro", d.Name)
		err = cfg.save()
	}
	if err != nil {
		return fmt.Errorf("cannot record the distro: %v", err)
	}
	clearRebootMarker(rc.sys)
	rc.changed = changed
	rc.skipped = !changed
	rc.msg = rc.distro + " is installed"
	if rc.skipped {
		rc.msg = rc.distro + " is already installed"
	}
	return nil
}

// --- inside the distro as root --------------------------------------------

// asRoot runs a program in the distro as root, with no shell unless the
// caller passes one. Root through wsl.exe needs no password and no sudo.
func (rc *runCtx) asRoot(stdin string, argv ...string) (wslResult, error) {
	args := append([]string{"-d", rc.distro, "-u", "root", "--exec"}, argv...)
	return wslExec(rc.sys, stdin, args...)
}

func (rc *runCtx) rootFail(what string, res wslResult, err error) error {
	if err != nil {
		return fmt.Errorf("%s: %v", what, err)
	}
	msg := fmt.Sprintf("%s: exit code %d", what, res.Code)
	if t := lastLine(strings.Split(res.text(), "\n")); t != "" {
		msg += ": " + t
	}
	return errors.New(msg)
}

// readWslConf returns /etc/wsl.conf; a missing file is an empty one.
func (rc *runCtx) readWslConf() (string, error) {
	res, err := rc.asRoot("", "/bin/sh", "-c", `if [ -e "$0" ]; then cat "$0"; else exit 3; fi`, "/etc/wsl.conf")
	if err == nil && res.Code == 3 {
		return "", nil
	}
	if err != nil || res.Code != 0 {
		return "", rc.rootFail("cannot read /etc/wsl.conf", res, err)
	}
	return res.Stdout, nil
}

// setWslConf sets one key in /etc/wsl.conf and keeps the rest of the file.
// A copy of the old file is made first. It returns false when the key
// already had the value, and then writes nothing.
func (rc *runCtx) setWslConf(section, key, value string) (bool, error) {
	old, err := rc.readWslConf()
	if err != nil {
		return false, err
	}
	f := parseINI([]byte(old))
	if cur, ok := f.get(section, key); ok && cur == value {
		return false, nil
	}
	f.set(section, key, value)
	out := string(f.render())
	if !strings.Contains(old, "\r\n") {
		out = strings.ReplaceAll(out, "\r\n", "\n") // the file is for Linux
	}
	// The name holds the time and this process id, and a name that exists
	// is never reused: the first backup (the original file) stays.
	stamp := fmt.Sprintf("%s-%d", rc.sys.Now().Format("20060102-150405"), rc.sys.Pid)
	res, err := rc.asRoot("", "/bin/sh", "-c", backupScript, "/etc/wsl.conf", stamp)
	if err != nil || res.Code != 0 {
		return false, rc.rootFail("cannot back up /etc/wsl.conf", res, err)
	}
	res, err = rc.asRoot(out, "/bin/sh", "-c", `cat > "$0.benchbar-new" && mv "$0.benchbar-new" "$0"`, "/etc/wsl.conf")
	if err != nil || res.Code != 0 {
		return false, rc.rootFail("cannot write /etc/wsl.conf", res, err)
	}
	return true, nil
}

// distroRunning is whether the distro runs now. Like setup check it asks the
// quiet running list, so it never starts anything.
func distroRunning(sys *System, name string) bool {
	for _, n := range runningNames(sys) {
		if strings.EqualFold(n, name) {
			return true
		}
	}
	return false
}

// refuseRunning stops an action that would restart a distro that was
// running when it began, unless --force was given. What runs in it (benches,
// MariaDB) stops with it.
func (rc *runCtx) refuseRunning() error {
	if !rc.wasRunning || rc.force {
		return nil
	}
	return &setupError{errDistroRunning, rc.distro + " is running. This change restarts it and stops everything inside it, such as your benches and MariaDB. Stop them first (benchbar down), or run this action again with --force."}
}

// confDiffers is whether /etc/wsl.conf lacks section.key = value.
func (rc *runCtx) confDiffers(section, key, value string) (bool, error) {
	old, err := rc.readWslConf()
	if err != nil {
		return false, err
	}
	cur, ok := parseINI([]byte(old)).get(section, key)
	return !ok || cur != value, nil
}

// terminate stops this one distro, so /etc/wsl.conf is read at its next
// start. It never touches other distros and never shuts WSL down.
func (rc *runCtx) terminate() error {
	res, err := wslExec(rc.sys, "", "--terminate", rc.distro)
	if err != nil || res.Code != 0 {
		return rc.rootFail("cannot stop "+rc.distro, res, err)
	}
	return nil
}

// --- distro_user -----------------------------------------------------------

func actDistroUser(rc *runCtx) error {
	user := rc.user
	// the password comes from the environment, never from a command line
	pw := rc.sys.Getenv("BENCHBAR_SETUP_PASSWORD")
	res, err := rc.asRoot("", "/usr/bin/id", "-u", user)
	if err != nil {
		return fmt.Errorf("cannot run wsl.exe: %v", err)
	}
	exists := res.Code == 0
	rc.userExisted = &exists
	if exists && strings.TrimSpace(res.Stdout) == "0" {
		return errors.New("that user is root")
	}
	// decide before anything is created: a refusal must change nothing
	if need, err := rc.confDiffers("user", "default", user); err != nil {
		return err
	} else if need {
		if err := rc.refuseRunning(); err != nil {
			return err
		}
	}
	if !exists {
		switch {
		case pw == "":
			return errors.New("BENCHBAR_SETUP_PASSWORD is not set")
		case strings.ContainsAny(pw, "\r\n\x00"):
			return errors.New("the password cannot contain a line break")
		}
		if res, err := rc.asRoot("", "/usr/sbin/useradd", "-m", "-s", "/bin/bash", "-G", "sudo", user); err != nil || res.Code != 0 {
			return rc.rootFail("cannot create the user "+user, res, err)
		}
		// chpasswd reads "user:password" on stdin
		if res, err := rc.asRoot(user+":"+pw+"\n", "/usr/sbin/chpasswd"); err != nil || res.Code != 0 {
			return rc.rootFail("cannot set the password of "+user, wslResult{Code: res.Code}, err)
		}
		rc.changed = true
	} else {
		rc.em.log(user + " exists already; its password is not changed")
		if res, err := rc.asRoot("", "/usr/sbin/usermod", "-aG", "sudo", user); err != nil || res.Code != 0 {
			return rc.rootFail("cannot add "+user+" to the sudo group", res, err)
		}
	}
	changed, err := rc.setWslConf("user", "default", user)
	if err != nil {
		return err
	}
	if changed {
		rc.changed = true
		rc.em.log("stopping " + rc.distro + " so the default user takes effect (other distros keep running)")
		if err := rc.terminate(); err != nil {
			return err
		}
	}
	rc.skipped = !rc.changed
	rc.msg = user + " is the default user of " + rc.distro
	return nil
}

// --- systemd ---------------------------------------------------------------

func (rc *runCtx) pid1() string {
	res, err := wslExec(rc.sys, "", "-d", rc.distro, "--exec", "/bin/cat", "/proc/1/comm")
	if err != nil || res.Code != 0 {
		return ""
	}
	return strings.TrimSpace(res.Stdout)
}

func actSystemd(rc *runCtx) error {
	differs, err := rc.confDiffers("boot", "systemd", "true")
	if err != nil {
		return err
	}
	if !differs && rc.pid1() == "systemd" {
		rc.skipped, rc.msg = true, "systemd is already running"
		return nil
	}
	if err := rc.refuseRunning(); err != nil {
		return err
	}
	if _, err := rc.setWslConf("boot", "systemd", "true"); err != nil {
		return err
	}
	rc.em.log("stopping " + rc.distro + " so systemd starts (other distros keep running)")
	if err := rc.terminate(); err != nil {
		return err
	}
	pid1 := ""
	for i := 0; i < 15; i++ {
		if pid1 = rc.pid1(); pid1 == "systemd" {
			break
		}
		rc.sys.Sleep(rc.sys.Ctx, 2*time.Second)
	}
	if pid1 != "systemd" {
		return fmt.Errorf("%s restarted but PID 1 is %q, not systemd", rc.distro, pid1)
	}
	rc.changed = true
	rc.msg = "systemd runs as PID 1 in " + rc.distro
	return nil
}

// --- cli_install -----------------------------------------------------------

func actCLIInstall(rc *runCtx) error {
	t := target{distro: rc.distro, cli: "benchbar"}
	if cfg, err := loadConfig(rc.sys); err == nil {
		if c := cfg.str("cli_path"); c != "" {
			t.cli = c
		}
	}
	pr, err := runProbeScript(rc.sys, rc.distro, t.cli, setupProbeScript)
	if err != nil {
		return fmt.Errorf("cannot run a command in %s: %v", rc.distro, err)
	}
	if pr.uid == "0" {
		return errors.New("the default user of " + rc.distro + " is root; create the Linux user first (distro_user)")
	}
	if pr.bench != "" {
		rc.skipped, rc.msg = true, "benchbar is already installed: "+orUnknown(pr.cliVer)
		return nil
	}
	if t.cli != "benchbar" {
		return errors.New(missingCLIFix(t))
	}
	script := "curl -fsSL " + installerURL + " | bash"
	code, lines, err := rc.stream("", "-d", rc.distro, "--cd", "~", "--exec", "/bin/bash", "-c", script)
	if err != nil {
		return fmt.Errorf("cannot run wsl.exe: %v", err)
	}
	if code != 0 {
		msg := fmt.Sprintf("the installer failed with exit code %d", code)
		if l := lastLine(lines); l != "" {
			msg += ": " + l
		}
		return errors.New(msg)
	}
	// curl | bash hides a failed download, so look for the result
	pr, err = runProbeScript(rc.sys, rc.distro, t.cli, setupProbeScript)
	if err != nil || pr.bench == "" {
		return errors.New("the installer finished, but benchbar is not on the PATH in " + rc.distro)
	}
	rc.changed = true
	rc.msg = "installed " + orUnknown(pr.cliVer)
	return nil
}

// --- linger, keepalive, wslconfig, path ------------------------------------

func actLinger(rc *runCtx) error {
	t := target{distro: rc.distro, cli: "benchbar"}
	if tt, err := resolveTarget(rc.sys, rc.distro); err == nil && tt.prob == nil {
		t = tt
	}
	pr, err := runProbeScript(rc.sys, rc.distro, t.cli, setupProbeScript)
	if err != nil {
		return fmt.Errorf("cannot run a command in %s: %v", rc.distro, err)
	}
	if pr.user == "" || pr.uid == "0" {
		return errors.New("the default user of " + rc.distro + " is root; create the Linux user first (distro_user)")
	}
	if pr.linger == "yes" {
		rc.skipped, rc.msg = true, "linger is already on for "+pr.user
		return nil
	}
	// root may change linger without the polkit question a normal user gets
	if res, err := rc.asRoot("", "/usr/bin/loginctl", "enable-linger", pr.user); err != nil || res.Code != 0 {
		return rc.rootFail("cannot enable linger for "+pr.user+" (is systemd running?)", res, err)
	}
	after, err := runProbeScript(rc.sys, rc.distro, t.cli, setupProbeScript)
	if err != nil || after.linger != "yes" {
		return errors.New("linger is still off for " + pr.user)
	}
	rc.changed = true
	rc.msg = "linger is on for " + pr.user
	return nil
}

// captured runs a shim command with its output sent to log events.
func (rc *runCtx) captured(fn func(*System) int) (int, string) {
	var lines []string
	w := &lineWriter{emit: func(s string) {
		lines = append(lines, s)
		rc.em.log(s)
	}}
	sub := *rc.sys
	sub.Stdout, sub.Stderr = w, w
	code := fn(&sub)
	w.Flush()
	return code, lastLine(lines)
}

func actKeepalive(rc *runCtx) error {
	info := queryKeepalive(rc.sys)
	checkKeepaliveTarget(&info, rc.distro)
	if info.Checks[0].Status == "ok" {
		rc.skipped, rc.msg = true, "the keepalive task already runs for "+rc.distro
		return nil
	}
	code, last := rc.captured(func(s *System) int { return keepaliveInstall(s, rc.distro) })
	if code != 0 {
		return errors.New("keepalive install failed: " + last)
	}
	rc.changed = true
	rc.msg = "the keepalive task is installed and started"
	return nil
}

func actWslconfigApply(rc *runCtx) error {
	_, rep, err := readWslconfig(rc.sys)
	if err != nil {
		return err
	}
	if len(rep.Suggest) == 0 {
		rc.skipped, rc.msg = true, ".wslconfig needs no change"
		return nil
	}
	code, last := rc.captured(func(s *System) int { return cmdWslconfig(s, []string{"--apply", "--yes"}) })
	if code != 0 {
		return errors.New("wslconfig --apply failed: " + last)
	}
	rc.changed = true
	rc.msg = ".wslconfig is updated"
	rc.warn("WSL reads .wslconfig when it restarts; benchbar.exe does not run wsl.exe --shutdown")
	return nil
}

func actPath(rc *runCtx) error {
	if c := pathCheck(rc.sys); c.Status == "ok" {
		rc.skipped, rc.msg = true, "benchbar.exe is already first on PATH"
		return nil
	}
	code, _ := rc.captured(func(s *System) int { return cmdPath(s, "install") })
	if code != 0 {
		return errors.New("path install failed")
	}
	if c := pathCheck(rc.sys); c.Status != "ok" {
		msg := c.Message
		if c.Fix != "" && c.Fix != "benchbar.exe path install" {
			msg += ": " + c.Fix
		}
		return errors.New(msg)
	}
	rc.changed = true
	rc.msg = "benchbar.exe is on your user PATH; new terminals pick it up"
	return nil
}

// backupScript copies $0 to $0.benchbar-backup-$1, or with -N added when
// that name is taken. Nothing is overwritten.
const backupScript = `if [ -e "$0" ]; then b="$0.benchbar-backup-$1"; n=0; while [ -e "$b" ]; do n=$((n+1)); b="$0.benchbar-backup-$1-$n"; done; cp -p "$0" "$b"; fi`
