package main

import "strings"

const trayExe = "BenchBarTray.exe"

// trayChecks covers the optional tray app. They apply only when the tray
// sits next to this benchbar.exe, because the shim alone needs no runtime.
func trayChecks(sys *System) []Check {
	if !sys.FileExists(dirOf(sys.ExePath) + `\` + trayExe) {
		return nil
	}
	dotnet := Check{ID: "dotnet_desktop", Label: ".NET Desktop Runtime", Status: "ok", Message: "version 10 is installed"}
	if !hasDesktopRuntime(sys) {
		dotnet.Status, dotnet.Message = "warn", "version 10 is not installed, the tray will not start"
		dotnet.Fix = "winget install Microsoft.DotNet.DesktopRuntime.10"
	}
	logon := Check{ID: "tray_logon", Label: "Tray at logon", Status: "ok", Message: "not set to open at logon"}
	if sys.FileExists(sys.Getenv("APPDATA") + `\Microsoft\Windows\Start Menu\Programs\Startup\BenchBar Tray.lnk`) {
		logon.Message = "opens at logon"
	}
	return []Check{dotnet, logon}
}

func hasDesktopRuntime(sys *System) bool {
	for _, root := range []string{sys.Getenv("DOTNET_ROOT"), sys.Getenv("ProgramFiles") + `\dotnet`} {
		if root == "" {
			continue
		}
		for _, v := range sys.ListDir(strings.TrimRight(root, `\/`) + `\shared\Microsoft.WindowsDesktop.App`) {
			if strings.HasPrefix(v, "10.") {
				return true
			}
		}
	}
	return false
}
