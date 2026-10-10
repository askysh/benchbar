package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"fmt"
	"strings"
)

// probeScript reads the facts adopt-distro needs in one call. $0 is the CLI
// name, as in the forwarding wrapper. Nothing in it writes.
const probeScript = `PATH="$HOME/.local/bin:$PATH"; u=$(id -un); ` +
	`printf 'wslconf_b64=%s\n' "$(base64 -w0 /etc/wsl.conf 2>/dev/null)"; ` +
	`printf 'pid1=%s\n' "$(cat /proc/1/comm 2>/dev/null)"; ` +
	`printf 'user=%s\n' "$u"; ` +
	`printf 'benchbar=%s\n' "$(command -v "$0" 2>/dev/null)"; ` +
	`printf 'linger=%s\n' "$(loginctl show-user "$u" -p Linger --value 2>/dev/null)"`

type probeResult struct {
	wslConf string
	pid1    string
	user    string
	bench   string
	linger  string
}

func parseProbe(out string) probeResult {
	var r probeResult
	for _, line := range strings.Split(out, "\n") {
		k, v, ok := strings.Cut(strings.TrimRight(line, "\r"), "=")
		if !ok {
			continue
		}
		switch k {
		case "wslconf_b64":
			if b, err := base64.StdEncoding.DecodeString(strings.TrimSpace(v)); err == nil {
				r.wslConf = string(b)
			}
		case "pid1":
			r.pid1 = strings.TrimSpace(v)
		case "user":
			r.user = strings.TrimSpace(v)
		case "benchbar":
			r.bench = strings.TrimSpace(v)
		case "linger":
			r.linger = strings.ToLower(strings.TrimSpace(v))
		}
	}
	return r
}

func runProbe(sys *System, distro, cli string) (probeResult, error) {
	args := []string{"-d", distro, "--cd", "~", "--exec", "/bin/sh", "-c", probeScript, cli}
	cmd, err := wslCommand(sys, args...)
	if err != nil {
		return probeResult{}, err
	}
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(errb.String())
		if msg == "" {
			msg = err.Error()
		}
		return probeResult{}, fmt.Errorf("%s", msg)
	}
	return parseProbe(out.String()), nil
}

func systemdFix(distro string, hasBoot bool) string {
	if hasBoot {
		return fmt.Sprintf("set systemd=true under [boot] in /etc/wsl.conf (wsl.exe -d %s -- sudo nano /etc/wsl.conf), then wsl.exe --terminate %s", quoteArg(distro), quoteArg(distro))
	}
	return fmt.Sprintf(`wsl.exe -d %s -- sudo sh -c "printf '\n[boot]\nsystemd=true\n' >> /etc/wsl.conf"; wsl.exe --terminate %s`, quoteArg(distro), quoteArg(distro))
}

func lingerFix(distro, user string) string {
	return fmt.Sprintf("wsl.exe -d %s -- loginctl enable-linger %s", quoteArg(distro), user)
}

func probeChecks(t target, r probeResult) []Check {
	distro, cli := t.distro, t.cli
	var cs []Check
	conf := parseINI([]byte(r.wslConf))
	v, _ := conf.get("boot", "systemd")
	confOn := strings.EqualFold(v, "true")
	sd := Check{ID: "systemd", Label: "systemd", Status: "ok",
		Message: "enabled in /etc/wsl.conf and running as pid 1"}
	switch {
	case confOn && r.pid1 == "systemd":
	case confOn:
		sd.Status = "fail"
		sd.Message = fmt.Sprintf("enabled in /etc/wsl.conf, but pid 1 is %q: the distro has not restarted since", r.pid1)
		sd.Fix = fmt.Sprintf("wsl.exe --terminate %s", quoteArg(distro))
	default:
		sd.Status = "fail"
		sd.Message = "[boot] systemd=true is not set in /etc/wsl.conf"
		sd.Fix = systemdFix(distro, conf.hasSection("boot"))
	}
	cs = append(cs, sd)

	bc := Check{ID: "benchbar", Label: "benchbar", Status: "ok", Message: "found at " + r.bench}
	if r.bench == "" {
		bc.Status = "fail"
		bc.Message = fmt.Sprintf("%s is not found in %s", cli, distro)
		bc.Fix = missingCLIFix(t)
	}
	cs = append(cs, bc)

	user := r.user
	if user == "" {
		user = "<user>"
	}
	lc := Check{ID: "linger", Label: "Linger", Status: "ok",
		Message: fmt.Sprintf("enabled for %s: benches keep running after the last session ends", user)}
	switch r.linger {
	case "yes":
	case "no":
		lc.Status = "warn"
		lc.Message = fmt.Sprintf("off for %s: benches stop when the last session ends", user)
		lc.Fix = lingerFix(distro, user)
	default:
		lc.Status = "warn"
		lc.Message = fmt.Sprintf("cannot read the linger setting of %s (is systemd running?)", user)
		lc.Fix = lingerFix(distro, user)
	}
	return append(cs, lc)
}

func replaceCheck(cs []Check, c Check) {
	for i := range cs {
		if cs[i].ID == c.ID {
			cs[i] = c
		}
	}
}

