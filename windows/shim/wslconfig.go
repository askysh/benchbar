package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const minMemory = 4 << 30

type wslSetting struct {
	Section string `json:"section"`
	Key     string `json:"key"`
	Value   string `json:"value"`
	Set     bool   `json:"set"`
	Default string `json:"default"`
}

type wslChange struct {
	Section string `json:"section"`
	Key     string `json:"key"`
	Value   string `json:"value"`
}

type wslReport struct {
	Path            string       `json:"path"`
	Exists          bool         `json:"exists"`
	HostMemoryBytes uint64       `json:"host_memory_bytes"`
	Settings        []wslSetting `json:"settings"`
	Suggest         []wslChange  `json:"suggest"`
}

func wslconfigPath(sys *System) (string, error) {
	if sys.ProfileDir == "" {
		return "", errors.New("USERPROFILE is not set")
	}
	return filepath.Join(sys.ProfileDir, ".wslconfig"), nil
}

func readWslconfig(sys *System) (*ini, wslReport, error) {
	path, err := wslconfigPath(sys)
	if err != nil {
		return nil, wslReport{}, err
	}
	data, err := os.ReadFile(path)
	exists := err == nil
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, wslReport{}, fmt.Errorf("cannot read %s: %v", path, err)
	}
	f := parseINI(data)
	var host uint64
	if sys.MemoryBytes != nil {
		host, _ = sys.MemoryBytes()
	}
	return f, analyzeWslconfig(f, path, exists, host), nil
}

// parseSize reads 8GB, 4096MB, 512M, 1.5GB or a plain byte count.
func parseSize(s string) (uint64, bool) {
	s = strings.ToUpper(strings.TrimSpace(s))
	i := 0
	for i < len(s) && (s[i] >= '0' && s[i] <= '9' || s[i] == '.') {
		i++
	}
	n, err := strconv.ParseFloat(s[:i], 64)
	if err != nil || n < 0 {
		return 0, false
	}
	mult := map[string]float64{
		"": 1, "B": 1,
		"K": 1 << 10, "KB": 1 << 10,
		"M": 1 << 20, "MB": 1 << 20,
		"G": 1 << 30, "GB": 1 << 30,
		"T": 1 << 40, "TB": 1 << 40,
	}
	m, ok := mult[strings.TrimSpace(s[i:])]
	if !ok {
		return 0, false
	}
	return uint64(n * m), true
}

func formatGB(b uint64) string {
	s := strconv.FormatFloat(float64(b)/(1<<30), 'f', 1, 64)
	return strings.TrimSuffix(s, ".0") + " GB"
}

func analyzeWslconfig(f *ini, path string, exists bool, host uint64) wslReport {
	memDefault := "50% of host RAM"
	if host > 0 {
		memDefault += ", " + formatGB(host/2)
	}
	specs := []wslSetting{
		{Section: "wsl2", Key: "memory", Default: memDefault},
		{Section: "wsl2", Key: "processors", Default: "all logical processors"},
		{Section: "wsl2", Key: "swap", Default: "25% of host RAM"},
		{Section: "wsl2", Key: "vmIdleTimeout", Default: "60000"},
		{Section: "general", Key: "instanceIdleTimeout", Default: "15000"},
	}
	r := wslReport{Path: path, Exists: exists, HostMemoryBytes: host, Settings: specs, Suggest: []wslChange{}}
	for i := range r.Settings {
		s := &r.Settings[i]
		s.Value, s.Set = f.get(s.Section, s.Key)
	}
	mem := r.Settings[0]
	switch {
	case mem.Set:
		if n, ok := parseSize(mem.Value); ok && n < minMemory {
			r.Suggest = append(r.Suggest, wslChange{"wsl2", "memory", "4GB"})
		}
	case host > 0 && host/2 < minMemory:
		r.Suggest = append(r.Suggest, wslChange{"wsl2", "memory", "4GB"})
	}
	if v := r.Settings[3]; !v.Set || v.Value != "-1" {
		r.Suggest = append(r.Suggest, wslChange{"wsl2", "vmIdleTimeout", "-1"})
	}
	if v := r.Settings[4]; !v.Set || v.Value != "-1" {
		r.Suggest = append(r.Suggest, wslChange{"general", "instanceIdleTimeout", "-1"})
	}
	return r
}

