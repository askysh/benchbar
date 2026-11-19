//go:build windows

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

// useTestKeys points the per user registry paths of platform_windows.go at a
// throwaway key under HKCU and removes it when the test ends. The real
// Environment, Lxss, StartupApproved and Internet Settings keys are never
// opened for writing: every write goes through a variable this swaps, and the
// swap is checked before the first write.
func useTestKeys(t *testing.T) string {
	t.Helper()
	root := fmt.Sprintf(`Software\BenchBarShimTest-%d-%d`, os.Getpid(), time.Now().UnixNano())
	realKeys := []string{userEnvKey, lxssKey, startupApprovedKey, internetSettingsKey}
	oldEnv, oldLxss, oldStartup, oldNet := userEnvKey, lxssKey, startupApprovedKey, internetSettingsKey
	userEnvKey, lxssKey = root+`\Environment`, root+`\Lxss`
	startupApprovedKey, internetSettingsKey = root+`\StartupApproved`, root+`\Internet Settings`
	t.Cleanup(func() {
		userEnvKey, lxssKey, startupApprovedKey, internetSettingsKey = oldEnv, oldLxss, oldStartup, oldNet
		deleteTree(registry.CURRENT_USER, root)
	})
	for _, k := range []string{userEnvKey, lxssKey, startupApprovedKey, internetSettingsKey} {
		for _, r := range realKeys {
			if strings.EqualFold(k, r) {
				t.Fatalf("test key %q is a real key", k)
			}
		}
		if !strings.HasPrefix(k, root) {
			t.Fatalf("test key %q is outside %q", k, root)
		}
	}
	return root
}

