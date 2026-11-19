//go:build windows

package main

import (
	"os"
	"strings"
	"testing"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

// SHELLEXECUTEINFOW is 112 bytes on a 64 bit Windows (amd64 and arm64) and
// 60 on a 32 bit one. A wrong field type moves hProcess, and the elevated
// install then waits on a garbage handle, so the offsets are pinned too.
func TestShellExecuteInfoLayout(t *testing.T) {
	var i shellExecuteInfo
	wantSize, wantProcess, wantShow := uintptr(112), uintptr(104), uintptr(48)
	if unsafe.Sizeof(uintptr(0)) == 4 {
		wantSize, wantProcess, wantShow = 60, 56, 28
	}
	if got := unsafe.Sizeof(i); got != wantSize {
		t.Errorf("sizeof(shellExecuteInfo) = %d, want %d", got, wantSize)
	}
	if got := unsafe.Offsetof(i.Process); got != wantProcess {
		t.Errorf("offset of Process = %d, want %d", got, wantProcess)
	}
	if got := unsafe.Offsetof(i.Show); got != wantShow {
		t.Errorf("offset of Show = %d, want %d", got, wantShow)
	}
}

func TestShellExecuteExportsResolve(t *testing.T) {
	for name, p := range map[string]interface{ Find() error }{
		"ShellExecuteExW":           procShellExecuteExW,
		"AllowSetForegroundWindow":  procAllowSetForeground,
		"IsProcessorFeaturePresent": procIsProcessorFeaturePresent,
		"GetTickCount64":            procGetTickCount64,
	} {
		if err := p.Find(); err != nil {
			t.Errorf("%s: %v", name, err)
		}
	}
	// the call the elevator makes before ShellExecuteEx must work on this thread
	if err := windows.CoInitializeEx(0, windows.COINIT_APARTMENTTHREADED|windows.COINIT_DISABLE_OLE1DDE); err == nil {
		windows.CoUninitialize()
	}
}

// The elevator itself is never started here: runas shows a UAC prompt. The
// same code path runs with the open verb and the no UI flag on a program the
// test owns (the test binary as the child), so the struct, the strings and
// the process handle are real, and nothing is elevated.
func TestShellExecuteStartsAChildAndReportsItsExitCode(t *testing.T) {
	t.Setenv(helperEnv, "exit7")
	proc, err := shellExecute("open", seeMaskFlagNoUI, os.Args[0], nil)
	if err != nil {
		if os.Getenv("GITHUB_ACTIONS") == "true" {
			t.Fatalf("ShellExecuteEx on a hosted runner: %v", err)
		}
		t.Skipf("ShellExecuteEx is not usable in this session: %v", err)
	}
	defer proc.Close()
	done, code, err := proc.Wait(30 * time.Second)
	if err != nil || !done {
		t.Fatalf("Wait = %v, %d, %v", done, code, err)
	}
	if code != 7 {
		t.Errorf("exit code %d, want 7", code)
	}
}

func TestShellExecuteRefusesAnEmbeddedNul(t *testing.T) {
	if _, err := shellExecute("open", seeMaskFlagNoUI, "a\x00b", nil); err == nil {
		t.Error("a path with a NUL byte was accepted")
	}
}

func TestWinProcWaitTimesOutThenSeesTheEnd(t *testing.T) {
	cmd := startHelper(t, "sleep")
	h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION|windows.SYNCHRONIZE, false, uint32(cmd.Process.Pid))
	if err != nil {
		t.Fatal(err)
	}
	p := &winProc{h: h}
	defer p.Close()
	if done, _, err := p.Wait(100 * time.Millisecond); err != nil || done {
		t.Fatalf("a running child: done=%v err=%v", done, err)
	}
	cmd.Process.Kill()
	done, code, err := p.Wait(10 * time.Second)
	if err != nil || !done {
		t.Fatalf("after kill: done=%v code=%d err=%v", done, code, err)
	}
	if code != 1 {
		t.Errorf("Process.Kill exits with 1 on Windows, got %d", code)
	}
}

func TestJoinWindowsArgs(t *testing.T) {
	got := joinWindowsArgs([]string{"wsl", "--install", `C:\Program Files\x`, "a\tb", ""})
	want := `wsl --install "C:\Program Files\x" "a	b" `
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestHostFacts(t *testing.T) {
	h := winHost{}
	build, err := h.WindowsBuild()
	if err != nil || build < 17763 {
		t.Errorf("WindowsBuild = %d, %v", build, err)
	}
	name, err := h.ProductName()
	if err != nil || !strings.HasPrefix(name, "Windows") {
		t.Errorf("ProductName = %q, %v", name, err)
	}
	if build >= 22000 && strings.Contains(name, "Windows 10") {
		t.Errorf("build %d is Windows 11 but ProductName is %q", build, name)
	}
	boot, err := h.BootTime()
	if err != nil {
		t.Fatal(err)
	}
	if boot.After(time.Now()) || boot.Before(time.Now().Add(-5*365*24*time.Hour)) {
		t.Errorf("BootTime %v is not in the last five years", boot)
	}
	if _, err := h.VirtualizationEnabled(); err != nil {
		t.Errorf("VirtualizationEnabled: %v", err)
	}
	_ = h.IsAdmin() // either answer is right on a CI runner or a dev PC
}

func TestOSHostWiresTheWindowsTypes(t *testing.T) {
	h, e := osHost()
	if _, ok := h.(winHost); !ok {
		t.Errorf("osHost host is %T", h)
	}
	if _, ok := e.(winElevator); !ok {
		t.Errorf("osHost elevator is %T", e)
	}
}
