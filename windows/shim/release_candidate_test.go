package main

import (
	"strings"
	"testing"
)

// A release candidate (X.Y.Z-rc.N) is a GitHub pre-release. The update check
// never offers one, whatever its flag says, and --version still installs one
// when a person names it.

func TestSelfUpdateCheckSkipsReleaseCandidates(t *testing.T) {
	e := newSUEnv(t)
	e.releases(
		rel("v0.9.0-rc.2", "2026-11-25T10:00:00Z", false, true, "amd64", "arm64"),
		// a candidate someone published without the pre-release flag is skipped by its tag
		rel("v0.9.0-rc.1", "2026-11-24T10:00:00Z", false, false, "amd64", "arm64"),
		rel("v0.8.4", "2026-11-20T10:00:00Z", false, false, "amd64", "arm64"),
		rel("v0.8.3", "2026-11-17T10:00:00Z", false, false, "amd64", "arm64"))
	r := e.check(t)
	if r.Latest == nil || *r.Latest != "0.8.4" || !r.UpdateAvailable {
		t.Fatalf("the check offered %v, want 0.8.4: %+v", r.Latest, r)
	}
}

func TestSelfUpdateVersionTakesAReleaseCandidate(t *testing.T) {
	e := newSUEnv(t)
	if code := e.run("self-update", "--dry-run", "--version", "0.9.0-rc.1"); code != 0 {
		t.Fatalf("exit %d\n%s%s", code, e.stdout(), e.stderr())
	}
	if !strings.Contains(e.stdout(), "This installs 0.9.0-rc.1") || !strings.Contains(e.stdout(), "-Version '0.9.0-rc.1';") {
		t.Fatalf("stdout:\n%s", e.stdout())
	}
	if len(e.web.calls) != 0 {
		t.Fatalf("--version needs no lookup: %v", e.web.calls)
	}
	for _, bad := range []string{"0.9.0-rc", "0.9.0-rc.", "0.9.0-beta.1", "0.9.0-rc.1-x", "0.9"} {
		e2 := newSUEnv(t)
		if code := e2.run("self-update", "--dry-run", "--version", bad); code != 1 || !strings.Contains(e2.stderr(), "is not a version") {
			t.Fatalf("%q: exit %d, stderr %q", bad, code, e2.stderr())
		}
	}
}

func TestZipNameTakesAReleaseCandidate(t *testing.T) {
	m := zipNameRE.FindStringSubmatch("benchbar-windows-0.9.0-rc.1-amd64.zip")
	if m == nil || m[1] != "0.9.0-rc.1" || m[2] != "amd64" {
		t.Fatalf("zip name: %v", m)
	}
}