// deleteTree removes a key and its subkeys, deepest first.
func deleteTree(root registry.Key, path string) {
	k, err := registry.OpenKey(root, path, registry.ENUMERATE_SUB_KEYS|registry.QUERY_VALUE)
	if err != nil {
		return
	}
	names, _ := k.ReadSubKeyNames(-1)
	k.Close()
	for _, n := range names {
		deleteTree(root, path+`\`+n)
	}
	registry.DeleteKey(root, path)
}

func createTestKey(t *testing.T, path string) registry.Key {
	t.Helper()
	// only ever under a throwaway BenchBarShimTest key, whatever the caller passes
	if !strings.HasPrefix(path, `Software\BenchBarShimTest-`) {
		t.Fatalf("test key %q is not under a BenchBarShimTest key", path)
	}
	k, _, err := registry.CreateKey(registry.CURRENT_USER, path, registry.ALL_ACCESS)
	if err != nil {
		t.Skipf("cannot create a test key under HKCU: %v", err)
	}
	t.Cleanup(func() { k.Close() })
	return k
}

func TestUserPathRoundTripInATestKey(t *testing.T) {
	useTestKeys(t)
	createTestKey(t, userEnvKey)
	s := winServices{}

	v, err := s.User()
	if err != nil {
		t.Fatal(err)
	}
	if v.Exists || !v.Expand || v.Value != "" {
		t.Errorf("a key without Path: %+v", v)
	}

	if err := s.SetUser(`%USERPROFILE%\bin;C:\tools`, true); err != nil {
		t.Fatal(err)
	}
	v, err = s.User()
	if err != nil || v != (PathValue{Value: `%USERPROFILE%\bin;C:\tools`, Expand: true, Exists: true}) {
		t.Errorf("after an expand write: %+v, %v", v, err)
	}

	if err := s.SetUser(`C:\plain`, false); err != nil {
		t.Fatal(err)
	}
	v, err = s.User()
	if err != nil || v != (PathValue{Value: `C:\plain`, Expand: false, Exists: true}) {
		t.Errorf("after a plain write: %+v, %v", v, err)
	}
}

func TestUserPathFailsWithoutTheKey(t *testing.T) {
	useTestKeys(t)
	if _, err := (winServices{}).User(); err == nil {
		t.Error("User() on a missing key returned no error")
	}
	if err := (winServices{}).SetUser("x", false); err == nil {
		t.Error("SetUser on a missing key returned no error")
	}
}

func TestDistrosFromATestKey(t *testing.T) {
	useTestKeys(t)
	s := winServices{}
	if d, err := s.Distros(); err != nil || d != nil {
		t.Fatalf("no Lxss key: %v, %v", d, err)
	}
	lx := createTestKey(t, lxssKey)
	const guidA, guidB = "{11111111-1111-1111-1111-111111111111}", "{22222222-2222-2222-2222-222222222222}"
	for guid, d := range map[string]struct {
		name string
		ver  uint32
	}{guidA: {"Alpha", 2}, guidB: {"Beta", 1}} {
		k, _, err := registry.CreateKey(lx, guid, registry.ALL_ACCESS)
		if err != nil {
			t.Fatal(err)
		}
		k.SetStringValue("DistributionName", d.name)
		k.SetDWordValue("Version", d.ver)
		k.SetStringValue("BasePath", `C:\wsl\`+d.name)
		k.Close()
	}
	// a subkey with no name is not a distro
	if k, _, err := registry.CreateKey(lx, "{33333333-3333-3333-3333-333333333333}", registry.ALL_ACCESS); err == nil {
		k.Close()
	}
	lx.SetStringValue("DefaultDistribution", strings.ToLower(guidB))

	got, err := s.Distros()
	if err != nil {
		t.Fatal(err)
	}
	by := map[string]Distro{}
	for _, d := range got {
		by[d.Name] = d
	}
	if len(got) != 2 {
		t.Fatalf("got %+v", got)
	}
	if a := by["Alpha"]; a.Version != 2 || a.Default || a.BasePath != `C:\wsl\Alpha` {
		t.Errorf("Alpha = %+v", a)
	}
	if b := by["Beta"]; b.Version != 1 || !b.Default {
		t.Errorf("Beta = %+v (the default compares without case)", b)
	}
}

func TestStartupApprovedReadsABinaryValue(t *testing.T) {
	useTestKeys(t)
	k := createTestKey(t, startupApprovedKey)
	if _, err := startupApproved("BenchBar.lnk"); err == nil {
		t.Error("a missing value returned no error")
	}
	want := []byte{0x02, 0, 0, 0, 0xde, 0xad}
	if err := k.SetBinaryValue("BenchBar.lnk", want); err != nil {
		t.Fatal(err)
	}
	got, err := startupApproved("BenchBar.lnk")
	if err != nil || string(got) != string(want) {
		t.Errorf("got %x, %v", got, err)
	}
}

func TestMachinePathAndSystemFacts(t *testing.T) {
	// read only: HKLM is never written
	if v, err := (winServices{}).Machine(); err != nil || v == "" {
		t.Errorf("Machine() = %q, %v", v, err)
	}
	if mem, err := hostMemory(); err != nil || mem < 256<<20 {
		t.Errorf("hostMemory = %d, %v", mem, err)
	}
	d := systemDir()
	if !strings.EqualFold(filepath.Base(d), "System32") {
		t.Errorf("systemDir = %q", d)
	}
	if err := procSendMessageTimeout.Find(); err != nil {
		t.Errorf("SendMessageTimeoutW: %v", err)
	}
	if err := procGetOEMCP.Find(); err != nil {
		t.Errorf("GetOEMCP: %v", err)
	}
}

func TestOEMDecode(t *testing.T) {
	if got := osOEMDecode(nil); got != "" {
		t.Errorf("empty: %q", got)
	}
	if got := osOEMDecode([]byte(`C:\Users\x`)); got != `C:\Users\x` {
		t.Errorf("ASCII: %q", got)
	}
	if got := osOEMDecode([]byte{0x80, 0xe9}); got == "" {
		t.Error("high bytes decoded to nothing")
	}
}

func TestIsTerminalIsFalseForAFile(t *testing.T) {
	nul, err := os.Open("NUL")
	if err != nil {
		t.Fatal(err)
	}
	defer nul.Close()
	if isTerminal(nul) {
		t.Error("NUL is not a console")
	}
	f, err := os.Create(filepath.Join(t.TempDir(), "f"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if isTerminal(f) {
		t.Error("a file is not a console")
	}
}

func TestNamedMutexTakenTwice(t *testing.T) {
	name := fmt.Sprintf(`Local\BenchBarShimTest-%d-%d`, os.Getpid(), time.Now().UnixNano())
	var l mutexLocks
	release, ok, err := l.TryLock(name)
	if err != nil || !ok || release == nil {
		t.Fatalf("first TryLock: ok=%v err=%v", ok, err)
	}
	defer release()
	r2, ok, err := l.TryLock(name)
	if err != nil || ok || r2 != nil {
		t.Fatalf("second TryLock while held: ok=%v err=%v", ok, err)
	}
	// the failed attempt closed its own handle, so the first release frees the name
	release()
	r3, ok, err := l.TryLock(name)
	if err != nil || !ok {
		t.Fatalf("TryLock after release: ok=%v err=%v", ok, err)
	}
	r3()
}

func TestNamedMutexWithABadName(t *testing.T) {
	if _, ok, err := (mutexLocks{}).TryLock("a\x00b"); ok || err == nil {
		t.Errorf("a name with a NUL byte: ok=%v err=%v", ok, err)
	}
}

// The job object kills what it holds when it closes: the shim dies, the
// job closes, wsl.exe goes with it.
func TestJobObjectKillsTheChildOnClose(t *testing.T) {
	cmd := startHelper(t, "sleep")
	closeJob := attachKillOnClose(cmd.Process.Pid)
	if !(procControl{}).Alive(cmd.Process.Pid) {
		t.Fatal("the child is not running")
	}
	closeJob()
	waitExit(t, cmd, 10*time.Second)
	if (procControl{}).Alive(cmd.Process.Pid) {
		t.Error("Alive still true after the job closed")
	}
}

func TestJobObjectLeavesTheChildAloneUntilClose(t *testing.T) {
	cmd := startHelper(t, "sleep")
	closeJob := attachKillOnClose(cmd.Process.Pid)
	defer closeJob()
	time.Sleep(300 * time.Millisecond)
	if !(procControl{}).Alive(cmd.Process.Pid) {
		t.Error("the child ended while the job was open")
	}
}

func TestAttachKillOnCloseWithAMissingPid(t *testing.T) {
	// no process has this id; the call must still return a usable no-op
	attachKillOnClose(0x7ffffff0)()
}

func TestProcControlOnAChild(t *testing.T) {
	cmd := startHelper(t, "sleep")
	pid := cmd.Process.Pid
	var pc procControl
	if !pc.Alive(pid) {
		t.Fatal("not alive")
	}
	img, err := pc.Image(pid)
	if err != nil || !strings.EqualFold(filepath.Base(img), filepath.Base(os.Args[0])) {
		t.Errorf("Image = %q, %v (test binary %q)", img, err, os.Args[0])
	}
	if c, err := pc.Created(pid); err != nil || c == 0 {
		t.Errorf("Created = %d, %v", c, err)
	}
	found := false
	for _, p := range processImages(filepath.Base(os.Args[0])) {
		if p.Pid == pid {
			found = true
			if p.Created == 0 || p.Image == "" {
				t.Errorf("processImages entry %+v", p)
			}
		}
	}
	if !found {
		t.Errorf("processImages did not list pid %d", pid)
	}
	if err := pc.Terminate(pid); err != nil {
		t.Fatal(err)
	}
	waitExit(t, cmd, 10*time.Second)
	if pc.Alive(pid) {
		t.Error("Alive after Terminate")
	}
}

func TestProcControlOnAPidThatIsGone(t *testing.T) {
	var pc procControl
	if pc.Alive(0x7ffffff0) {
		t.Error("Alive for a pid nobody has")
	}
	if _, err := pc.Image(0x7ffffff0); err == nil {
		t.Error("Image for a pid nobody has returned no error")
	}
	if err := pc.Terminate(0x7ffffff0); err == nil {
		t.Error("Terminate for a pid nobody has returned no error")
	}
	if got := processImages("benchbar-no-such-program.exe"); len(got) != 0 {
		t.Errorf("got %v", got)
	}
}

func TestOwnProcessIsAlive(t *testing.T) {
	if !(procControl{}).Alive(os.Getpid()) {
		t.Error("the test process is not alive")
	}
	h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, uint32(os.Getpid()))
	if err != nil {
		t.Fatal(err)
	}
	windows.CloseHandle(h)
}