func cmdAdoptDistro(sys *System, args []string) int {
	p, err := parseFlags(args, []string{"--yes", "--json"}, nil)
	if err == nil && len(p.pos) > 1 {
		err = fmt.Errorf("unexpected argument %s", p.pos[1])
	}
	if err != nil {
		errorf(sys, "%v. usage: benchbar.exe adopt-distro [NAME] [--yes] [--json]", err)
		return 1
	}
	asJSON, yes := p.bools["--json"], p.bools["--yes"]
	want := ""
	if len(p.pos) == 1 {
		want = p.pos[0]
	}
	t, err := resolveTarget(sys, want)
	if err != nil {
		errorf(sys, "%v", err)
		return 1
	}

	var checks []Check
	var probe probeResult
	probed := false
	switch {
	case t.prob != nil:
		checks = append(checks, Check{ID: "distro", Label: "Distro", Status: "fail",
			Message: t.prob.Msg, Fix: t.prob.Fix})
	case t.distro == "":
		checks = append(checks, Check{ID: "distro", Label: "Distro", Status: "fail",
			Message: "no distro name is known and the WSL registry cannot be read",
			Fix:     "benchbar.exe adopt-distro <NAME> (wsl.exe --list --verbose shows the names)"})
	default:
		if t.info == nil {
			checks = append(checks,
				Check{ID: "distro", Label: "Distro", Status: "warn", Message: "cannot read the WSL registry, assuming " + t.distro + " is registered", Fix: listDistros},
				Check{ID: "wsl2", Label: "WSL version", Status: "warn", Message: "unknown, the WSL registry cannot be read", Fix: listDistros})
		} else {
			checks = append(checks, Check{ID: "distro", Label: "Distro", Status: "ok", Message: t.distro + " is registered"})
			w := Check{ID: "wsl2", Label: "WSL version", Status: "ok", Message: "runs as WSL 2"}
			if t.info.Version != 2 {
				w.Status = "fail"
				w.Message = fmt.Sprintf("runs as WSL %d, systemd needs WSL 2", t.info.Version)
				w.Fix = fmt.Sprintf("wsl.exe --set-version %s 2", quoteArg(t.distro))
			}
			checks = append(checks, w)
		}
		probe, err = runProbe(sys, t.distro, t.cli)
		if err != nil {
			checks = append(checks, Check{ID: "probe", Label: "WSL access", Status: "fail",
				Message: fmt.Sprintf("cannot run a command in %s: %v", t.distro, err),
				Fix:     fmt.Sprintf("wsl.exe -d %s -- true", quoteArg(t.distro))})
		} else {
			probed = true
			checks = append(checks, probeChecks(t, probe)...)
		}
	}

	if !asJSON {
		fmt.Fprintf(sys.Stdout, "\nWSL DISTRO\n")
		printChecks(sys.Stdout, checks)
	}

	if probed && probe.linger == "no" && probe.user != "" {
		if sys.offerLinger(yes, asJSON, probe.user, t.distro) {
			c, _ := applyLinger(sys, t, probe.user)
			replaceCheck(checks, c)
			if !asJSON {
				fmt.Fprintf(sys.Stdout, "\n  After the change:\n")
				printCheck(sys.Stdout, c)
			}
		}
	}

	recorded := false
	if !hasFail(checks) && t.distro != "" {
		cfg, err := loadConfig(sys)
		if err == nil {
			cfg.setStr("distro", t.distro)
			err = cfg.save()
		}
		if err != nil {
			errorf(sys, "cannot record the distro: %v", err)
			return 1
		}
		recorded = true
		if !asJSON {
			fmt.Fprintf(sys.Stdout, "\nRecorded %s in %s\n", t.distro, cfg.path)
		}
	}

	if asJSON {
		if checks == nil {
			checks = []Check{}
		}
		printJSON(sys.Stdout, struct {
			Distro   string  `json:"distro"`
			Recorded bool    `json:"recorded"`
			Checks   []Check `json:"checks"`
		}{t.distro, recorded, checks})
	} else {
		printSummary(sys.Stdout, checks)
	}
	if hasFail(checks) {
		return 1
	}
	return 0
}

// offerLinger decides whether to enable linger: --yes, or a yes typed at the
// prompt. The prompt only appears on a terminal and never with --json.
func (sys *System) offerLinger(yes, asJSON bool, user, distro string) bool {
	if yes {
		return true
	}
	if asJSON || !sys.StdinIsTerminal {
		return false
	}
	fmt.Fprintf(sys.Stdout, "\nEnable linger for %s in %s now? [y/N] ", user, distro)
	line, _ := bufio.NewReader(sys.Stdin).ReadString('\n')
	switch strings.ToLower(strings.TrimSpace(line)) {
	case "y", "yes":
		return true
	}
	return false
}

// applyLinger runs the one fix adopt-distro may apply, then reads the
// setting again. The returned check is the linger line afterwards.
func applyLinger(sys *System, t target, user string) (Check, bool) {
	warn := probeChecks(t, probeResult{linger: "no", user: user})[2]
	cmd, err := wslCommand(sys, "-d", t.distro, "--exec", "loginctl", "--no-ask-password", "enable-linger", user)
	if err != nil {
		warn.Message += fmt.Sprintf(" (enabling failed: %v)", err)
		return warn, false
	}
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	if err := cmd.Run(); err != nil {
		detail := strings.TrimSpace(out.String())
		if detail == "" {
			detail = err.Error()
		}
		warn.Message += fmt.Sprintf(" (enabling failed: %s)", detail)
		return warn, false
	}
	r, err := runProbe(sys, t.distro, t.cli)
	if err != nil {
		warn.Message += fmt.Sprintf(" (enabled, but the recheck failed: %v)", err)
		return warn, false
	}
	return probeChecks(t, r)[2], true
}
