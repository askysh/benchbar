package main

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"time"
)

// report-windows writes a zip for a bug report that works on a PC with no
// WSL, no distro and no CLI. It reads, never changes: it does not elevate
// and it does not start a stopped distro (the running state comes from
// `wsl.exe --list --running --quiet`, as in `setup check` without --probe).

const (
	reportSchema     = 1
	reportKeep       = 10
	reportIncludeMax = 1 << 20  // bytes of one included file; a larger one is tailed
	reportCLIMax     = 32 << 20 // bytes of the CLI's own zip
	reportWSLTimeout = 20 * time.Second
	reportCLITimeout = 120 * time.Second
	reportURLMax     = 3900
	issueBase        = "https://github.com/askysh/benchbar/issues/new?template=bug_report_windows.yml"
	reportUsage      = "usage: benchbar.exe report-windows [--json] [--distro NAME] [--bench PATH] [--context TEXT] [--tray-version V] [--include FILE]..."
)

var reportNameRE = regexp.MustCompile(`^benchbar-windows-report-\d{8}-\d{6}(-\d+)?\.zip$`)

type skippedPart struct {
	Part   string `json:"part"`
	Reason string `json:"reason"`
}

type reportResult struct {
	SchemaVersion int           `json:"schema_version"`
	Zip           string        `json:"zip"`
	Included      []string      `json:"included"`
	Skipped       []skippedPart `json:"skipped"`
	IssueURL      string        `json:"issue_url"`
}

// splitIncludes takes the repeatable --include out of args.
func splitIncludes(args []string) (rest, includes []string, err error) {
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--include":
			if i+1 >= len(args) {
				return nil, nil, errors.New("--include needs a value")
			}
			i++
			includes = append(includes, args[i])
		case strings.HasPrefix(a, "--include="):
			includes = append(includes, strings.TrimPrefix(a, "--include="))
		default:
			rest = append(rest, a)
		}
	}
	return rest, includes, nil
}

// --- redaction --------------------------------------------------------------

var (
	secretLineRE = regexp.MustCompile(`(?i)\b([A-Za-z0-9_.-]*(?:password|passwd|secret|token|api[_-]?key)[A-Za-z0-9_.-]*)(\s*[=:]\s*)("[^"\r\n]*"|'[^'\r\n]*'|[^\s,;]+)`)
	winUsersRE   = regexp.MustCompile(`(?i)([A-Za-z]:[\\/]+Users[\\/]+)[^\\/\s"'<>|:*?]+`)
	wslHomeRE    = regexp.MustCompile(`(?i)(\\\\wsl(?:\.localhost|\$)\\[^\\\s"']+\\home\\)[^\\\s"'<>]+`)
	mntUsersRE   = regexp.MustCompile(`(?i)(/mnt/[a-z]/Users/)[^/\s"'<>]+`)
	linuxHomeRE  = regexp.MustCompile(`(/home/)[^/\s"'<>:]+`)
	pathTokenRE  = regexp.MustCompile(`(?i)(?:[A-Za-z]:[\\/][^\s"']*|\\\\[^\s"']+|/(?:home|mnt|tmp|usr|etc|var|opt|root)/[^\s"']*)`)
)

type redactor struct {
	profile *regexp.Regexp // %USERPROFILE%
	names   []*regexp.Regexp
}

func newRedactor(sys *System, linuxUser string) *redactor {
	r := &redactor{}
	if p := strings.TrimRight(sys.ProfileDir, `\/`); p != "" {
		parts := regexp.MustCompile(`[\\/]+`).Split(p, -1)
		for i := range parts {
			parts[i] = regexp.QuoteMeta(parts[i])
		}
		r.profile = regexp.MustCompile(`(?i)` + strings.Join(parts, `[\\/]+`))
	}
	add := func(name string, fold bool) {
		if len(name) < 3 || name == "root" {
			return
		}
		flag := ""
		if fold {
			flag = "(?i)"
		}
		// Go's \b is ASCII only: a name such as "José" needs letter classes
		r.names = append(r.names, regexp.MustCompile(flag+`(^|[^\pL\pN_])`+regexp.QuoteMeta(name)+`($|[^\pL\pN_])`))
	}
	win := sys.User
	if i := strings.LastIndexAny(win, `\/`); i >= 0 {
		win = win[i+1:]
	}
	add(win, true)
	add(linuxUser, false)
	return r
}

