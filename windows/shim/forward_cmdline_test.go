package main

import (
	"path/filepath"
	"reflect"
	"testing"
)

// The fake wsl.exe records the argument list it was started with. These are
// the same arguments the real WSL test (integration_test.go) sends, so a
// quoting bug for a newline, a tab or a 30000 unit command line shows on
// every host, not only where a distro is installed.
func TestForwardControlCharactersAndALongCommandLine(t *testing.T) {
	long := longArgs()
	for name, args := range map[string][]string{"control characters": controlArgs, "a command line near 32 KB": long} {
		t.Run(name, func(t *testing.T) {
			record := filepath.Join(t.TempDir(), "rec.jsonl")
			r := runShimProc(t, []string{"FAKE_WSL_MODE=exit:0", "FAKE_WSL_RECORD=" + record}, nil, args...)
			if r.code != 0 {
				t.Fatalf("exit %d stderr %q", r.code, r.stderr)
			}
			st := readEvents(t, record)
			if len(st) != 1 {
				t.Fatalf("%d calls", len(st))
			}
			want := append([]string{"/bin/sh", "-c", wantWrapper, "benchbar"}, args...)
			if !reflect.DeepEqual(st[0].Exec, want) {
				t.Errorf("the fake got %d arguments, want %d", len(st[0].Exec), len(want))
				for i := range want {
					if i >= len(st[0].Exec) || st[0].Exec[i] != want[i] {
						t.Errorf("arg %d differs: %.60q", i, want[i])
						break
					}
				}
			}
		})
	}
}
