package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// The elevated half of wsl_enable.
//
// The unelevated shim starts itself with the runas verb:
//
//	benchbar.exe setup elevated wsl_enable --result <folder>\run-<16 hex>.jsonl
//
// The child is locked down on purpose. It takes exactly that command line:
// an action from the allow list (wsl_enable only), and a result file whose
// name, folder and parent folder are fixed (...\BenchBar\setup\run-*.jsonl).
// It takes no other argument, runs only System32\wsl.exe, and creates the
// one result file new (it never overwrites, so a planted file or link makes
// it stop). It writes the same JSON lines `setup run` prints. The parent
// reads the file while the child runs and relays it.

// finalPathFn is replaced in tests.
var finalPathFn = finalPathOf

var elevatedActions = map[string]bool{"wsl_enable": true}

var resultNameRE = regexp.MustCompile(`^run-[0-9a-f]{16}\.jsonl$`)

const elevatedPoll = 200 * time.Millisecond

// validResultPath checks the one path the elevated child may write.
func validResultPath(path string) error {
	if path == "" || strings.ContainsAny(path, `"%`) || !filepath.IsAbs(path) || filepath.Clean(path) != path {
		return errors.New("the result path is not an absolute clean path")
	}
	if !resultNameRE.MatchString(filepath.Base(path)) {
		return errors.New("the result file name is not allowed")
	}
	dir := filepath.Dir(path)
	if !strings.EqualFold(filepath.Base(dir), "setup") || !strings.EqualFold(filepath.Base(filepath.Dir(dir)), "BenchBar") {
		return errors.New("the result file is not in a BenchBar\\setup folder")
	}
	for _, d := range []string{dir, filepath.Dir(dir)} {
		fi, err := os.Lstat(d)
		if err != nil {
			return fmt.Errorf("cannot read %s: %v", d, err)
		}
		if !fi.IsDir() || fi.Mode()&(os.ModeSymlink|os.ModeIrregular) != 0 {
			return fmt.Errorf("%s is a link, not a folder", d)
		}
	}
	return nil
}

// cmdSetupElevated is the elevated child. Anything but the exact command
// line is refused before any work.
func cmdSetupElevated(sys *System, args []string) int {
	if len(args) != 3 || !elevatedActions[args[0]] || args[1] != "--result" {
		errorf(sys, "setup elevated takes: ACTION --result FILE (allowed actions: wsl_enable)")
		return 1
	}
	action, path := args[0], args[2]
	if err := validResultPath(path); err != nil {
		errorf(sys, "%v", err)
		return 1
	}
	if sys.ElevatedWSLPath == nil {
		errorf(sys, "no trusted wsl.exe")
		return 1
	}
	wsl, err := sys.ElevatedWSLPath()
	if err != nil {
		errorf(sys, "wsl.exe was not found in the system folder: %v", err)
		return 1
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		errorf(sys, "cannot create the result file: %v", err)
		return 1
	}
	// The folder checks above ran before the create. Compare the real path
	// of the open file now, so a folder swapped for a junction in between
	// is caught: close, delete what was created, refuse.
	if real, err := finalPathFn(f); err != nil || !strings.EqualFold(filepath.Clean(real), path) {
		f.Close()
		os.Remove(real)
		if real != path {
			os.Remove(path)
		}
		errorf(sys, "the result file is not where it must be, refusing")
		return 1
	}
	defer f.Close()

	child := *sys
	child.WSLPath = func() (string, error) { return wsl, nil }
	rc := &runCtx{sys: &child, em: &emitter{w: f, jsonl: true}, child: true}
	return runAction(rc, action)
}

// rawEvent reads any event line the child wrote.
type rawEvent struct {
	Event          string   `json:"event"`
	ID             string   `json:"id"`
	Status         string   `json:"status"`
	Message        string   `json:"message"`
	Line           string   `json:"line"`
	Exit           int      `json:"exit"`
	Changed        bool     `json:"changed"`
	RebootRequired bool     `json:"reboot_required"`
	Cancelled      bool     `json:"cancelled"`
	Warnings       []string `json:"warnings"`
	NextActions    []string `json:"next_actions"`
}

