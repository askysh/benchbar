package main

import (
	"fmt"
	"strings"
)

const installerLine = `wsl.exe -d %s -- bash -c "curl -fsSL https://raw.githubusercontent.com/askysh/benchbar/main/install.sh | bash"`

// target is the distro and CLI a command goes to.
type target struct {
	distro string // empty when no name is known
	info   *Distro
	cli    string
	prob   *problem
}

func resolveTarget(sys *System, want string) (target, error) {
	cfg, err := loadConfig(sys)
	if err != nil {
		return target{}, err
	}
	t := target{cli: cfg.str("cli_path")}
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
