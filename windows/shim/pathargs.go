package main

import (
	"regexp"
	"strings"
)

// Windows paths as arguments. A person at PowerShell types
// `benchbar.exe adopt C:\Users\me\bench`; inside the distro that is not a
// path, and the CLI would take it for a folder named "C:\Users..." under the
// current directory. So an argument that is clearly a Windows path is turned
// into the Linux path before it is forwarded, in Go, with no extra wsl.exe
// call. Only two shapes count:
//
//	X:\... or X:/...                      -> /mnt/x/...
//	\\wsl.localhost\DISTRO\... or \\wsl$\DISTRO\...   -> /... (the same distro only)
//
// Anything else is passed as it is, including a value such as "a:b" and the
// text of a message that happens to hold a path. The arguments after a "--"
// are converted as well: the CLI documents "--" as the end of options before
// bench paths (benchbar ports plan -- PATH), and a drive path is never a
// valid Linux argument, so the conversion cannot break a command that takes
// something else there.
var (
	drivePathRE = regexp.MustCompile(`^([A-Za-z]):([\\/].*)?$`)
	wslUNCRE    = regexp.MustCompile(`^(?:\\\\|//)wsl(?:\.localhost|\$)[\\/]+([^\\/]+)(?:[\\/](.*))?$`)
)

// linuxPathArg converts one argument, or returns it unchanged. distro is the
// target distro: a \\wsl.localhost path of another distro cannot be reached
// from this one and stays as it is.
func linuxPathArg(arg, distro string) string {
	if m := drivePathRE.FindStringSubmatch(arg); m != nil {
		// "C:" alone, or "C:rest" (a drive relative path), is not converted:
		// only X:\ and X:/ are clearly a drive path
		if m[2] == "" {
			return arg
		}
		rest := strings.ReplaceAll(m[2], `\`, "/")
		return "/mnt/" + strings.ToLower(m[1]) + strings.TrimRight(rest, "/")
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
	return arg
}

// linuxPathArgs converts every argument. The value of --name=VALUE is
// converted too, so --bench-dir=C:\bench works like --bench-dir C:\bench.
func linuxPathArgs(args []string, distro string) []string {
	out := make([]string, len(args))
	for i, a := range args {
		out[i] = a
		if strings.HasPrefix(a, "--") {
			if name, val, ok := strings.Cut(a, "="); ok {
				if conv := linuxPathArg(val, distro); conv != val {
					out[i] = name + "=" + conv
				}
				continue
			}
		}
		out[i] = linuxPathArg(a, distro)
	}
	return out
}
