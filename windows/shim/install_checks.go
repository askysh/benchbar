package main

import (
	"os"
	"path/filepath"
	"strings"
)

const installManifest = ".installed-files.txt"

// installedFiles reads the list install.ps1 wrote next to benchbar.exe: one
// path relative to the install folder per line (UTF-8, CRLF). It returns nil
// when there is no list, so a copy that was not made by the installer says
// nothing.
func installedFiles(sys *System) []string {
	if sys.ExePath == "" {
		return nil
	}
	data, err := os.ReadFile(filepath.Join(dirOf(sys.ExePath), installManifest))
	if err != nil {
		return nil
	}
	var out []string
	for _, l := range strings.Split(string(data), "\n") {
		if l = strings.TrimSpace(strings.TrimPrefix(l, "\xef\xbb\xbf")); l != "" {
			out = append(out, l)
		}
	}
	return out
}

// installRecordChecks warns when a file the installer put in the install
// folder is gone: the tray, or the program the keepalive task runs. A
// security product that quarantines an unsigned program leaves exactly this.
func installRecordChecks(sys *System, ka keepaliveInfo) []Check {
	listed := installedFiles(sys)
	if len(listed) == 0 {
		return nil
	}
	dir := dirOf(sys.ExePath)
	in := func(rel string) bool {
		for _, l := range listed {
			if strings.EqualFold(strings.ReplaceAll(l, "/", `\`), rel) {
				return true
			}
		}
		return false
	}
	var missing []string
	add := func(rel string) {
		if in(rel) && !sys.FileExists(dir+`\`+rel) {
			for _, m := range missing {
				if strings.EqualFold(m, rel) {
					return
				}
			}
			missing = append(missing, rel)
		}
	}
	add(trayExe)
	// the keepalive target, when it is a file of this install folder
	if ka.Exe != "" && strings.EqualFold(normDir(dirOf(ka.Exe), sys.Getenv), normDir(dir, sys.Getenv)) {
		add(ka.Exe[strings.LastIndexAny(ka.Exe, `\/`)+1:])
	}
	if len(missing) == 0 {
		return nil
	}
	return []Check{{
		ID: "install_files", Label: "Installed files", Status: "warn",
		Message: strings.Join(missing, ", ") + " is missing from " + dir + ", although the installer put it there. A security product may have removed it: open Windows Security > Virus & threat protection > Protection history",
		Fix:     "restore the file in Windows Security > Protection history (allow it), then run install.ps1 again",
	}}
}
