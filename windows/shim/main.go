// benchbar.exe: the Windows shim. It runs the BenchBar CLI inside a WSL
// distro and hands the CLI's exit code back. It never reimplements CLI logic.
package main

import (
	"fmt"
	"os"
	"strings"
)

// version is set with -ldflags "-X main.version=...".
var version = "dev"

func main() {
	os.Exit(run(newSystem(), os.Args[1:]))
}

// run handles the shim's own subcommands (only as the first argument) and
// forwards everything else.
func run(sys *System, args []string) int {
	if len(args) > 0 {
		switch args[0] {
		case "--shim-version":
			fmt.Fprintf(sys.Stdout, "benchbar.exe %s\n", version)
			return 0
		case "adopt-distro":
			return cmdAdoptDistro(sys, args[1:])
		case "wslconfig":
			return cmdWslconfig(sys, args[1:])
		case "keepalive":
			return cmdKeepalive(sys, args[1:])
		case "path":
			// the CLI has its own `path` command; only these two are ours
			if len(args) > 1 && (args[1] == "install" || args[1] == "status") {
				return cmdPath(sys, args[1])
			}
		case "doctor":
			if !hasAny(args[1:], "--json", "--fix-hints") {
				return cmdDoctor(sys, args[1:])
			}
		}
	}
	return cmdForward(sys, args)
}

func hasAny(args []string, want ...string) bool {
	for _, a := range args {
		for _, w := range want {
			if a == w {
				return true
			}
		}
	}
	return false
}

func errorf(sys *System, format string, a ...any) {
	fmt.Fprintf(sys.Stderr, "benchbar.exe: "+format+"\n", a...)
}

func lower(s string) string { return strings.ToLower(s) }
