//go:build windows

package main

import (
	"errors"
	"os"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

type winServices struct{}

func osServices() (DistroSource, PathStore, Broadcaster) {
	return winServices{}, winServices{}, winServices{}
}

const lxssKey = `Software\Microsoft\Windows\CurrentVersion\Lxss`

func (winServices) Distros() ([]Distro, error) {
	k, err := registry.OpenKey(registry.CURRENT_USER, lxssKey, registry.READ)
	if errors.Is(err, registry.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer k.Close()
	def, _, _ := k.GetStringValue("DefaultDistribution")
	names, err := k.ReadSubKeyNames(-1)
	if err != nil {
		return nil, err
	}
	var out []Distro
	for _, n := range names {
		sk, err := registry.OpenKey(k, n, registry.READ)
		if err != nil {
			continue
		}
		name, _, err := sk.GetStringValue("DistributionName")
		if err == nil && name != "" {
			d := Distro{Name: name, Default: def != "" && strings.EqualFold(def, n)}
			if v, _, err := sk.GetIntegerValue("Version"); err == nil {
				d.Version = int(v)
			}
			d.BasePath, _, _ = sk.GetStringValue("BasePath")
			out = append(out, d)
		}
		sk.Close()
	}
	return out, nil
}

const (
	userEnvKey    = `Environment`
	machineEnvKey = `SYSTEM\CurrentControlSet\Control\Session Manager\Environment`
)

func (winServices) User() (PathValue, error) {
	k, err := registry.OpenKey(registry.CURRENT_USER, userEnvKey, registry.QUERY_VALUE)
	if err != nil {
		return PathValue{}, err
	}
	defer k.Close()
	v, typ, err := k.GetStringValue("Path")
	if errors.Is(err, registry.ErrNotExist) {
		return PathValue{Expand: true}, nil
	}
	if err != nil {
		return PathValue{}, err
	}
	return PathValue{Value: v, Expand: typ == registry.EXPAND_SZ, Exists: true}, nil
}

func (winServices) SetUser(value string, expand bool) error {
	k, err := registry.OpenKey(registry.CURRENT_USER, userEnvKey, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer k.Close()
	if expand {
		return k.SetExpandStringValue("Path", value)
	}
	return k.SetStringValue("Path", value)
}

func (winServices) Machine() (string, error) {
	k, err := registry.OpenKey(registry.LOCAL_MACHINE, machineEnvKey, registry.QUERY_VALUE)
	if err != nil {
		return "", err
	}
	defer k.Close()
	v, _, err := k.GetStringValue("Path")
	if errors.Is(err, registry.ErrNotExist) {
		return "", nil
	}
	return v, err
}

var procSendMessageTimeout = windows.NewLazySystemDLL("user32.dll").NewProc("SendMessageTimeoutW")

func (winServices) EnvironmentChanged() error {
	const (
		hwndBroadcast   = 0xffff
		wmSettingChange = 0x001A
		smtoAbortIfHung = 0x0002
	)
	env, err := windows.UTF16PtrFromString("Environment")
	if err != nil {
		return err
	}
	var result uintptr
	r, _, callErr := procSendMessageTimeout.Call(hwndBroadcast, wmSettingChange, 0,
		uintptr(unsafe.Pointer(env)), smtoAbortIfHung, 5000, uintptr(unsafe.Pointer(&result)))
	if r == 0 {
		return callErr
	}
	return nil
}

type memoryStatusEx struct {
	Length               uint32
	MemoryLoad           uint32
	TotalPhys            uint64
	AvailPhys            uint64
	TotalPageFile        uint64
	AvailPageFile        uint64
	TotalVirtual         uint64
	AvailVirtual         uint64
	AvailExtendedVirtual uint64
}

var procGlobalMemoryStatusEx = windows.NewLazySystemDLL("kernel32.dll").NewProc("GlobalMemoryStatusEx")

func hostMemory() (uint64, error) {
	var ms memoryStatusEx
	ms.Length = uint32(unsafe.Sizeof(ms))
	r, _, err := procGlobalMemoryStatusEx.Call(uintptr(unsafe.Pointer(&ms)))
	if r == 0 {
		return 0, err
	}
	return ms.TotalPhys, nil
}

func isTerminal(f *os.File) bool {
	var mode uint32
	return windows.GetConsoleMode(windows.Handle(f.Fd()), &mode) == nil
}

// relayInterrupt does nothing: the console delivers Ctrl+C and Ctrl+Break
// to wsl.exe itself, which passes SIGINT into Linux.
func relayInterrupt(p *os.Process) {}

// attachKillOnClose puts the process in a job object that kills it when the
// job closes, so killing the shim stops wsl.exe. Failures are ignored. The
// returned func closes the job.
func attachKillOnClose(pid int) func() {
	noop := func() {}
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return noop
	}
	var info windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION
	info.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	_, err = windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation,
		uintptr(unsafe.Pointer(&info)), uint32(unsafe.Sizeof(info)))
	if err != nil {
		windows.CloseHandle(job)
		return noop
	}
	h, err := windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE, false, uint32(pid))
	if err != nil {
		windows.CloseHandle(job)
		return noop
	}
	defer windows.CloseHandle(h)
	if err := windows.AssignProcessToJobObject(job, h); err != nil {
		windows.CloseHandle(job)
		return noop
	}
	return func() { windows.CloseHandle(job) }
}

type procControl struct{}

func openProc(pid int, access uint32) (windows.Handle, error) {
	return windows.OpenProcess(access, false, uint32(pid))
}

func (procControl) Alive(pid int) bool {
	h, err := openProc(pid, windows.PROCESS_QUERY_LIMITED_INFORMATION|windows.SYNCHRONIZE)
	if err != nil {
		return false
	}
	defer windows.CloseHandle(h)
	ev, err := windows.WaitForSingleObject(h, 0)
	return err == nil && ev == uint32(windows.WAIT_TIMEOUT)
}

func (procControl) Image(pid int) (string, error) {
	h, err := openProc(pid, windows.PROCESS_QUERY_LIMITED_INFORMATION)
	if err != nil {
		return "", err
	}
	defer windows.CloseHandle(h)
	buf := make([]uint16, windows.MAX_PATH*4)
	n := uint32(len(buf))
	if err := windows.QueryFullProcessImageName(h, 0, &buf[0], &n); err != nil {
		return "", err
	}
	return windows.UTF16ToString(buf[:n]), nil
}

func (procControl) Terminate(pid int) error {
	h, err := openProc(pid, windows.PROCESS_TERMINATE)
	if err != nil {
		return err
	}
	defer windows.CloseHandle(h)
	return windows.TerminateProcess(h, 1)
}
