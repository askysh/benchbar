package main

import "strings"

const (
	trayExe      = "BenchBarTray.exe"
	trayShortcut = "BenchBar Tray.lnk"
)

// startupDisabled is true when Windows has the startup entry turned off. The
// value under HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\
// StartupApproved\StartupFolder starts with an odd byte (03) for a disabled
// entry; 02, or no value at all, means enabled.
func startupDisabled(sys *System, name string) bool {
	if sys.StartupApproved == nil {
		return false
	}
	v, err := sys.StartupApproved(name)
	return err == nil && len(v) > 0 && v[0]&1 == 1
}

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
	if sys.FileExists(sys.Getenv("APPDATA") + `\Microsoft\Windows\Start Menu\Programs\Startup\` + trayShortcut) {
		logon.Message = "opens at logon"
		if startupDisabled(sys, trayShortcut) {
			// the shortcut is there, but Windows keeps it from running
			logon.Status = "warn"
			logon.Message = "Windows has turned it off: Settings > Apps > Startup"
			logon.Fix = "start ms-settings:startupapps"
		}
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
