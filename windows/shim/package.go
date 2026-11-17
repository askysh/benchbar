package main

import (
	"os"
	"path/filepath"
	"strings"
	"time"
)

// PackageInfo says whether this process runs from a Microsoft Store (MSIX)
// package, and its package family name. The name is read at run time and
// never written into the code.
type PackageInfo struct {
	Packaged bool
	Family   string
}

// detectPackage asks Windows. Another platform, or a Windows before 8, is
// never packaged.
func detectPackage() PackageInfo {
	if fam, ok := packageFamilyName(); ok && fam != "" {
		return PackageInfo{Packaged: true, Family: fam}
	}
	return PackageInfo{}
}

// packagedDataDir is the physical folder a packaged process's writes under
// %LOCALAPPDATA%\BenchBar would be redirected to. Opening it directly is not
// redirected, so every path the shim prints is a path that exists. The tray
// uses the same expression.
func packagedDataDir(localAppData, family string) string {
	return filepath.Join(localAppData, "Packages", family, "LocalCache", "Local", "BenchBar")
}

const storeAliasFix = "Settings > Apps > Advanced app settings > App execution aliases, turn on BenchBar"

// aliasDir is %LOCALAPPDATA%\Microsoft\WindowsApps, where app execution
// aliases live. Empty when LOCALAPPDATA is unknown.
func (sys *System) aliasDir() string {
	if sys.LocalAppData == "" {
		return ""
	}
	return strings.TrimRight(sys.LocalAppData, `\/`) + `\Microsoft\WindowsApps`
}

// aliasPath is the benchbar.exe app execution alias of the Store install.
func (sys *System) aliasPath() string {
	if d := sys.aliasDir(); d != "" {
		return d + `\benchbar.exe`
	}
	return ""
}

// programsExe is the benchbar.exe of the one line installer.
func (sys *System) programsExe() string {
	if sys.LocalAppData == "" {
		return ""
	}
	return strings.TrimRight(sys.LocalAppData, `\/`) + `\Programs\BenchBar\benchbar.exe`
}

// exeExists is true for a file or an app execution alias.
func (sys *System) exeExists(path string) bool {
	if path == "" {
		return false
	}
	if sys.FileExists != nil && sys.FileExists(path) {
		return true
	}
	return sys.LstatExists != nil && sys.LstatExists(path)
}

// ownVersionedPath is true for a path in a versioned folder of this
// package's family, such as C:\Program Files\WindowsApps\
// Askysh.BenchBar_0.9.0.0_x64__0f196q1bwh8q6\benchbar.exe. That folder
// changes on every update, so a task that names it goes stale.
func (sys *System) ownVersionedPath(path string) bool {
	if !sys.Package.Packaged {
		return false
	}
	i := strings.LastIndex(sys.Package.Family, "_")
	if i <= 0 {
		return false
	}
	name, publisher := strings.ToLower(sys.Package.Family[:i]), strings.ToLower(sys.Package.Family[i+1:])
	p := strings.ToLower(strings.ReplaceAll(path, "/", `\`))
	parts := strings.Split(p, `\`)
	if len(parts) < 3 {
		return false
	}
	folder := parts[len(parts)-2]
	return strings.Contains(p, `\windowsapps\`) &&
		strings.HasPrefix(folder, name+"_") && strings.HasSuffix(folder, "_"+publisher)
}

// lockConfig takes configLockName, waiting up to two seconds. After that it
// goes on without it. The returned function releases it.
func lockConfig(sys *System) func() {
	if sys.Locks != nil {
		for i := 0; i < 20; i++ {
			release, ok, err := sys.Locks.TryLock(configLockName)
			if err != nil {
				break
			}
			if ok {
				return release
			}
			sys.Sleep(sys.Ctx, 100*time.Millisecond)
		}
	}
	return func() {}
}

// importLegacyConfig copies %LOCALAPPDATA%\BenchBar\config.json into the
// package's data folder once: when packaged, the new folder has no
// config.json and the old one can be read (a read passes through to the real
// file of an earlier unpackaged install). The old folder is never written.
func importLegacyConfig(sys *System) {
	if !sys.Package.Packaged || sys.ConfigDir == "" || sys.LegacyConfigDir == "" ||
		strings.EqualFold(filepath.Clean(sys.ConfigDir), filepath.Clean(sys.LegacyConfigDir)) {
		return
	}
	dst := filepath.Join(sys.ConfigDir, "config.json")
	if _, err := os.Lstat(dst); err == nil {
		return
	}
	data, err := os.ReadFile(filepath.Join(sys.LegacyConfigDir, "config.json"))
	if err != nil || len(data) == 0 {
		return
	}
	defer lockConfig(sys)()
	// the tray may have done it while we waited for the lock
	if _, err := os.Lstat(dst); err == nil {
		return
	}
	_ = writeFileAtomic(dst, data)
}

// twoInstallsCheck warns when a packaged copy runs next to the one line
// installer's copy.
func twoInstallsCheck(sys *System) []Check {
	other := sys.programsExe()
	if !sys.Package.Packaged || other == "" || !sys.exeExists(other) {
		return nil
	}
	return []Check{{
		ID: "two_installs", Label: "Installs", Status: "warn",
		Message: "two BenchBar installs are on this PC: the Microsoft Store one and " + other,
		Fix:     `& ([scriptblock]::Create((irm https://raw.githubusercontent.com/askysh/benchbar/main/install.ps1))) -Uninstall`,
	}}
}

// updateFix says how to get a newer benchbar.exe.
func updateFix(sys *System) string {
	if sys.Package.Packaged {
		return "update BenchBar in the Microsoft Store (Library > Get updates)"
	}
	return "irm https://raw.githubusercontent.com/askysh/benchbar/main/install.ps1 | iex"
}
