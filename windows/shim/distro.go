package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// listDistros shows the names a --distro or adopt-distro argument takes.
const listDistros = "wsl.exe --list --verbose"

const installerBase = "https://raw.githubusercontent.com/askysh/benchbar/"

// releaseRE matches the version of a release build (X.Y.Z). A dev build, a
// commit id or a pull request build (0.0.0-pr12) is not one.
var releaseRE = regexp.MustCompile(`^\d+\.\d+\.\d+$`)

// installerURL is the installer of this shim's own release, so the CLI in
// the distro matches the shim; a dev build uses main.
func installerURL() string {
	if releaseRE.MatchString(version) {
		return installerBase + "v" + version + "/install.sh"
	}
	return installerBase + "main/install.sh"
}

// installerPipe is the one shell line that downloads the installer and runs
// it. pipefail makes a failed download (curl exit 22 on a 404) the exit code
// of the whole line; without it the pipe would end with bash's 0. The line
// is for bash, which every distro BenchBar supports has, and the commands
// that run it name bash explicitly. A release build passes --version, so
// install.sh checks out that release of the CLI too.
func installerPipe() string {
	line := "set -o pipefail; curl -fsSL " + installerURL() + " | bash"
	if releaseRE.MatchString(version) {
		line += " -s -- --version v" + version
	}
	return line
}

// installerCommand runs the installer inside the distro; without a name it
// goes to the default distro.
func installerCommand(distro string) string {
	dash := ""
	if distro != "" {
		dash = "-d " + quoteArg(distro) + " "
	}
	return fmt.Sprintf(`wsl.exe %s-- bash -c "%s"`, dash, installerPipe())
}

// quoteArg quotes a distro name for a command the user pastes into cmd or
// PowerShell. Plain names stay as they are.
func quoteArg(s string) string {
	plain := s != ""
	for _, r := range s {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '.' || r == '_' || r == '-' || r > 127) {
			plain = false
		}
	}
	if plain {
		return s
	}
	return `"` + strings.ReplaceAll(s, `"`, `\"`) + `"`
}

// missingCLIFix is the fix for a CLI that is not found in the distro. The
// installer only provides "benchbar", so a custom cli_path is a config error.
func missingCLIFix(t target) string {
	if t.cli != "" && t.cli != "benchbar" {
		p := t.cfgPath
		if p == "" {
			p = "config.json"
		}
		return fmt.Sprintf(`correct or remove "cli_path" (%s) in %s`, t.cli, p)
	}
	return installerCommand(t.distro)
}

// target is the distro and CLI a command goes to.
type target struct {
	distro  string // empty when no name is known
	info    *Distro
	cli     string
	cfgPath string // config.json, for messages
	prob    *problem
}

func resolveTarget(sys *System, want string) (target, error) {
	return resolveTargetWith(sys, want, false)
}

// resolveTargetWith is resolveTarget; with lenient a config.json that is not
// valid JSON is ignored when a distro name is given. adopt-distro NAME uses
// it, because it is the command that writes the file again.
func resolveTargetWith(sys *System, want string, lenient bool) (target, error) {
	cfg, err := loadConfig(sys)
	var ce *configError
	if errors.As(err, &ce) && want != "" && lenient {
		// adopt-distro NAME repairs a broken config.json, so it must get past it
		cfg, err = &configFile{path: ce.path, m: map[string]json.RawMessage{}}, nil
	}
	if err != nil {
		return target{}, err
	}
	t := target{cli: cfg.str("cli_path"), cfgPath: cfg.path}
	if t.cli == "" {
		t.cli = "benchbar"
	}
	if want == "" {
		want = cfg.str("distro")
	}
	t.distro, t.info, t.prob = resolveDistro(sys, want)
	return t, nil
}

