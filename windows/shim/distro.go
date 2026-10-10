package main

import (
	"fmt"
	"strings"
)

// listDistros shows the names a --distro or adopt-distro argument takes.
const listDistros = "wsl.exe --list --verbose"

const installerURL = "https://raw.githubusercontent.com/askysh/benchbar/main/install.sh"

// installerCommand runs the installer inside the distro; without a name it
// goes to the default distro.
func installerCommand(distro string) string {
	dash := ""
	if distro != "" {
		dash = "-d " + quoteArg(distro) + " "
	}
	return fmt.Sprintf(`wsl.exe %s-- bash -c "curl -fsSL %s | bash"`, dash, installerURL)
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
	cfg, err := loadConfig(sys)
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
		return "", nil, &problem{Msg: "no WSL distro is installed", Fix: "wsl.exe --install -d Ubuntu-24.04"}
	}
	pick := -1
	for i, d := range list {
		if d.Default {
			pick = i
			break
		}
	}
	if pick < 0 {
		for i, d := range list {
			if !strings.HasPrefix(strings.ToLower(d.Name), "docker-desktop") {
				pick = i
				break
			}
		}
	}
	if pick < 0 {
		pick = 0
	}
	return list[pick].Name, &list[pick], nil
}