// text hides the names and secrets in one text part.
func (r *redactor) text(s string) string {
	s = secretLineRE.ReplaceAllString(s, "${1}${2}<redacted>")
	if r.profile != nil {
		s = r.profile.ReplaceAllString(s, `C:\Users\<user>`)
	}
	s = winUsersRE.ReplaceAllString(s, "${1}<user>")
	s = wslHomeRE.ReplaceAllString(s, "${1}<user>")
	s = mntUsersRE.ReplaceAllString(s, "${1}<user>")
	s = linuxHomeRE.ReplaceAllString(s, "${1}<user>")
	for _, re := range r.names {
		s = re.ReplaceAllString(s, "${1}<user>${2}")
	}
	return s
}

// forURL also drops every path: a URL carries versions and a sentence only.
func (r *redactor) forURL(s string) string {
	s = r.text(s)
	return pathTokenRE.ReplaceAllString(s, "<path>")
}

// --- running wsl.exe with a limit -------------------------------------------

type limitBuffer struct {
	bytes.Buffer
	max  int
	over bool
}

func (b *limitBuffer) Write(p []byte) (int, error) {
	if b.Len()+len(p) > b.max {
		b.over = true
		return 0, errors.New("output too large")
	}
	return b.Buffer.Write(p)
}

// wslText runs wsl.exe, waits at most d and returns its text. A timeout is
// an error and ends the process.
func wslText(sys *System, d time.Duration, args ...string) (wslResult, error) {
	type out struct {
		res wslResult
		err error
	}
	ch := make(chan out, 1)
	go func() {
		res, err := wslExec(sys, "", args...)
		ch <- out{res, err}
	}()
	select {
	case o := <-ch:
		return o.res, o.err
	case <-time.After(d):
		return wslResult{}, fmt.Errorf("wsl.exe %s did not answer within %s", strings.Join(args, " "), d)
	}
}

// wslBytes runs wsl.exe and returns its raw stdout (a zip must not pass
// through the text decoder).
func wslBytes(sys *System, d time.Duration, max int, args ...string) ([]byte, int, error) {
	cmd, err := wslCommand(sys, args...)
	if err != nil {
		return nil, 1, err
	}
	var o limitBuffer
	o.max = max
	var e bytes.Buffer
	cmd.Stdout, cmd.Stderr = &o, &e
	if err := cmd.Start(); err != nil {
		return nil, 1, err
	}
	defer attachKillOnClose(cmd.Process.Pid)()
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		if o.over {
			return nil, 1, errors.New("the output is larger than the limit")
		}
		code := 0
		if err != nil {
			var ee interface{ ExitCode() int }
			if !errors.As(err, &ee) {
				return nil, 1, err
			}
			code = ee.ExitCode()
		}
		return o.Bytes(), code, nil
	case <-time.After(d):
		cmd.Process.Kill()
		<-done
		return nil, 1, fmt.Errorf("no answer within %s", d)
	}
}

// --- the parts ---------------------------------------------------------------

type zipPart struct {
	name string
	data []byte
}

type reportBuilder struct {
	parts    []zipPart
	skipped  []skippedPart
	redactor *redactor
}

func (b *reportBuilder) addText(name, text string) {
	b.parts = append(b.parts, zipPart{name, []byte(b.redactor.text(text))})
}

func (b *reportBuilder) skip(part, reason string) {
	b.skipped = append(b.skipped, skippedPart{part, reason})
}

func lines(s string, n int) string {
	l := strings.Split(strings.TrimSpace(s), "\n")
	if len(l) > n {
		l = l[:n]
	}
	return strings.TrimSpace(strings.Join(l, "\n"))
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}

// tailFile reads a file, or its last reportIncludeMax bytes.
func tailFile(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if !fi.Mode().IsRegular() {
		return nil, errors.New("not a regular file")
	}
	note := ""
	if fi.Size() > reportIncludeMax {
		if _, err := f.Seek(fi.Size()-reportIncludeMax, io.SeekStart); err != nil {
			return nil, err
		}
		note = fmt.Sprintf("[benchbar.exe kept the last %d bytes of %d]\n", reportIncludeMax, fi.Size())
	}
	data, err := io.ReadAll(io.LimitReader(f, reportIncludeMax))
	if err != nil {
		return nil, err
	}
	data, _ = decodeText(data)
	return append([]byte(note), data...), nil
}

func uniqueName(used map[string]bool, name string) string {
	base := name
	for n := 2; used[name]; n++ {
		ext := filepath.Ext(base)
		name = fmt.Sprintf("%s-%d%s", strings.TrimSuffix(base, ext), n, ext)
	}
	used[name] = true
	return name
}

// --- the command -------------------------------------------------------------

