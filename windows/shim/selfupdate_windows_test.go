//go:build windows

package main

import (
	"runtime"
	"testing"

	"golang.org/x/sys/windows/registry"
)

func TestArchFromRegistry(t *testing.T) {
	for in, want := range map[string]string{"AMD64": "amd64", "amd64": "amd64", " ARM64 ": "arm64", "arm64": "arm64"} {
		if got, ok := archFromRegistry(in); !ok || got != want {
			t.Errorf("%q: %q, %v", in, got, ok)
		}
	}
	for _, in := range []string{"", "x86", "IA64", "ARM"} {
		if got, ok := archFromRegistry(in); ok {
			t.Errorf("%q gave %q", in, got)
		}
	}
}

// The registry value is read for real (HKLM, read only). An arm64 test
// binary can only run on an Arm machine; an amd64 one runs on either, and
// machineArch is what tells them apart.
func TestMachineArchReadsTheMachine(t *testing.T) {
	got := machineArch()
	if got != "amd64" && got != "arm64" {
		t.Fatalf("machineArch = %q", got)
	}
	if runtime.GOARCH == "arm64" && got != "arm64" {
		t.Errorf("an arm64 binary runs on an %s machine?", got)
	}
	k, err := registry.OpenKey(registry.LOCAL_MACHINE, machineEnvKey, registry.QUERY_VALUE)
	if err != nil {
		t.Skip(err)
	}
	defer k.Close()
	v, _, err := k.GetStringValue("PROCESSOR_ARCHITECTURE")
	if err != nil {
		t.Skip(err)
	}
	if want, ok := archFromRegistry(v); ok && want != got {
		t.Errorf("registry says %q, machineArch says %q", want, got)
	}
}

func TestSystemProxySettingsFromATestKey(t *testing.T) {
	useTestKeys(t)
	if _, _, ok := systemProxySettings(); ok {
		t.Error("a missing key reported a proxy")
	}
	k := createTestKey(t, internetSettingsKey)
	if _, _, ok := systemProxySettings(); ok {
		t.Error("no ProxyEnable reported a proxy")
	}
	k.SetDWordValue("ProxyEnable", 0)
	k.SetStringValue("ProxyServer", "proxy.test:3128")
	if _, _, ok := systemProxySettings(); ok {
		t.Error("ProxyEnable=0 reported a proxy")
	}
	k.SetDWordValue("ProxyEnable", 1)
	k.SetStringValue("ProxyOverride", "*.local;<local>")
	server, override, ok := systemProxySettings()
	if !ok || server != "proxy.test:3128" || override != "*.local;<local>" {
		t.Errorf("got %q, %q, %v", server, override, ok)
	}
	k.SetStringValue("ProxyServer", "  ")
	if _, _, ok := systemProxySettings(); ok {
		t.Error("a blank ProxyServer reported a proxy")
	}
}