// resolveDistro checks WANT (or the WSL default when empty) against the
// registry. When the registry cannot be read the check is skipped.
func resolveDistro(sys *System, want string) (string, *Distro, *problem) {
	list, err := sys.Distros.Distros()
	if err != nil {
		return want, nil, nil
	}
	if want != "" {
		for i := range list {
			if strings.EqualFold(list[i].Name, want) {
				return list[i].Name, &list[i], nil
			}
		}
		return "", nil, &problem{
			Msg: fmt.Sprintf("WSL distro %q is not installed", want),
			Fix: "benchbar.exe adopt-distro <NAME> (wsl.exe --list --verbose shows the names)",
		}
	}
	if len(list) == 0 {
		return "", nil, &problem{Msg: "no WSL distro is installed", Fix: "benchbar.exe setup check (it installs Ubuntu 24.04; by hand: wsl.exe --install -d Ubuntu-24.04)"}
	}
	var usable []int
	for i, d := range list {
		if !isToolDistro(d.Name) {
			usable = append(usable, i)
		}
	}
	switch {
	case len(usable) == 0:
		return "", nil, &problem{
			Msg: "the only WSL distros are container tool distros (" + names(list) + "), which BenchBar never uses",
			Fix: "benchbar.exe setup check (it installs Ubuntu 24.04), or benchbar.exe adopt-distro NAME for a distro you added yourself",
		}
	case len(usable) == 1:
		return list[usable[0]].Name, &list[usable[0]], nil
	}
	// several usable distros: the WSL default stays the choice, unless
	// it is not a usable one
	var rest []Distro
	for _, i := range usable {
		if list[i].Default {
			return list[i].Name, &list[i], nil
		}
		rest = append(rest, list[i])
	}
	return "", nil, &problem{
		Msg: "the WSL default distro is not one BenchBar can use and there is more than one other (" + names(rest) + ")",
		Fix: "benchbar.exe adopt-distro NAME (wsl.exe --list --verbose shows the names)",
	}
}

// toolDistroPrefixes are the distros that container tools register for
// themselves. BenchBar never picks one on its own.
var toolDistroPrefixes = []string{"docker-desktop", "rancher-desktop", "podman-machine"}

func isToolDistro(name string) bool {
	n := strings.ToLower(name)
	for _, p := range toolDistroPrefixes {
		if strings.HasPrefix(n, p) {
			return true
		}
	}
	return false
}

func names(list []Distro) string {
	var out []string
	for _, d := range list {
		out = append(out, d.Name)
	}
	return strings.Join(out, ", ")
}

// The one Linux release BenchBar supports in a distro.
const (
	supportedOSID  = "ubuntu"
	supportedOSVer = "24.04"
)

// osProblem is the message when the probe shows a distro that is not Ubuntu
// 24.04, or "" when it is, or when the probe could not read the release.
func osProblem(distro string, r probeResult) string {
	if r.osID == "" || (r.osID == supportedOSID && r.osVer == supportedOSVer) {
		return ""
	}
	name := r.osName
	if name == "" {
		name = r.osID
	}
	return fmt.Sprintf("BenchBar supports Ubuntu %s; %s is %s", supportedOSVer, distro, strings.TrimSpace(name+" "+r.osVer))
}

// osFix is the fix for a distro that is not Ubuntu 24.04.
func osFix() string {
	return "benchbar.exe setup run distro_install --distro Ubuntu-24.04 installs it next to this one, or benchbar.exe adopt-distro NAME uses another distro that is Ubuntu 24.04"
}

// releaseVersion parses the X.Y.Z in a version line such as "benchbar 0.8.1".
func releaseVersion(line string) ([3]int, bool) {
	var v [3]int
	m := versionRE.FindStringSubmatch(line)
	if m == nil {
		return v, false
	}
	for i := range v {
		v[i], _ = strconv.Atoi(m[i+1])
	}
	return v, true
}

func versionLess(a, b [3]int) bool {
	for i := range a {
		if a[i] != b[i] {
			return a[i] < b[i]
		}
	}
	return false
}

// cliSkew compares the CLI version the distro reports with the shim's own
// release version. A dev build of the shim, and a version line that cannot
// be read, never report a skew. older is true when the CLI is older than
// the shim, newer when it is newer.
func cliSkew(cliLine string) (cli string, older, newer bool) {
	if !releaseRE.MatchString(version) {
		return "", false, false
	}
	have, ok := releaseVersion(cliLine)
	if !ok {
		return "", false, false
	}
	want, _ := releaseVersion(version)
	cli = fmt.Sprintf("%d.%d.%d", have[0], have[1], have[2])
	return cli, versionLess(have, want), versionLess(want, have)
}
