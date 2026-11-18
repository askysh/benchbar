package main

import (
	"regexp"
	"strings"
)

// Windows paths as arguments. A person at PowerShell types
// `benchbar.exe adopt C:\Users\me\bench`; inside the distro that is not a
// path, and the CLI would take it for a folder named "C:\Users..." under the
// current directory. So an argument that is clearly a Windows path is turned
// into the Linux path before it is forwarded. Three shapes count:
//
//	X:\... or X:/...                      -> MOUNT/x/... (the mount of the drive, /mnt/x by default)
//	\\wsl.localhost\DISTRO\... or \\wsl$\DISTRO\...   -> /... (the same distro only)
//	.\x or ..\x                           -> ./x or ../x (against the current folder, which is forwarded)
//
// Anything else is passed as it is, including a value such as "a:b" and the
// text of a message that happens to hold a path. The arguments after a "--"
// are converted as well: the CLI documents "--" as the end of options before
// bench paths (benchbar ports plan -- PATH), and a drive path is never a
// valid Linux argument, so the conversion cannot break a command that takes
// something else there.
//
// A distro can mount the drives elsewhere than /mnt ([automount] root in
// /etc/wsl.conf), so the mount of a drive is asked from wslpath in the distro
// (driveRoots), one call for all the drives of a command, and only when an
// argument holds a drive path. /mnt/x is the answer when the call fails.
var (
	drivePathRE = regexp.MustCompile(`^([A-Za-z]):([\\/].*)?$`)
	wslUNCRE    = regexp.MustCompile(`^(?:\\\\|//)wsl(?:\.localhost|\$)[\\/]+([^\\/]+)(?:[\\/](.*))?$`)
	dotSlashRE  = regexp.MustCompile(`^\.\.?\\`)
)

// driveRoots maps a lower case drive letter to the Linux mount of the drive,
// such as "c" to "/mnt/c". A drive that is not in the map is /mnt/<letter>.
type driveRoots map[string]string

func (r driveRoots) root(letter string) string {
	l := strings.ToLower(letter)
	if p := r[l]; p != "" {
		return p
	}
	return "/mnt/" + l
}

// linuxPathArg converts one argument, or returns it unchanged. distro is the
// target distro: a \\wsl.localhost path of another distro cannot be reached
// from this one and stays as it is.
func linuxPathArg(arg, distro string) string {
	return linuxPathArgWith(arg, distro, nil)
}

func linuxPathArgWith(arg, distro string, roots driveRoots) string {
	if m := drivePathRE.FindStringSubmatch(arg); m != nil {
		// "C:" alone, or "C:rest" (a drive relative path), is not converted:
		// only X:\ and X:/ are clearly a drive path
		if m[2] == "" {
			return arg
		}
		rest := strings.ReplaceAll(m[2], `\`, "/")
		return roots.root(m[1]) + strings.TrimRight(rest, "/")
	}
	if m := wslUNCRE.FindStringSubmatch(arg); m != nil {
		if distro == "" || !strings.EqualFold(m[1], distro) {
			return arg
		}
		rest := strings.TrimRight(strings.ReplaceAll(m[2], `\`, "/"), "/")
		if rest == "" {
			return "/"
		}
		return "/" + strings.TrimLeft(rest, "/")
	}
	if dotSlashRE.MatchString(arg) {
		return strings.ReplaceAll(arg, `\`, "/")
	}
	return arg
}

// linuxPathArgs converts every argument. The value of --name=VALUE is
// converted too, so --bench-dir=C:\bench works like --bench-dir C:\bench.
func linuxPathArgs(args []string, distro string) []string {
	return linuxPathArgsWith(args, distro, nil)
}

func linuxPathArgsWith(args []string, distro string, roots driveRoots) []string {
	out := make([]string, len(args))
	for i, a := range args {
		out[i] = a
		if strings.HasPrefix(a, "--") {
			if name, val, ok := strings.Cut(a, "="); ok {
				if conv := linuxPathArgWith(val, distro, roots); conv != val {
					out[i] = name + "=" + conv
				}
				continue
			}
		}
		out[i] = linuxPathArgWith(a, distro, roots)
	}
	return out
}

// driveLettersIn lists the drives (lower case, once each) that an argument
// names with a convertible drive path.
func driveLettersIn(args []string) []string {
	var out []string
	seen := map[string]bool{}
	for _, a := range args {
		if strings.HasPrefix(a, "--") {
			if _, val, ok := strings.Cut(a, "="); ok {
				a = val
			}
		}
		if m := drivePathRE.FindStringSubmatch(a); m != nil && m[2] != "" {
			if l := strings.ToLower(m[1]); !seen[l] {
				seen[l] = true
				out = append(out, l)
			}
		}
	}
	return out
}

// probeDriveRoots asks the distro where it mounts the drives in letters.
// wslpath knows [automount] root and the options of the distro. Any failure
// leaves the default /mnt/x, so a command is never stopped by the probe.
func probeDriveRoots(sys *System, distro string, letters []string) driveRoots {
	if len(letters) == 0 {
		return nil
	}
	var a []string
	if distro != "" {
		a = append(a, "-d", distro)
	}
	a = append(a, "--exec", "/bin/sh", "-c", `for d; do wslpath -a -u -- "$d:\\" 2>/dev/null || echo; done`, "sh")
	a = append(a, letters...)
	res, err := wslExec(sys, "", a...)
	if err != nil || res.Code != 0 {
		return nil
	}
	roots := driveRoots{}
	lines := strings.Split(strings.ReplaceAll(res.Stdout, "\r", ""), "\n")
	for i, l := range letters {
		if i >= len(lines) {
			break
		}
		if p := strings.TrimRight(strings.TrimSpace(lines[i]), "/"); strings.HasPrefix(p, "/") {
			roots[l] = p
		}
	}
	return roots
}
