package main

import (
	"fmt"
	"strings"
)

// expandPercent expands %NAME% the way the registry's REG_EXPAND_SZ does.
// A name that is not set stays as written.
func expandPercent(s string, getenv func(string) string) string {
	var b strings.Builder
	for {
		i := strings.IndexByte(s, '%')
		if i < 0 {
			break
		}
		j := strings.IndexByte(s[i+1:], '%')
		if j < 0 {
			break
		}
		name := s[i+1 : i+1+j]
		b.WriteString(s[:i])
		if v := getenv(name); name != "" && v != "" {
			b.WriteString(v)
		} else {
			b.WriteString(s[i : i+j+2])
		}
		s = s[i+j+2:]
	}
	b.WriteString(s)
	return b.String()
}

// normDir makes two spellings of one folder compare equal.
func normDir(s string, getenv func(string) string) string {
	s = strings.TrimSpace(expandPercent(s, getenv))
	s = strings.Trim(s, `"`)
	s = strings.ReplaceAll(s, "/", `\`)
	return strings.ToLower(strings.TrimRight(s, `\`))
}

// appendPathDir adds dir to a PATH value unless an entry already names it.
// The rest of the value stays byte for byte.
func appendPathDir(current, dir string, getenv func(string) string) (string, bool) {
	want := normDir(dir, getenv)
	for _, e := range strings.Split(current, ";") {
		if e != "" && normDir(e, getenv) == want {
			return current, false
		}
	}
	switch {
	case strings.TrimSpace(current) == "":
		return dir, true
	case strings.HasSuffix(current, ";"):
		return current + dir, true
	}
	return current + ";" + dir, true
}

func dirOf(path string) string {
	if i := strings.LastIndexAny(path, `\/`); i >= 0 {
		return path[:i]
	}
	return "."
}

// firstBenchbar walks the machine PATH, then the user PATH, and returns the
// first folder holding benchbar.exe.
func firstBenchbar(machine, user string, getenv func(string) string, exists func(string) bool) (string, bool) {
	for _, list := range []string{machine, user} {
		for _, e := range strings.Split(list, ";") {
			dir := strings.Trim(strings.TrimSpace(expandPercent(e, getenv)), `"`)
			if dir == "" {
				continue
			}
			if exists(strings.TrimRight(dir, `\/`) + `\benchbar.exe`) {
				return dir, true
			}
		}
	}
	return "", false
}

func pathCheck(sys *System) Check {
	c := Check{ID: "path", Label: "PATH", Fix: "benchbar.exe path install"}
	user, err := sys.Paths.User()
	if err != nil {
		c.Status = "warn"
		c.Fix = `reg query HKCU\Environment /v Path`
		c.Message = fmt.Sprintf("cannot read the user PATH: %v", err)
		return c
	}
	machine, err := sys.Paths.Machine()
	if err != nil {
		c.Status = "warn"
		c.Fix = `reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v Path`
		c.Message = fmt.Sprintf("cannot read the machine PATH: %v", err)
		return c
	}
	exeDir := dirOf(sys.ExePath)
	dir, found := firstBenchbar(machine, user.Value, sys.Getenv, sys.FileExists)
	switch {
	case found && normDir(dir, sys.Getenv) == normDir(exeDir, sys.Getenv):
		c.Status, c.Fix = "ok", ""
		c.Message = "benchbar.exe resolves to " + exeDir
	case found:
		c.Status = "warn"
		c.Message = fmt.Sprintf("another copy comes first: %s\\benchbar.exe (this one is %s)", strings.TrimRight(dir, `\/`), sys.ExePath)
	default:
		c.Status = "warn"
		c.Message = exeDir + " is not on PATH"
	}
	return c
}

func cmdPath(sys *System, sub string) int {
	if sub == "install" {
		user, err := sys.Paths.User()
		if err != nil {
			errorf(sys, "cannot read the user PATH: %v", err)
			return 1
		}
		exeDir := dirOf(sys.ExePath)
		next, changed := appendPathDir(user.Value, exeDir, sys.Getenv)
		if changed {
			expand := user.Expand || !user.Exists
			if err := sys.Paths.SetUser(next, expand); err != nil {
				errorf(sys, "cannot write the user PATH: %v", err)
				return 1
			}
			if err := sys.Broadcast.EnvironmentChanged(); err != nil {
				fmt.Fprintf(sys.Stderr, "benchbar.exe: could not tell running programs about the change: %v\n", err)
			}
			fmt.Fprintf(sys.Stdout, "Added %s to your user PATH. New terminals pick it up; open terminals keep the old PATH.\n", exeDir)
		} else {
			fmt.Fprintf(sys.Stdout, "%s is already on your user PATH.\n", exeDir)
		}
	}
	printCheck(sys.Stdout, pathCheck(sys))
	return 0
}
