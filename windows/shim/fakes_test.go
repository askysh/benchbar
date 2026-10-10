package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type fakeDistros struct {
	list []Distro
	err  error
}

func (f *fakeDistros) Distros() ([]Distro, error) { return f.list, f.err }

type fakePaths struct {
	user     PathValue
	machine  string
	userErr  error
	setCalls int
}

func (f *fakePaths) User() (PathValue, error) { return f.user, f.userErr }
func (f *fakePaths) SetUser(v string, expand bool) error {
	f.user = PathValue{Value: v, Expand: expand, Exists: true}
	f.setCalls++
	return nil
}
func (f *fakePaths) Machine() (string, error) { return f.machine, nil }

type fakeBroadcast struct{ n int }

func (f *fakeBroadcast) EnvironmentChanged() error { f.n++; return nil }

type fakeTasks struct {
	calls   [][]string
	handler func(args []string) (string, int, error)
}

func (f *fakeTasks) Schtasks(args ...string) (string, int, error) {
	f.calls = append(f.calls, args)
	if f.handler != nil {
		return f.handler(args)
	}
	return "", 0, nil
}

// env is a shim System wired to fakes, in a temp folder.
type env struct {
	*System
	t       *testing.T
	root    string
	distros *fakeDistros
	paths   *fakePaths
	bcast   *fakeBroadcast
	tasks   *fakeTasks
	procs   *fakeProcs
	out     *bytes.Buffer
	err     *bytes.Buffer
	record  string
}

var ubuntu = Distro{Name: "Ubuntu-24.04", Version: 2, Default: true}

func newEnv(t *testing.T) *env {
	t.Helper()
	root := t.TempDir()
	e := &env{
		System:  newFakeSystem(),
		t:       t,
		root:    root,
		distros: &fakeDistros{list: []Distro{ubuntu}},
		paths:   &fakePaths{},
		bcast:   &fakeBroadcast{},
		tasks:   &fakeTasks{},
		procs:   newFakeProcs(),
		out:     &bytes.Buffer{},
		err:     &bytes.Buffer{},
		record:  filepath.Join(root, "record.jsonl"),
	}
	e.Distros, e.Paths, e.Broadcast, e.Tasks = e.distros, e.paths, e.bcast, e.tasks
	e.Procs = e.procs
	e.Stdout, e.Stderr = e.out, e.err
	e.ConfigDir = filepath.Join(root, "LocalAppData", "BenchBar")
	e.ProfileDir = filepath.Join(root, "Profile")
	os.MkdirAll(e.ProfileDir, 0o755)
	t.Setenv("FAKE_WSL_RECORD", e.record)
	t.Setenv("FAKE_WSL_MODE", "exit:0")
	t.Setenv("FAKE_WSL_RECORD_STDIN", "")
	t.Setenv("FAKE_WSL_PROBE_AFTER", "")
	t.Setenv("FAKE_WSL_READY", "")
	return e
}

func (e *env) run(args ...string) int { return run(e.System, args) }

func (e *env) writeConfig(content string) {
	e.t.Helper()
	if err := os.MkdirAll(e.ConfigDir, 0o755); err != nil {
		e.t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(e.ConfigDir, "config.json"), []byte(content), 0o644); err != nil {
		e.t.Fatal(err)
	}
}

func (e *env) readConfig() map[string]json.RawMessage {
	e.t.Helper()
	data, err := os.ReadFile(filepath.Join(e.ConfigDir, "config.json"))
	if err != nil {
		e.t.Fatal(err)
	}
	m := map[string]json.RawMessage{}
	if err := json.Unmarshal(data, &m); err != nil {
		e.t.Fatal(err)
	}
	return m
}

func (e *env) stdout() string { return e.out.String() }
func (e *env) stderr() string { return e.err.String() }

type fakeEvent struct {
	Event   string   `json:"event"`
	Args    []string `json:"args"`
	Distro  string   `json:"distro"`
	Cd      string   `json:"cd"`
	Exec    []string `json:"exec"`
	WSLUTF8 string   `json:"wsl_utf8"`
	Stdin   string   `json:"stdin_b64"`
	Signal  string   `json:"signal"`
}

// events reads what the fake wsl.exe recorded; none if it never ran.
func readEvents(t *testing.T, path string) []fakeEvent {
	t.Helper()
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	var out []fakeEvent
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		if line == "" {
			continue
		}
		var ev fakeEvent
		if err := json.Unmarshal([]byte(line), &ev); err != nil {
			t.Fatalf("bad record line %q: %v", line, err)
		}
		out = append(out, ev)
	}
	return out
}

func (e *env) events() []fakeEvent { return readEvents(e.t, e.record) }

// starts are the invocations of the fake, not its other events.
func (e *env) starts() []fakeEvent {
	var out []fakeEvent
	for _, ev := range e.events() {
		if ev.Event == "start" {
			out = append(out, ev)
		}
	}
	return out
}

type fakeProcs struct {
	alive      map[int]bool
	images     map[int]string
	terminated []int
}

func newFakeProcs() *fakeProcs {
	return &fakeProcs{alive: map[int]bool{}, images: map[int]string{}}
}

func (f *fakeProcs) add(pid int, image string) { f.alive[pid], f.images[pid] = true, image }

func (f *fakeProcs) Alive(pid int) bool { return f.alive[pid] }
func (f *fakeProcs) Image(pid int) (string, error) {
	if img, ok := f.images[pid]; ok {
		return img, nil
	}
	return "", errors.New("no such process")
}
func (f *fakeProcs) Terminate(pid int) error {
	f.terminated = append(f.terminated, pid)
	f.alive[pid] = false
	return nil
}
