//go:build windows

package main

import (
	"errors"
	"fmt"
	"path/filepath"
	"runtime"
	"strings"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

type winHost struct{}

func osHost() (HostInfo, Elevator) { return winHost{}, winElevator{} }

func (winHost) WindowsBuild() (int, error) {
	v := windows.RtlGetVersion()
	if v == nil {
		return 0, errors.New("RtlGetVersion returned nothing")
	}
	return int(v.BuildNumber), nil
}

var (
	kernel32                      = windows.NewLazySystemDLL("kernel32.dll")
	procIsProcessorFeaturePresent = kernel32.NewProc("IsProcessorFeaturePresent")
	procGetTickCount64            = kernel32.NewProc("GetTickCount64")
	shell32                       = windows.NewLazySystemDLL("shell32.dll")
	procShellExecuteExW           = shell32.NewProc("ShellExecuteExW")
	procAllowSetForeground        = windows.NewLazySystemDLL("user32.dll").NewProc("AllowSetForegroundWindow")
)

// pfVirtFirmwareEnabled is PF_VIRT_FIRMWARE_ENABLED (21): virtualization is
// enabled in the firmware and made available by the operating system.
const pfVirtFirmwareEnabled = 21

func (winHost) VirtualizationEnabled() (bool, error) {
	if err := procIsProcessorFeaturePresent.Find(); err != nil {
		return false, err
	}
	r, _, _ := procIsProcessorFeaturePresent.Call(pfVirtFirmwareEnabled)
	return r != 0, nil
}

func (winHost) BootTime() (time.Time, error) {
	if err := procGetTickCount64.Find(); err != nil {
		return time.Time{}, err
	}
	ms, _, _ := procGetTickCount64.Call()
	return time.Now().Add(-time.Duration(ms) * time.Millisecond), nil
}

func (winHost) IsAdmin() bool { return windows.GetCurrentProcessToken().IsElevated() }

// shellExecuteInfo is SHELLEXECUTEINFOW.
type shellExecuteInfo struct {
	Size       uint32
	Mask       uint32
	Hwnd       windows.Handle
	Verb       *uint16
	File       *uint16
	Parameters *uint16
	Directory  *uint16
	Show       int32
	InstApp    windows.Handle
	IDList     uintptr
	Class      *uint16
	HkeyClass  windows.Handle
	HotKey     uint32
	Icon       windows.Handle
	Process    windows.Handle
}

const (
	seeMaskNoCloseProcess = 0x00000040
	seeMaskNoAsync        = 0x00000100
	swHide                = 0
)

type winElevator struct{}

// Start runs exe with the runas verb: Windows shows the UAC prompt and the
// program starts with the full administrator token. The parameters are
// quoted here; callers pass fixed words and one validated path.
func (winElevator) Start(exe string, args []string) (ElevatedProc, error) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	// ShellExecuteEx wants COM in a single threaded apartment. S_FALSE and
	// RPC_E_CHANGED_MODE both leave COM usable, so the result is not checked.
	if err := windows.CoInitializeEx(0, windows.COINIT_APARTMENTTHREADED|windows.COINIT_DISABLE_OLE1DDE); err == nil {
		defer windows.CoUninitialize()
	}
	// Let the UAC prompt take the foreground. This works only when this
	// process may set it (the caller passed the right on, or owns the
	// foreground); otherwise it is a harmless no-op. ASFW_ANY is (DWORD)-1.
	if procAllowSetForeground.Find() == nil {
		procAllowSetForeground.Call(^uintptr(0) & 0xFFFFFFFF)
	}
	verb, _ := windows.UTF16PtrFromString("runas")
	file, err := windows.UTF16PtrFromString(exe)
	if err != nil {
		return nil, err
	}
	params, err := windows.UTF16PtrFromString(joinWindowsArgs(args))
	if err != nil {
		return nil, err
	}
	// the working folder is the program's own, not wherever the caller is
	dir, err := windows.UTF16PtrFromString(filepath.Dir(exe))
	if err != nil {
		return nil, err
	}
	info := shellExecuteInfo{
		Mask: seeMaskNoCloseProcess | seeMaskNoAsync,
		Verb: verb, File: file, Parameters: params, Directory: dir, Show: swHide,
	}
	info.Size = uint32(unsafe.Sizeof(info))
	if err := procShellExecuteExW.Find(); err != nil {
		return nil, err
	}
	r, _, callErr := procShellExecuteExW.Call(uintptr(unsafe.Pointer(&info)))
	if r == 0 {
		if errors.Is(callErr, windows.ERROR_CANCELLED) {
			return nil, ErrElevationDeclined
		}
		return nil, fmt.Errorf("ShellExecuteEx: %v", callErr)
	}
	if info.Process == 0 {
		return nil, errors.New("ShellExecuteEx returned no process handle")
	}
	return &winProc{h: info.Process}, nil
}

// joinWindowsArgs quotes every argument that holds a space; the callers
// never pass a double quote.
func joinWindowsArgs(args []string) string {
	out := make([]string, len(args))
	for i, a := range args {
		out[i] = a
		if strings.ContainsAny(a, " \t") {
			out[i] = `"` + a + `"`
		}
	}
	return strings.Join(out, " ")
}

type winProc struct{ h windows.Handle }

func (p *winProc) Wait(d time.Duration) (bool, int, error) {
	ev, err := windows.WaitForSingleObject(p.h, uint32(d.Milliseconds()))
	if err != nil {
		return false, 0, err
	}
	if ev == uint32(windows.WAIT_TIMEOUT) {
		return false, 0, nil
	}
	var code uint32
	if err := windows.GetExitCodeProcess(p.h, &code); err != nil {
		return true, 0, err
	}
	return true, int(code), nil
}

func (p *winProc) Close() { windows.CloseHandle(p.h) }