// tailer reads complete lines from a file that another process appends to.
type tailer struct {
	path string
	off  int64
	part string
}

func (t *tailer) pump() []string {
	f, err := os.Open(t.path)
	if err != nil {
		return nil
	}
	defer f.Close()
	if _, err := f.Seek(t.off, io.SeekStart); err != nil {
		return nil
	}
	data, _ := io.ReadAll(f)
	t.off += int64(len(data))
	t.part += string(data)
	var lines []string
	for {
		i := strings.IndexByte(t.part, '\n')
		if i < 0 {
			break
		}
		if l := strings.TrimSpace(t.part[:i]); l != "" {
			lines = append(lines, l)
		}
		t.part = t.part[i+1:]
	}
	return lines
}

func randomHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return fmt.Sprintf("%016x", time.Now().UnixNano())[:2*n]
	}
	return hex.EncodeToString(b)
}

// runWslEnableElevated is the unelevated side of wsl_enable: it skips the
// prompt when WSL already answers, asks Windows for permission, relays the
// child's event lines and ends with exactly one done event.
func runWslEnableElevated(rc *runCtx) int {
	sys, em := rc.sys, rc.em
	id := "wsl_enable"
	failed := func(msg string, cancelled bool) int {
		em.step(id, "failed", msg)
		em.done(doneEvent{Exit: 1, Cancelled: cancelled})
		return 1
	}
	if res, err := wslExec(sys, "", "--status"); err == nil && res.Code == 0 {
		em.step(id, "skipped", "WSL is already enabled")
		em.done(doneEvent{Exit: 0, NextActions: []string{"wsl_update"}})
		return 0
	}
	dir := setupDir(sys)
	if dir == "" {
		return failed("LOCALAPPDATA is not set", false)
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return failed("cannot create "+dir+": "+err.Error(), false)
	}
	if real, err := filepath.EvalSymlinks(dir); err == nil {
		dir = real // the real spelling, so the child's path check compares like with like
	}
	path := filepath.Join(dir, "run-"+randomHex(8)+".jsonl")
	em.step(id, "running", "Windows will ask for permission to turn on WSL")
	proc, err := sys.Elevate.Start(sys.ExePath, []string{"setup", "elevated", id, "--result", path})
	if errors.Is(err, ErrElevationDeclined) {
		return failed("the Windows permission prompt was declined", true)
	}
	if err != nil {
		return failed("cannot ask Windows for permission: "+err.Error(), false)
	}
	defer proc.Close()
	defer os.Remove(path)

	tl := &tailer{path: path}
	var final *rawEvent
	relay := func() {
		for _, l := range tl.pump() {
			var ev rawEvent
			if json.Unmarshal([]byte(l), &ev) != nil {
				continue
			}
			switch ev.Event {
			case "step":
				em.step(ev.ID, ev.Status, ev.Message)
			case "log":
				em.log(ev.Line)
			case "done":
				e := ev
				final = &e
			}
		}
	}
	exit := 0
	for {
		done, code, werr := proc.Wait(elevatedPoll)
		relay()
		if werr != nil {
			return failed("lost the elevated process: "+werr.Error(), false)
		}
		if done {
			exit = code
			relay()
			break
		}
		if sys.Ctx.Err() != nil {
			return failed("stopped while the elevated process was running", false)
		}
	}
	if final == nil {
		msg := "the elevated process ended without a result"
		if exit != 0 {
			msg = fmt.Sprintf("%s (exit code %d)", msg, exit)
		}
		return failed(msg, false)
	}
	warnings := final.Warnings
	if final.Exit == 0 && final.RebootRequired {
		if err := writeRebootMarker(sys); err != nil {
			warnings = append(warnings, "could not remember that a restart is pending: "+err.Error())
		}
	}
	em.done(doneEvent{Exit: final.Exit, Changed: final.Changed, RebootRequired: final.RebootRequired,
		Warnings: warnings, NextActions: final.NextActions})
	return final.Exit
}