func cmdReportWindows(sys *System, args []string) int {
	rest, includes, err := splitIncludes(args)
	var p *parsedArgs
	if err == nil {
		p, err = parseFlags(rest, []string{"--json"}, []string{"--distro", "--bench", "--context", "--tray-version"})
	}
	if err == nil && len(p.pos) > 0 {
		err = fmt.Errorf("unexpected argument %s", p.pos[0])
	}
	if err != nil {
		errorf(sys, "%v. %s", err, reportUsage)
		return 1
	}
	if sys.ConfigDir == "" {
		errorf(sys, "LOCALAPPDATA is not set, so there is no place for the report")
		return 1
	}
	bench := p.vals["--bench"]
	if bench != "" && (!strings.HasPrefix(bench, "/") || strings.ContainsAny(bench, "\r\n\x00")) {
		errorf(sys, "--bench takes an absolute path inside the distro. %s", reportUsage)
		return 1
	}
	distro := p.vals["--distro"]
	if distro != "" && !distroNameRE.MatchString(distro) {
		errorf(sys, "%q is not a usable distro name. %s", distro, reportUsage)
		return 1
	}
	if distro == "" {
		// a damaged config.json must not stop a report
		if d, err := setupDistro(sys, ""); err == nil {
			distro = d
		} else {
			distro = defaultSetupDistro
		}
	}
	context := strings.TrimSpace(p.vals["--context"])
	if r := []rune(context); len(r) > 200 {
		context = string(r[:200])
	}
	trayVersion := p.vals["--tray-version"]

	facts := gatherFacts(sys, distro)
	rd := newRedactor(sys, facts.linuxUser)
	b := &reportBuilder{redactor: rd}

	b.addText("wsl-status.txt", facts.statusText)
	b.addText("wsl-list.txt", facts.listText)
	rep := buildSetupReport(sys, distro, false)
	// redact the values before they become JSON: a path with backslashes
	// put in afterwards would break the escaping
	rep.Distro = rd.text(rep.Distro)
	for i := range rep.Steps {
		rep.Steps[i].Detail = rd.text(rep.Steps[i].Detail)
	}
	var js bytes.Buffer
	enc := json.NewEncoder(&js)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if enc.Encode(rep) == nil {
		b.parts = append(b.parts, zipPart{"setup-check.json", js.Bytes()})
	}

	cliVersion := ""
	cliZip, cliVer, reason := collectCLIReport(sys, facts, distro, bench)
	if cliZip != nil {
		b.parts = append(b.parts, zipPart{"cli-report.zip", cliZip})
		cliVersion = cliVer
	} else {
		b.skip("cli_report", reason)
	}

	used := map[string]bool{"summary.txt": true, "setup-check.json": true, "wsl-status.txt": true, "wsl-list.txt": true, "cli-report.zip": true}
	for _, inc := range includes {
		name := "included/" + uniqueName(used, filepath.Base(strings.ReplaceAll(inc, `\`, "/")))
		data, err := tailFile(inc)
		if err != nil {
			b.skip("include:"+filepath.Base(strings.ReplaceAll(inc, `\`, "/")), "cannot read the file: "+rd.text(err.Error()))
			continue
		}
		b.parts = append(b.parts, zipPart{name, []byte(rd.text(string(data)))})
	}

	summary := buildSummary(sys, facts, distro, context, trayVersion, cliVersion)
	parts := append([]zipPart{{"summary.txt", []byte(rd.text(summary))}}, b.parts...)

	zipPath, err := writeReportZip(sys, parts)
	if err != nil {
		errorf(sys, "cannot write the report: %v", err)
		return 1
	}
	pruneReports(filepath.Dir(zipPath), filepath.Base(zipPath))

	res := reportResult{SchemaVersion: reportSchema, Zip: zipPath, Included: []string{}, Skipped: b.skipped}
	if res.Skipped == nil {
		res.Skipped = []skippedPart{}
	}
	for _, pt := range parts {
		res.Included = append(res.Included, pt.name)
	}
	res.IssueURL = buildIssueURL(sys, rd, facts, distro, context, trayVersion, cliVersion)
	if p.bools["--json"] {
		printJSON(sys.Stdout, res)
		return 0
	}
	fmt.Fprintf(sys.Stdout, "Report written: %s\n", res.Zip)
	for _, s := range res.Skipped {
		fmt.Fprintf(sys.Stdout, "Left out %s: %s\n", s.Part, s.Reason)
	}
	fmt.Fprintf(sys.Stdout, "Open this page and attach the zip:\n%s\n", res.IssueURL)
	return 0
}

// facts are what the report says about this PC.
type reportFacts struct {
	product     string
	build       int
	arch        string
	wslVersion  string // the number, or ""
	versionText string
	statusText  string
	listText    string
	statusOK    bool
	wslMissing  bool
	registered  bool
	running     bool
	defaultName string
	configured  string
	linuxUser   string
}

func gatherFacts(sys *System, distro string) reportFacts {
	f := reportFacts{arch: runtime.GOARCH}
	f.product, _ = sys.Host.ProductName()
	f.build, _ = sys.Host.WindowsBuild()
	if _, err := sys.WSLPath(); err != nil {
		f.wslMissing = true
		f.statusText = "wsl.exe was not found: " + err.Error() + "\n"
		f.listText = f.statusText
	} else {
		f.statusText, f.statusOK = wslOutput(sys, "--status")
		f.listText, _ = wslOutput(sys, "--list", "--verbose")
		if res, err := wslText(sys, reportWSLTimeout, "--version"); err == nil && res.Code == 0 {
			f.versionText = lines(res.Stdout, 4)
			f.wslVersion, _ = wslVersionOK(res.Stdout)
		}
	}
	if cfg, err := loadConfig(sys); err == nil {
		f.configured = cfg.str("distro")
	}
	if list, err := sys.Distros.Distros(); err == nil {
		for _, d := range list {
			if d.Default {
				f.defaultName = d.Name
			}
			if strings.EqualFold(d.Name, distro) {
				f.registered = true
			}
		}
	}
	if f.registered && !f.wslMissing {
		if res, err := wslText(sys, reportWSLTimeout, "--list", "--running", "--quiet"); err == nil && res.Code == 0 {
			for _, n := range strings.Split(res.Stdout, "\n") {
				if strings.EqualFold(strings.TrimSpace(n), distro) {
					f.running = true
				}
			}
		}
	}
	if f.running {
		if res, err := wslText(sys, reportWSLTimeout, "-d", distro, "--exec", "/usr/bin/id", "-un"); err == nil && res.Code == 0 {
			f.linuxUser = strings.TrimSpace(res.Stdout)
		}
	}
	return f
}

func wslOutput(sys *System, args ...string) (string, bool) {
	res, err := wslText(sys, reportWSLTimeout, args...)
	if err != nil {
		return "wsl.exe " + strings.Join(args, " ") + ": " + err.Error() + "\n", false
	}
	return fmt.Sprintf("wsl.exe %s (exit code %d)\n%s\n", strings.Join(args, " "), res.Code, res.text()), res.Code == 0
}

func (f reportFacts) distroState() string {
	switch {
	case f.wslMissing:
		return "WSL not found"
	case !f.registered:
		return "not installed"
	case f.running:
		return "running"
	}
	return "stopped"
}

func buildSummary(sys *System, f reportFacts, distro, context, trayVersion, cliVersion string) string {
	var s strings.Builder
	w := func(k, v string) { fmt.Fprintf(&s, "%s: %s\n", k, v) }
	w("BenchBar Windows report", sys.Now().Format(time.RFC3339))
	w("benchbar.exe", version)
	w("tray", firstNonEmpty(trayVersion, "not given"))
	w("benchbar CLI", firstNonEmpty(cliVersion, "not available"))
	w("Windows", firstNonEmpty(f.product, "unknown")+fmt.Sprintf(", build %d, %s", f.build, f.arch))
	w("WSL version", firstNonEmpty(strings.ReplaceAll(f.versionText, "\n", "; "), "not available"))
	w("WSL default distro", firstNonEmpty(f.defaultName, "none"))
	w("configured distro", firstNonEmpty(f.configured, "none"))
	w("distro used", distro+" ("+f.distroState()+")")
	w("context", firstNonEmpty(context, "not given"))
	return s.String()
}

// collectCLIReport runs `benchbar report --json` in a running distro and
// returns the zip it names. Otherwise it returns why not.
func collectCLIReport(sys *System, f reportFacts, distro, bench string) ([]byte, string, string) {
	switch {
	case f.wslMissing:
		return nil, "", "WSL is not installed"
	case !f.registered:
		return nil, "", "the distro " + distro + " is not installed"
	case !f.running:
		return nil, "", "the distro is stopped"
	}
	t := target{distro: distro, cli: "benchbar"}
	if tt, err := resolveTarget(sys, distro); err == nil && tt.prob == nil {
		t = tt
	}
	if !cliExists(sys, t) {
		return nil, "", "benchbar is not installed in the distro"
	}
	args := []string{"report", "--json", "--out", "/tmp"}
	if bench != "" {
		args = append(args, "--bench-dir", bench)
	}
	out, code, err := wslBytes(sys, reportCLITimeout, 1<<20, forwardArgs(distro, t.cli, args)...)
	if err != nil {
		return nil, "", "benchbar report did not run: " + err.Error()
	}
	if code != 0 {
		return nil, "", fmt.Sprintf("benchbar report failed with exit code %d", code)
	}
	var doc struct {
		Zip        string `json:"zip"`
		CLIVersion string `json:"cli_version"`
	}
	ok := false
	ls := strings.Split(strings.TrimSpace(string(out)), "\n")
	for i := len(ls) - 1; i >= 0 && !ok; i-- {
		if l := strings.TrimSpace(ls[i]); strings.HasPrefix(l, "{") {
			ok = json.Unmarshal([]byte(l), &doc) == nil
		}
	}
	if !ok || !strings.HasPrefix(doc.Zip, "/") || !strings.HasSuffix(doc.Zip, ".zip") || strings.ContainsAny(doc.Zip, "\r\n\x00") {
		return nil, doc.CLIVersion, "benchbar report did not name a zip"
	}
	data, code, err := wslBytes(sys, reportWSLTimeout, reportCLIMax, "-d", distro, "--exec", "/bin/cat", doc.Zip)
	if err != nil || code != 0 || len(data) == 0 {
		why := "cannot read it"
		if err != nil {
			why = err.Error()
		}
		return nil, doc.CLIVersion, "cannot copy the CLI report out of the distro: " + why
	}
	// the copy is in the Windows zip now: do not leave one more in /tmp
	_, _, _ = wslBytes(sys, reportWSLTimeout, 1024, "-d", distro, "--exec", "/bin/rm", "-f", "--", doc.Zip)
	return data, doc.CLIVersion, ""
}

// --- the zip and its folder ---------------------------------------------------

func writeReportZip(sys *System, parts []zipPart) (string, error) {
	dir := filepath.Join(sys.ConfigDir, "reports")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	stamp := sys.Now().Format("20060102-150405")
	path := filepath.Join(dir, "benchbar-windows-report-"+stamp+".zip")
	for n := 2; fileExists(path); n++ {
		path = filepath.Join(dir, fmt.Sprintf("benchbar-windows-report-%s-%d.zip", stamp, n))
	}
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for _, pt := range parts {
		w, err := zw.CreateHeader(&zip.FileHeader{Name: pt.name, Method: zip.Deflate, Modified: sys.Now()})
		if err != nil {
			return "", err
		}
		if _, err := w.Write(pt.data); err != nil {
			return "", err
		}
	}
	if err := zw.Close(); err != nil {
		return "", err
	}
	if err := writeFileAtomic(path, buf.Bytes()); err != nil {
		return "", err
	}
	return path, nil
}

// pruneReports keeps the newest reportKeep report zips. The names hold the
// time, so the name order is the age order. keep is never removed.
func pruneReports(dir, keep string) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	var names []string
	for _, e := range entries {
		if !e.IsDir() && reportNameRE.MatchString(e.Name()) {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	for len(names) > reportKeep {
		if names[0] != keep {
			os.Remove(filepath.Join(dir, names[0]))
		}
		names = names[1:]
	}
}

// --- the issue link -------------------------------------------------------------

func buildIssueURL(sys *System, rd *redactor, f reportFacts, distro, context, trayVersion, cliVersion string) string {
	clean := rd.forURL
	versions := fmt.Sprintf("benchbar.exe %s, tray %s, CLI %s", version,
		firstNonEmpty(trayVersion, "not given"), firstNonEmpty(cliVersion, "not available"))
	win := fmt.Sprintf("%s, build %d, %s", firstNonEmpty(f.product, "Windows"), f.build, f.arch)
	dist := fmt.Sprintf("%s, WSL %s, %s", distro, firstNonEmpty(f.wslVersion, "unknown"), f.distroState())
	build := func(ctx string, withWhat bool) string {
		q := url.Values{}
		q.Set("title", strings.TrimSpace("[Windows] "+ctx))
		q.Set("versions", clean(versions))
		q.Set("windows", clean(win))
		q.Set("distro", clean(dist))
		if withWhat && ctx != "" {
			q.Set("what", "While: "+ctx+"\n\n\n")
		}
		return issueBase + "&" + strings.ReplaceAll(q.Encode(), "+", "%20")
	}
	ctx := clean(context)
	u := build(ctx, true)
	for len(u) > reportURLMax && len(ctx) > 0 {
		r := []rune(ctx)
		ctx = string(r[:len(r)/2])
		u = build(ctx, true)
	}
	if len(u) > reportURLMax {
		u = build("", false)
	}
	return u
}
