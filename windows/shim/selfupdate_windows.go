//go:build windows

package main

import (
	"runtime"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

// machineArch reads the machine's own PROCESSOR_ARCHITECTURE from the
// registry, as install.ps1 does: an emulated amd64 process on an Arm PC
// would report amd64 otherwise.
func machineArch() string {
	k, err := registry.OpenKey(registry.LOCAL_MACHINE, machineEnvKey, registry.QUERY_VALUE)
	if err == nil {
		defer k.Close()
		if v, _, err := k.GetStringValue("PROCESSOR_ARCHITECTURE"); err == nil {
			switch strings.ToUpper(strings.TrimSpace(v)) {
			case "ARM64":
				return "arm64"
			case "AMD64":
				return "amd64"
			}
		}
	}
	return runtime.GOARCH
}

const internetSettingsKey = `Software\Microsoft\Windows\CurrentVersion\Internet Settings`

// systemProxySettings is the manual proxy of Internet Options, when it is on.
func systemProxySettings() (server, override string, ok bool) {
	k, err := registry.OpenKey(registry.CURRENT_USER, internetSettingsKey, registry.QUERY_VALUE)
	if err != nil {
		return "", "", false
	}
	defer k.Close()
	if on, _, err := k.GetIntegerValue("ProxyEnable"); err != nil || on == 0 {
		return "", "", false
	}
	server, _, _ = k.GetStringValue("ProxyServer")
	override, _, _ = k.GetStringValue("ProxyOverride")
	return server, override, strings.TrimSpace(server) != ""
}

// processImages lists the running processes named name, with their full
// program path and creation time. A process this user cannot open is left
// out.
func processImages(name string) []ProcessInfo {
	snap, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return nil
	}
	defer windows.CloseHandle(snap)
	var e windows.ProcessEntry32
	e.Size = uint32(unsafe.Sizeof(e))
	var out []ProcessInfo
	for err = windows.Process32First(snap, &e); err == nil; err = windows.Process32Next(snap, &e) {
		if !strings.EqualFold(windows.UTF16ToString(e.ExeFile[:]), name) {
			continue
		}
		pid := int(e.ProcessID)
		if img, err := (procControl{}).Image(pid); err == nil {
			created, _ := (procControl{}).Created(pid)
			out = append(out, ProcessInfo{Pid: pid, Image: img, Created: created})
		}
	}
	return out
}