func (r wslReport) print(w io.Writer) {
	state := "found"
	if !r.Exists {
		state = "not found"
	}
	fmt.Fprintf(w, ".wslconfig: %s (%s)\n", r.Path, state)
	for _, s := range r.Settings {
		val := s.Value
		if !s.Set {
			val = "not set (default " + s.Default + ")"
		}
		fmt.Fprintf(w, "  %-20s %s\n", s.Key, val)
	}
}

func formatChanges(changes []wslChange) string {
	var b strings.Builder
	last := ""
	for _, c := range changes {
		if c.Section != last {
			fmt.Fprintf(&b, "[%s]\n", c.Section)
			last = c.Section
		}
		fmt.Fprintf(&b, "%s=%s\n", c.Key, c.Value)
	}
	return b.String()
}

func cmdWslconfig(sys *System, args []string) int {
	p, err := parseFlags(args, []string{"--suggest", "--apply", "--yes", "--json"}, nil)
	if err != nil || len(p.pos) > 0 {
		if err == nil {
			err = fmt.Errorf("unexpected argument %s", p.pos[0])
		}
		errorf(sys, "%v. usage: benchbar.exe wslconfig [--suggest] [--apply --yes] [--json]", err)
		return 1
	}
	if p.bools["--json"] && p.bools["--apply"] {
		errorf(sys, "--json does not combine with --apply")
		return 1
	}
	f, rep, err := readWslconfig(sys)
	if err != nil {
		errorf(sys, "%v", err)
		return 1
	}
	switch {
	case p.bools["--json"]:
		printJSON(sys.Stdout, rep)
	case p.bools["--apply"]:
		return applyWslconfig(sys, f, rep, p.bools["--yes"])
	case p.bools["--suggest"]:
		if len(rep.Suggest) == 0 {
			fmt.Fprintln(sys.Stdout, "Nothing to change.")
		} else {
			fmt.Fprint(sys.Stdout, formatChanges(rep.Suggest))
		}
	default:
		rep.print(sys.Stdout)
	}
	return 0
}

func applyWslconfig(sys *System, f *ini, rep wslReport, yes bool) int {
	if len(rep.Suggest) == 0 {
		fmt.Fprintln(sys.Stdout, "Nothing to change.")
		return 0
	}
	if !yes {
		fmt.Fprintf(sys.Stdout, "Would change %s:\n%s", rep.Path, formatChanges(rep.Suggest))
		errorf(sys, "pass --yes to write it")
		return 1
	}
	if rep.Exists {
		old, err := os.ReadFile(rep.Path)
		if err != nil {
			errorf(sys, "cannot read %s: %v", rep.Path, err)
			return 1
		}
		backup := rep.Path + ".benchbar-backup-" + sys.Now().Format("20060102-150405")
		if err := writeFileAtomic(backup, old); err != nil {
			errorf(sys, "cannot write the backup %s: %v", backup, err)
			return 1
		}
		fmt.Fprintf(sys.Stdout, "Backed up to %s\n", backup)
	}
	for _, c := range rep.Suggest {
		f.set(c.Section, c.Key, c.Value)
	}
	if err := writeFileAtomic(rep.Path, f.render()); err != nil {
		errorf(sys, "cannot write %s: %v", rep.Path, err)
		return 1
	}
	fmt.Fprintf(sys.Stdout, "Wrote %s:\n%s", rep.Path, formatChanges(rep.Suggest))
	fmt.Fprintln(sys.Stdout, "WSL reads it at its next start. wsl.exe --shutdown restarts it and stops running benches, so run it when that is OK. benchbar.exe never runs it.")
	return 0
}

// idleCheck is the doctor line for the two idle timeouts.
func idleCheck(r wslReport) Check {
	c := Check{ID: "wslconfig", Label: ".wslconfig", Status: "ok",
		Message: "vmIdleTimeout and instanceIdleTimeout are -1"}
	var bad []string
	for _, s := range r.Settings {
		if s.Key != "vmIdleTimeout" && s.Key != "instanceIdleTimeout" {
			continue
		}
		switch {
		case !s.Set:
			bad = append(bad, fmt.Sprintf("%s not set (default %s)", s.Key, s.Default))
		case s.Value != "-1":
			bad = append(bad, fmt.Sprintf("%s is %s", s.Key, s.Value))
		}
	}
	if len(bad) > 0 {
		c.Status = "warn"
		c.Message = "WSL can stop idle benches: " + strings.Join(bad, ", ")
		c.Fix = "benchbar.exe wslconfig --suggest"
	}
	return c
}
