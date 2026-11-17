package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"regexp"
	"strings"
	"sync"
	"time"
)

// benchbar.exe self-update updates the installed BenchBar for Windows
// (benchbar.exe and the tray) with the one line installer, then the CLI in
// the distro with the new benchbar.exe, so the three are the same release.
// The installer is the engine: what it downloads carries no internet mark,
// it checks the zip against the release's SHA256 sums, moves files that are
// in use aside to NAME.old and closes and restarts the tray.

const selfUpdateHelp = `Usage: benchbar.exe self-update [--check] [--json] [--yes] [--version X.Y.Z | --zip PATH] [--installer FILE] [--dry-run]
       benchbar.exe self-update --cli [ARGS]

Updates BenchBar for Windows: benchbar.exe and the tray app with the one line
installer, then the BenchBar CLI in WSL to the same release. It shows the plan
and asks first. Your settings, benches and sites stay as they are.

  --check          this version against the latest release, changes nothing
  --json           the check as one JSON document (implies --check)
  --yes            do not ask
  --version X.Y.Z  install this release (also an older one) instead of the latest
  --zip PATH       install this benchbar-windows-VERSION-ARCH.zip (a test build)
  --installer FILE use this install.ps1 instead of the one on GitHub (for tests)
  --dry-run        the plan and the command, nothing runs
  --cli [ARGS]     only the CLI's own self-update inside WSL (benchbar.exe and
                   the tray stay as they are)`

const selfUpdateUsage = "usage: benchbar.exe self-update [--check] [--json] [--yes] [--version X.Y.Z | --zip PATH] [--installer FILE] [--dry-run], or self-update --cli ARGS for the CLI's own self-update in WSL"

// cliCheckTimeout bounds each wsl.exe call of the check's CLI part. A
// variable so a test can shorten it.
var cliCheckTimeout = 15 * time.Second

// installerEnvDropped are the install.ps1 variables a user may have left
// set in the shell (the docs tell iex users to set them). The installer
// gets its choices on the command line only, so none of them can change
// what is installed, or turn an update into an uninstall.
var installerEnvDropped = []string{
	"BENCHBAR_VERSION", "BENCHBAR_ZIP", "BENCHBAR_SOURCE", "BENCHBAR_UNINSTALL", "BENCHBAR_NO_TRAY", "BENCHBAR_YES",
}

var zipNameRE = regexp.MustCompile(`^benchbar-windows-(\d+\.\d+\.\d+)-(amd64|arm64)\.zip$`)

type suOpts struct {
	check, asJSON, yes, dryRun bool
	version, zip, installer    string
}

func cmdSelfUpdate(sys *System, args []string) int {
	for i, a := range args {
		if a == "--cli" {
			rest := append(append([]string{}, args[:i]...), args[i+1:]...)
			return selfUpdateCLIOnly(sys, rest)
		}
	}
	if hasAny(args, "-h", "--help", "help") {
		fmt.Fprintln(sys.Stdout, selfUpdateHelp)
		return 0
	}
	p, err := parseFlags(args, []string{"--check", "--json", "--yes", "--dry-run"}, []string{"--version", "--zip", "--installer"})
	if err == nil && len(p.pos) > 0 {
		err = fmt.Errorf("unexpected argument %s", p.pos[0])
	}
	if err != nil {
		errorf(sys, "%v. %s", err, selfUpdateUsage)
		return 1
	}
	o := suOpts{check: p.bools["--check"], asJSON: p.bools["--json"], yes: p.bools["--yes"], dryRun: p.bools["--dry-run"],
		version: p.vals["--version"], zip: p.vals["--zip"], installer: p.vals["--installer"]}
	if o.check || o.asJSON {
		return selfUpdateCheck(sys, o.asJSON)
	}
	return selfUpdateRun(sys, o)
}

// selfUpdateCLIOnly is the CLI's own self-update, forwarded as it is. It
// says first that it leaves the Windows side alone, so no one updates one
// side by accident.
func selfUpdateCLIOnly(sys *System, rest []string) int {
	fmt.Fprintf(sys.Stderr, "benchbar.exe: --cli runs the CLI's own self-update inside WSL. It updates only that CLI; benchbar.exe %s and the tray app stay as they are. To update all of BenchBar for Windows: benchbar.exe self-update\n", version)
	return cmdForward(sys, append([]string{"self-update"}, rest...))
}

