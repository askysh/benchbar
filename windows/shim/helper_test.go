package main

import (
	"math/rand"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

// helperEnv makes the test binary act as a tiny child program. The Windows
// tests start it to have a process of their own to wait for, put in a job,
// terminate or list, so they never touch a process they did not start.
const helperEnv = "BENCHBAR_SHIM_TEST_HELPER"

// runHelper is the body of the child. "sleep" waits until it is killed,
// "exit7" ends with code 7.
func runHelper(mode string) int {
	switch mode {
	case "sleep":
		time.Sleep(10 * time.Minute)
		return 0
	case "exit7":
		return 7
	}
	return 99
}

// startHelper starts the child and makes sure it is gone when the test ends.
func startHelper(t *testing.T, mode string) *exec.Cmd {
	t.Helper()
	cmd := exec.Command(os.Args[0])
	cmd.Env = append(os.Environ(), helperEnv+"="+mode)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cmd.Process.Kill()
		cmd.Wait()
	})
	return cmd
}

// waitExit waits for cmd to end, failing the test after d.
func waitExit(t *testing.T, cmd *exec.Cmd, d time.Duration) {
	t.Helper()
	done := make(chan struct{})
	go func() { cmd.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(d):
		t.Fatalf("pid %d still running after %v", cmd.Process.Pid, d)
	}
}

// controlArgs are the characters a command line parser or a shell may eat.
var controlArgs = []string{
	"a\nb", "a\rb", "a\tb", "\n", "\r", "\t", "\r\n", "trail\n", "\tlead",
	"a\r\n\r\nb", "x\ny z\n\"q\"\n", "\n\n", "tab\t\"quoted\"\tend", "back\\\nslash",
}

// longArgs are arguments that make a command line of about 30000 units. Each
// one differs, so a cut or a mix up shows.
func longArgs() []string {
	var args []string
	for i, total := 0, 0; total < 30000; i++ {
		a := strings.Repeat(string(rune('a'+i%26)), 997)
		args = append(args, a)
		total += len(a) + 1
	}
	return args
}

// binaryPayload is n bytes of every byte value from a fixed seed, with CR LF
// pairs, a Ctrl+Z (end of file to a Windows text stream) and NUL set in at
// intervals.
func binaryPayload(n int) []byte {
	r := rand.New(rand.NewSource(166))
	b := make([]byte, n)
	r.Read(b)
	for i := 0; i+8 < n; i += 4093 {
		copy(b[i:], "\r\n\x1a\x00\n\r\r\n")
	}
	return b
}
