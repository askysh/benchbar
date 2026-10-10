package main

import "fmt"

func distroCheck(t target) Check {
	c := Check{ID: "distro", Label: "WSL distro"}
	switch {
	case t.prob != nil:
		c.Status, c.Message, c.Fix = "fail", t.prob.Msg, t.prob.Fix
	case t.info == nil:
		c.Status = "warn"
		c.Message = "cannot read the WSL registry, so the distro is not checked"
		c.Fix = listDistros
	case t.info.Version != 2:
		c.Status = "fail"
		c.Message = fmt.Sprintf("%s runs as WSL %d, benches need WSL 2", t.distro, t.info.Version)
		c.Fix = fmt.Sprintf("wsl.exe --set-version %s 2", t.distro)
	default:
		c.Status = "ok"
		c.Message = t.distro + " is registered and runs WSL 2"
	}
	return c
}

// cmdDoctor prints the Windows checks, then the CLI's own doctor.
func cmdDoctor(sys *System, rest []string) int {
	t, err := resolveTarget(sys, "")
	if err != nil {
		errorf(sys, "%v", err)
		return 1
	}
	checks := []Check{pathCheck(sys), distroCheck(t)}
	if _, rep, err := readWslconfig(sys); err != nil {
		checks = append(checks, Check{ID: "wslconfig", Label: ".wslconfig", Status: "warn", Message: err.Error(), Fix: `type "%USERPROFILE%\.wslconfig"`})
	} else {
		checks = append(checks, idleCheck(rep))
	}
	checks = append(checks, queryKeepalive(sys).Checks...)

	fmt.Fprint(sys.Stdout, "\nWINDOWS\n")
	printChecks(sys.Stdout, checks)
	fmt.Fprintln(sys.Stdout)

	if t.prob != nil {
		t.prob.print(sys)
		return 1
	}
	code := forward(sys, t, append([]string{"doctor"}, rest...))
	if code == 0 && hasFail(checks) {
		return 1
	}
	return code
}