// --- how this copy was installed --------------------------------------------

// installKind is "installer" for the copy in %LOCALAPPDATA%\Programs\BenchBar,
// "store" for a Microsoft Store (MSIX) package and "other" for any other
// copy (a dev build, an unpacked zip). dir is the installer's folder.
func installKind(sys *System) (kind, dir string) {
	if local := strings.TrimRight(sys.Getenv("LOCALAPPDATA"), `\/`); local != "" {
		dir = local + `\Programs\BenchBar`
	}
	// a packaged program always runs from C:\Program Files\WindowsApps
	if strings.Contains(strings.ToLower(strings.ReplaceAll(sys.ExePath, "/", `\`)), `\windowsapps\`) {
		return "store", dir
	}
	if dir != "" && normDir(parentDir(sys.ExePath), sys.Getenv) == normDir(dir, sys.Getenv) {
		return "installer", dir
	}
	return "other", dir
}

func parentDir(p string) string {
	if i := strings.LastIndexAny(p, `\/`); i >= 0 {
		return p[:i]
	}
	return ""
}

func archOf(sys *System) string {
	if sys.MachineArch != nil {
		if a := sys.MachineArch(); a == "amd64" || a == "arm64" {
			return a
		}
	}
	return "amd64"
}

// --- the check ---------------------------------------------------------------

// selfUpdateReport is the document of self-update --check --json. The tray
// reads current, latest, update_available, install and error.
type selfUpdateReport struct {
	SchemaVersion   int             `json:"schema_version"`
	Current         string          `json:"current"`
	Latest          *string         `json:"latest"`
	UpdateAvailable bool            `json:"update_available"`
	Install         string          `json:"install"`
	Exe             string          `json:"exe"`
	InstallDir      string          `json:"install_dir"`
	Arch            string          `json:"arch"`
	ReleaseURL      *string         `json:"release_url"`
	LatestSource    *string         `json:"latest_source"`
	Command         *string         `json:"command"`
	Notes           []string        `json:"notes"`
	Error           *string         `json:"error"`
	CLIDistro       *string         `json:"cli_distro"`
	CLI             json.RawMessage `json:"cli"`
	CLIError        *string         `json:"cli_error"`
}

func buildSelfUpdateReport(sys *System) selfUpdateReport {
	kind, dir := installKind(sys)
	arch := archOf(sys)
	r := selfUpdateReport{SchemaVersion: 1, Current: version, Install: kind, Exe: sys.ExePath, InstallDir: dir, Arch: arch, Notes: []string{}}

	// the CLI is asked at the same time; it never makes the check fail
	var wg sync.WaitGroup
	var cliDistro, cliErr string
	var cliDoc json.RawMessage
	wg.Add(1)
	go func() {
		defer wg.Done()
		cliDistro, cliDoc, cliErr = askCLICheck(sys)
	}()
	rel, err := findLatest(sys, arch)
	wg.Wait()

	if err != nil {
		r.Error = strp(err.Error())
	} else {
		r.Latest, r.ReleaseURL, r.LatestSource = strp(rel.Version), strp(rel.URL), strp(rel.Source)
		r.UpdateAvailable = newerVersion(version, rel.Version)
		if rel.Note != "" {
			r.Notes = append(r.Notes, rel.Note)
		}
	}
	switch kind {
	case "installer":
		if r.UpdateAvailable {
			r.Command = strp("benchbar.exe self-update")
		}
	case "store":
		r.Notes = append(r.Notes, "this benchbar.exe comes from the Microsoft Store, which updates it and the tray app")
	default:
		where := `%LOCALAPPDATA%\Programs\BenchBar`
		if dir != "" {
			where = dir
		}
		r.Notes = append(r.Notes, fmt.Sprintf("this benchbar.exe is not the installed copy in %s, so self-update does not update it", where))
	}
	if !releaseRE.MatchString(version) {
		r.Notes = append(r.Notes, "this benchbar.exe is a development build, not a release")
	}
	if cliDistro != "" {
		r.CLIDistro = strp(cliDistro)
	}
	r.CLI = cliDoc
	if cliErr != "" {
		r.CLIError = strp(cliErr)
	}
	return r
}

// askCLICheck asks the CLI in the distro for its own self-update --check
// --json, only when the distro already runs (a check never starts one) and
// only within cliCheckTimeout per call.
func askCLICheck(sys *System) (distro string, doc json.RawMessage, problemText string) {
	t, err := resolveTarget(sys, "")
	if err != nil {
		return "", nil, err.Error()
	}
	if t.prob != nil {
		return "", nil, t.prob.Msg
	}
	if t.distro == "" {
		return "", nil, "no WSL distro is known"
	}
	run, err := wslExecTimeout(sys, cliCheckTimeout, "", "--list", "--running", "--quiet")
	if err != nil || run.Code != 0 {
		return t.distro, nil, "WSL did not answer"
	}
	running := false
	for _, l := range strings.Split(run.Stdout, "\n") {
		running = running || strings.EqualFold(strings.TrimSpace(l), t.distro)
	}
	if !running {
		return t.distro, nil, t.distro + " is not running, and a check does not start it"
	}
	res, err := wslExecTimeout(sys, cliCheckTimeout, "", forwardArgs(t.distro, t.cli, []string{"self-update", "--check", "--json"})...)
	if isWslTimeout(err) {
		return t.distro, nil, fmt.Sprintf("the CLI in %s did not answer within %d s", t.distro, int(cliCheckTimeout.Seconds()))
	}
	if err != nil {
		return t.distro, nil, err.Error()
	}
	// the CLI prints one document; exit 1 with a document is its own error
	out := strings.TrimSpace(res.Stdout)
	if i := strings.LastIndex(out, "\n"); i >= 0 {
		out = strings.TrimSpace(out[i+1:])
	}
	if strings.HasPrefix(out, "{") && json.Valid([]byte(out)) {
		return t.distro, json.RawMessage(out), ""
	}
	if res.Code == 127 {
		return t.distro, nil, t.cli + " is not installed in " + t.distro
	}
	return t.distro, nil, fmt.Sprintf("the CLI in %s gave no JSON (exit code %d)", t.distro, res.Code)
}

func selfUpdateCheck(sys *System, asJSON bool) int {
	r := buildSelfUpdateReport(sys)
	if asJSON {
		printJSON(sys.Stdout, r)
		return 0
	}
	w := sys.Stdout
	switch r.Install {
	case "installer":
		fmt.Fprintf(w, "benchbar.exe %s, installed by the one line installer in %s\n", r.Current, r.InstallDir)
	case "store":
		fmt.Fprintf(w, "benchbar.exe %s, from the Microsoft Store\n", r.Current)
	default:
		fmt.Fprintf(w, "benchbar.exe %s at %s (not the installed copy)\n", r.Current, r.Exe)
	}
	if r.Error != nil {
		fmt.Fprintf(w, "Latest release: unknown: %s\n", *r.Error)
	} else {
		fmt.Fprintf(w, "Latest release with a Windows build for %s: %s (%s)\n", r.Arch, *r.Latest, *r.ReleaseURL)
		switch {
		case r.UpdateAvailable && r.Command != nil:
			fmt.Fprintf(w, "An update is available: %s\n", *r.Command)
		case r.UpdateAvailable:
			fmt.Fprintln(w, "An update is available.")
		default:
			fmt.Fprintln(w, "BenchBar for Windows is up to date.")
		}
	}
	for _, n := range r.Notes {
		fmt.Fprintf(w, "Note: %s\n", n)
	}
	fmt.Fprintln(w, cliCheckLine(r))
	if r.Error != nil {
		return 1
	}
	return 0
}

// cliCheckLine is the CLI part of the check in one line.
func cliCheckLine(r selfUpdateReport) string {
	label := "CLI in WSL"
	if r.CLIDistro != nil {
		label += " (" + *r.CLIDistro + ")"
	}
	if r.CLI == nil {
		reason := "not asked"
		if r.CLIError != nil {
			reason = *r.CLIError
		}
		return label + ": unknown: " + reason
	}
	var doc struct {
		Current string  `json:"current"`
		Latest  *string `json:"latest"`
	}
	json.Unmarshal(r.CLI, &doc)
	line := label + ": " + orUnknown(doc.Current)
	if doc.Current != "" && releaseRE.MatchString(version) && doc.Current != version {
		line += fmt.Sprintf(", benchbar.exe is %s: benchbar.exe self-update brings both to the same release", version)
	}
	return line
}

// --- the update ----------------------------------------------------------------

func selfUpdateRun(sys *System, o suOpts) int {
	kind, dir := installKind(sys)
	switch kind {
	case "store":
		fmt.Fprintln(sys.Stdout, "This benchbar.exe comes from the Microsoft Store, which updates it and the tray app (Microsoft Store > Library > Get updates). Nothing was changed.")
		return 0
	case "other":
		where := `%LOCALAPPDATA%\Programs\BenchBar\benchbar.exe`
		if dir != "" {
			where = dir + `\benchbar.exe`
		}
		(&problem{
			Msg: fmt.Sprintf("self-update updates the installed copy (%s), and this one is %s, so nothing was changed", where, sys.ExePath),
			Fix: fmt.Sprintf(`run "%s" self-update, or install with: %s`, where, oneLineInstall),
		}).print(sys)
		return 1
	}
	if o.version != "" && o.zip != "" {
		errorf(sys, "--version and --zip do not go together. %s", selfUpdateUsage)
		return 1
	}
	newExe := dir + `\benchbar.exe`
	trayExe := dir + `\BenchBarTray.exe`

	target := ""
	switch {
	case o.zip != "":
		m := zipNameRE.FindStringSubmatch(baseName(o.zip))
		if m == nil {
			errorf(sys, "'%s' is not a BenchBar Windows zip (benchbar-windows-X.Y.Z-ARCH.zip)", o.zip)
			return 1
		}
		target = m[1]
	case o.version != "":
		if !plainVersionRE.MatchString(o.version) {
			errorf(sys, "'%s' is not a version. fix: use X.Y.Z, for example --version 0.8.3", o.version)
			return 1
		}
		target = strings.TrimPrefix(o.version, "v")
	default:
		if !releaseRE.MatchString(version) {
			(&problem{Msg: "this benchbar.exe is a development build (" + version + "), so there is no newer release to compare with",
				Fix: "name a release: benchbar.exe self-update --version X.Y.Z"}).print(sys)
			return 1
		}
		rel, err := findLatest(sys, archOf(sys))
		if err != nil {
			(&problem{Msg: "could not find the latest release: " + err.Error(),
				Fix: "try again later, or name a release: benchbar.exe self-update --version X.Y.Z (see " + releasesPageURL + ")"}).print(sys)
			return 1
		}
		if rel.Note != "" {
			fmt.Fprintf(sys.Stdout, "Note: %s.\n", rel.Note)
		}
		if !newerVersion(version, rel.Version) {
			return selfUpdateUpToDate(sys, o, rel.Version)
		}
		target = rel.Version
	}

	noTray := !sys.FileExists(trayExe)
	distro, skip := cliTarget(sys)
	script := installerScript(o, target, noTray)
	ps, perr := "powershell.exe", error(nil)
	if sys.PowerShellPath != nil {
		ps, perr = sys.PowerShellPath()
	}

	w := sys.Stdout
	fmt.Fprintf(w, "BenchBar for Windows %s is installed in %s.\n", version, dir)
	fmt.Fprintf(w, "This installs %s%s:\n", target, relation(target))
	if noTray {
		fmt.Fprintln(w, "  1. The one line installer updates benchbar.exe (this install has no tray app).")
	} else {
		fmt.Fprintln(w, "  1. The one line installer updates benchbar.exe and the tray app. The tray app closes and starts again.")
	}
	if skip == "" {
		fmt.Fprintf(w, "  2. The new benchbar.exe updates the BenchBar CLI in WSL (%s) to the same release.\n", distro)
	} else {
		fmt.Fprintf(w, "  2. The BenchBar CLI in WSL is skipped: %s.\n", skip)
	}
	fmt.Fprintln(w, "  Your settings, benches and sites stay as they are.")
	fmt.Fprintf(w, "  runs: %s\n", printableCommand(ps, script))
	if o.dryRun {
		fmt.Fprintln(w, "dry-run: nothing was run")
		return 0
	}
	if perr != nil || sys.Launch == nil {
		errorf(sys, "Windows PowerShell was not found: %v", perr)
		return 1
	}
	if !o.yes {
		if !sys.StdinIsTerminal || sys.Getenv("BENCHBAR_NONINTERACTIVE") == "1" {
			(&problem{Msg: "self-update asks before it changes anything, and there is no terminal to answer on, so nothing was changed",
				Fix: "benchbar.exe self-update --yes"}).print(sys)
			return 1
		}
		fmt.Fprintf(w, "Update BenchBar for Windows to %s now? [y/N] ", target)
		line, _ := bufio.NewReader(sys.Stdin).ReadString('\n')
		if a := strings.ToLower(strings.TrimSpace(line)); a != "y" && a != "yes" {
			fmt.Fprintln(w, "Cancelled. Nothing was changed. Later: benchbar.exe self-update")
			return 1
		}
	}

	trayBefore, trayKnown := trayProcesses(sys, trayExe)
	fmt.Fprintf(w, "\nRunning the installer for %s.\n", target)
	var summary []string
	code, err := sys.Launch.Run(sys.Ctx, LaunchSpec{
		Path: ps, Args: installerArgs(script), Env: installerEnv(sys), Stdout: sys.Stdout, Stderr: sys.Stderr,
	})
	winOK := false
	switch {
	case err != nil:
		summary = append(summary, "Windows programs: failed: Windows PowerShell could not be started: "+err.Error())
	case code != 0:
		summary = append(summary, fmt.Sprintf("Windows programs: failed: the installer exited with %d (the lines above say why)", code))
	default:
		got, verr := exeVersion(sys, newExe)
		switch {
		case verr != nil:
			summary = append(summary, fmt.Sprintf("Windows programs: failed: the installer finished, but the new benchbar.exe did not start (%v). An antivirus may have blocked it: see Windows Security > Protection history", verr))
		case got != target:
			summary = append(summary, fmt.Sprintf("Windows programs: failed: the installer finished, but benchbar.exe reports %s, not %s", orUnknown(got), target))
		default:
			winOK = true
			if got == version {
				summary = append(summary, "Windows programs: "+target+" installed again")
			} else {
				summary = append(summary, fmt.Sprintf("Windows programs: updated from %s to %s", version, target))
			}
		}
	}
	summary = append(summary, trayLine(sys, trayExe, trayBefore, trayKnown, winOK))
	cliFailed := false
	if winOK {
		if l := restartKeepalive(sys, newExe); l != "" {
			summary = append(summary, l)
		}
		l, failed := cliStepLine(sys, newExe, distro, skip)
		summary = append(summary, l)
		cliFailed = failed
	} else {
		summary = append(summary, "CLI in WSL: not updated, because the Windows part failed")
	}
	printUpdateSummary(sys, summary)
	if !winOK || cliFailed {
		return 1
	}
	return 0
}

// selfUpdateUpToDate is the run when Windows has the newest release: the
// CLI in the distro may still be older than benchbar.exe, so that part runs.
func selfUpdateUpToDate(sys *System, o suOpts, latest string) int {
	fmt.Fprintf(sys.Stdout, "BenchBar for Windows %s is up to date (the newest release with a Windows build for this PC is %s).\n", version, latest)
	distro, skip := cliTarget(sys)
	if o.dryRun {
		if skip == "" {
			fmt.Fprintf(sys.Stdout, "  runs: benchbar.exe setup run cli_install --distro %s (it updates the CLI in WSL when it is older than benchbar.exe)\n", quoteArg(distro))
		}
		fmt.Fprintln(sys.Stdout, "dry-run: nothing was run")
		return 0
	}
	l, failed := cliStepLine(sys, sys.ExePath, distro, skip)
	printUpdateSummary(sys, []string{"Windows programs: up to date (" + version + ")", l})
	if failed {
		return 1
	}
	return 0
}

func printUpdateSummary(sys *System, lines []string) {
	fmt.Fprintln(sys.Stdout, "\nSummary:")
	for _, l := range lines {
		fmt.Fprintln(sys.Stdout, "  "+l)
	}
}

func relation(target string) string {
	switch {
	case target == version:
		return " (the same release again)"
	case newerVersion(target, version):
		return " (an older release than this one)"
	}
	return ""
}

func baseName(p string) string {
	if i := strings.LastIndexAny(p, `\/`); i >= 0 {
		return p[i+1:]
	}
	return p
}

// --- the installer command line ----------------------------------------------

// psQuote is a PowerShell single quoted string.
func psQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }

// installerScript is the -Command text. The installer runs as a script
// block, like the one line form, so an execution policy of Restricted does
// not stop it (it is not a script file). It always gets -Yes, and the
// version the user agreed to (or the zip), so a release published after
// the question cannot change what is installed. Only single quotes appear,
// so the line survives the Windows command line unchanged.
func installerScript(o suOpts, target string, noTray bool) string {
	src := "(irm " + psQuote(installerPS1URL) + ")"
	if o.installer != "" {
		src = "(Get-Content -Raw -LiteralPath " + psQuote(o.installer) + ")"
	}
	params := " -Yes"
	if o.zip != "" {
		params += " -Zip " + psQuote(o.zip)
	} else {
		params += " -Version " + psQuote(target)
	}
	if noTray {
		params += " -NoTray"
	}
	return "$ErrorActionPreference = 'Stop'; " +
		"[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; " +
		"& ([scriptblock]::Create(" + src + "))" + params + "; exit $LASTEXITCODE"
}

func installerArgs(script string) []string {
	return []string{"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script}
}

func printableCommand(ps, script string) string {
	return fmt.Sprintf(`%s -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "%s"`, baseName(ps), script)
}

// installerEnv is this process's environment without the install.ps1
// variables, plus BENCHBAR_FROM_SELF_UPDATE=1 so the installer's closing
// text leaves the CLI to the shim. It is the child's copy only; nothing is
// set in the user's shell.
func installerEnv(sys *System) []string {
	var out []string
	for _, kv := range powerShellEnv(sys.Environ()) {
		k, _, _ := strings.Cut(kv, "=")
		drop := strings.EqualFold(k, "BENCHBAR_FROM_SELF_UPDATE")
		for _, n := range installerEnvDropped {
			drop = drop || strings.EqualFold(k, n)
		}
		if !drop {
			out = append(out, kv)
		}
	}
	return append(out, "BENCHBAR_FROM_SELF_UPDATE=1")
}

// powerShellEnv is env for a Windows PowerShell 5.1 (powershell.exe) child:
// the same without PSModulePath. PowerShell 7 sets PSModulePath to its own
// module folders, and 5.1 started with that value cannot load its own
// modules (Get-FileHash is not recognized). Without the variable 5.1 builds
// its default. Windows environment names ignore case, and so does this.
// Every start of powershell.exe goes through it.
func powerShellEnv(env []string) []string {
	out := make([]string, 0, len(env))
	for _, kv := range env {
		k, _, _ := strings.Cut(kv, "=")
		if !strings.EqualFold(k, "PSModulePath") {
			out = append(out, kv)
		}
	}
	return out
}

// --- after the installer --------------------------------------------------------

// exeVersion asks a benchbar.exe for its version.
func exeVersion(sys *System, exe string) (string, error) {
	ctx, cancel := context.WithTimeout(sys.Ctx, 30*time.Second)
	defer cancel()
	var b bytes.Buffer
	code, err := sys.Launch.Run(ctx, LaunchSpec{Path: exe, Args: []string{"--shim-version"}, Env: sys.Environ(), Stdout: &b, Stderr: io.Discard})
	if err != nil {
		return "", err
	}
	if code != 0 {
		return "", fmt.Errorf("exit code %d", code)
	}
	f := strings.Fields(b.String())
	if len(f) >= 2 && f[0] == "benchbar.exe" {
		return f[1], nil
	}
	return "", nil
}

// trayProcesses are the tray processes of this install; known is false when
// the shim cannot list processes.
func trayProcesses(sys *System, trayExe string) (procs []ProcessInfo, known bool) {
	if sys.ProcessImages == nil {
		return nil, false
	}
	for _, p := range sys.ProcessImages("BenchBarTray.exe") {
		if normDir(p.Image, sys.Getenv) == normDir(trayExe, sys.Getenv) {
			procs = append(procs, p)
		}
	}
	return procs, true
}

// sameProcess is true when a process of after is one of before: same pid
// and same creation time, so a reused pid does not count.
func sameProcess(before, after []ProcessInfo) bool {
	for _, a := range after {
		for _, b := range before {
			if a.Pid == b.Pid && a.Created == b.Created {
				return true
			}
		}
	}
	return false
}

// trayLine says what happened to the tray, from its processes before and
// after the installer. A restart is claimed only when the Windows part
// worked and the tray process is a new one.
func trayLine(sys *System, trayExe string, before []ProcessInfo, known, winOK bool) string {
	if !sys.FileExists(trayExe) {
		return "Tray app: not installed (this install has benchbar.exe only)"
	}
	if !known {
		return "Tray app: the installer restarts it when it was running"
	}
	after, _ := trayProcesses(sys, trayExe)
	switch {
	case len(after) > 0 && sameProcess(before, after):
		return "Tray app: still the old one (the installer did not get to it): quit BenchBar from its menu and start it from the Start menu"
	case len(before) > 0 && len(after) > 0 && winOK:
		return "Tray app: restarted"
	case len(after) > 0 && winOK:
		return "Tray app: started"
	case len(after) > 0:
		return "Tray app: running a new process, but the Windows part failed: it may be the old version"
	case len(before) > 0:
		return "Tray app: closed for the update and not running now: start BenchBar from the Start menu"
	}
	return "Tray app: not running (it was not running before the update): start BenchBar from the Start menu when you want it"
}

// restartKeepalive moves a keepalive run of this install to the new
// benchbar.exe. The old run still runs the old program (renamed to
// benchbar.exe.old by the installer), which would also keep that file in
// use. keepalive install of the new exe rewrites the task, stops the old run
// and starts the task again. A task of another copy is left alone, and so
// is a PC without the task. The line is empty when nothing was done.
func restartKeepalive(sys *System, newExe string) string {
	if sys.Tasks == nil {
		return ""
	}
	out, code, err := sys.Tasks.Schtasks("/Query", "/TN", taskName, "/XML")
	if err != nil || code != 0 {
		return ""
	}
	exe, distro, ok := parseTaskArguments(out)
	if !ok || distro == "" || normDir(exe, sys.Getenv) != normDir(newExe, sys.Getenv) {
		return ""
	}
	c, err := sys.Launch.Run(sys.Ctx, LaunchSpec{Path: newExe, Args: []string{"keepalive", "install", "--distro", distro},
		Env: sys.Environ(), Stdout: sys.Stdout, Stderr: sys.Stderr})
	if err != nil || c != 0 {
		return "Keepalive: could not move it to the new benchbar.exe. fix: benchbar.exe keepalive install"
	}
	return "Keepalive: restarted with the new benchbar.exe"
}

// cliTarget is the distro the CLI part works on, the one setup uses, or why
// that part is skipped. It never starts a distro.
func cliTarget(sys *System) (distro, skip string) {
	list, err := sys.Distros.Distros()
	if err != nil {
		return "", "WSL is not ready on this PC; the setup installs the CLI once it is"
	}
	name, err := setupDistro(sys, "", false)
	if err != nil {
		return "", err.Error()
	}
	for _, d := range list {
		if strings.EqualFold(d.Name, name) {
			if d.Version != 2 {
				return "", d.Name + " runs as WSL 1; the setup converts it and installs the CLI"
			}
			return d.Name, ""
		}
	}
	return "", "no Linux distro is set up yet; the setup installs the CLI when it sets one up"
}

// cliStepLine runs setup run cli_install with exe (the new benchbar.exe, not
// this process) and returns its summary line. Its log lines are shown as
// they come.
func cliStepLine(sys *System, exe, distro, skip string) (string, bool) {
	if skip != "" {
		return "CLI in WSL: skipped: " + skip, false
	}
	if sys.Launch == nil {
		return "CLI in WSL: failed: cannot start programs here", true
	}
	var status, msg string
	lw := &lineWriter{emit: func(line string) {
		var ev struct {
			Event   string `json:"event"`
			Status  string `json:"status"`
			Message string `json:"message"`
			Line    string `json:"line"`
		}
		if json.Unmarshal([]byte(line), &ev) != nil {
			fmt.Fprintln(sys.Stdout, "    "+line)
			return
		}
		switch ev.Event {
		case "log":
			fmt.Fprintln(sys.Stdout, "    "+ev.Line)
		case "step":
			if ev.Status != "running" {
				status, msg = ev.Status, ev.Message
			}
		}
	}}
	fmt.Fprintf(sys.Stdout, "\nUpdating the BenchBar CLI in %s.\n", distro)
	code, err := sys.Launch.Run(sys.Ctx, LaunchSpec{Path: exe, Args: []string{"setup", "run", "cli_install", "--distro", distro, "--jsonl"},
		Env: sys.Environ(), Stdout: lw, Stderr: sys.Stderr})
	lw.Flush()
	label := "CLI in WSL (" + distro + "): "
	fix := ". fix: benchbar.exe setup run cli_install --distro " + quoteArg(distro)
	switch {
	case err != nil:
		return label + "failed: could not start " + exe + ": " + err.Error() + fix, true
	case status == "done" || status == "skipped":
		return label + msg, false
	case msg != "":
		return label + "failed: " + msg + fix, true
	}
	return label + fmt.Sprintf("failed with exit code %d", code) + fix, true
}
