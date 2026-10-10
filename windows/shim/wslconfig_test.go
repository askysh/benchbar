package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestINIRoundTripsByteForByte(t *testing.T) {
	inputs := []string{
		"",
		"[wsl2]\nmemory=8GB\n",
		"[wsl2]\r\nmemory = 8GB\r\n# comment\r\n; other\r\n\r\n[Experimental]\r\nautoMemoryReclaim=gradual",
		"\xEF\xBB\xBF[wsl2]\r\nMemory=2GB\r\n",
		"no section\nkey=value\n\n\n",
		"[wsl2]\n  swap =  0  \n[unknown]\nfoo\nbar=baz\n",
		"mixed\r\nendings\nhere\r\n",
	}
	for _, in := range inputs {
		if got := string(parseINI([]byte(in)).render()); got != in {
			t.Errorf("round trip changed %q into %q", in, got)
		}
	}
}

func TestINIGetIsCaseInsensitiveAndLastWins(t *testing.T) {
	f := parseINI([]byte("[WSL2]\nMemory=2GB\nmemory=6GB\n[general]\nmemory=1\n"))
	if v, ok := f.get("wsl2", "MEMORY"); !ok || v != "6GB" {
		t.Errorf("got %q %v", v, ok)
	}
	if _, ok := f.get("wsl2", "swap"); ok {
		t.Error("swap should be unset")
	}
}

func TestINISetReplacesInPlaceKeepingSpelling(t *testing.T) {
	f := parseINI([]byte("# top\r\n[WSL2]\r\nMemory =  2GB\r\nswap=0\r\n"))
	f.set("wsl2", "memory", "4GB")
	want := "# top\r\n[WSL2]\r\nMemory =  4GB\r\nswap=0\r\n"
	if got := string(f.render()); got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestINISetAddsAfterLastLineOfSection(t *testing.T) {
	f := parseINI([]byte("[wsl2]\nswap=0\n\n[general]\nx=1\n"))
	f.set("wsl2", "vmIdleTimeout", "-1")
	want := "[wsl2]\nswap=0\nvmIdleTimeout=-1\n\n[general]\nx=1\n"
	if got := string(f.render()); got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestINISetAddsMissingSection(t *testing.T) {
	f := parseINI([]byte("\xEF\xBB\xBF[wsl2]\r\nswap=0"))
	f.set("general", "instanceIdleTimeout", "-1")
	want := "\xEF\xBB\xBF[wsl2]\r\nswap=0\r\n\r\n[general]\r\ninstanceIdleTimeout=-1\r\n"
	if got := string(f.render()); got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestINISetOnEmptyFileUsesCRLF(t *testing.T) {
	f := parseINI(nil)
	f.set("wsl2", "memory", "4GB")
	if got, want := string(f.render()), "[wsl2]\r\nmemory=4GB\r\n"; got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestINIKeepsMissingFinalNewline(t *testing.T) {
	f := parseINI([]byte("[wsl2]\nswap=0"))
	f.set("wsl2", "memory", "4GB")
	if got, want := string(f.render()), "[wsl2]\nswap=0\nmemory=4GB"; got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestParseSize(t *testing.T) {
	cases := map[string]uint64{
		"8GB": 8 << 30, "8gb": 8 << 30, "8G": 8 << 30, "4096MB": 4096 << 20, "512M": 512 << 20,
		"1.5GB": 3 << 29, "1024KB": 1 << 20, "100": 100, "2 GB": 2 << 30, "1TB": 1 << 40,
	}
	for in, want := range cases {
		if got, ok := parseSize(in); !ok || got != want {
			t.Errorf("parseSize(%q) = %d, %v; want %d", in, got, ok, want)
		}
	}
	for _, bad := range []string{"", "abc", "GB", "4XB", "-1"} {
		if _, ok := parseSize(bad); ok {
			t.Errorf("parseSize(%q) should fail", bad)
		}
	}
}

func analyze(content string, host uint64) wslReport {
	return analyzeWslconfig(parseINI([]byte(content)), `C:\x\.wslconfig`, content != "", host)
}

func suggestText(r wslReport) string { return formatChanges(r.Suggest) }

func TestSuggestRules(t *testing.T) {
	const gb = uint64(1) << 30
	cases := []struct {
		name    string
		content string
		host    uint64
		want    string
	}{
		{"nothing set, big host", "", 16 * gb,
			"[wsl2]\nvmIdleTimeout=-1\n[general]\ninstanceIdleTimeout=-1\n"},
		{"nothing set, small host", "", 6 * gb,
			"[wsl2]\nmemory=4GB\nvmIdleTimeout=-1\n[general]\ninstanceIdleTimeout=-1\n"},
		{"exactly 8 GB host keeps default", "", 8 * gb,
			"[wsl2]\nvmIdleTimeout=-1\n[general]\ninstanceIdleTimeout=-1\n"},
		{"memory below 4 GB", "[wsl2]\nmemory=2GB\nvmIdleTimeout=-1\n[general]\ninstanceIdleTimeout=-1\n", 32 * gb,
			"[wsl2]\nmemory=4GB\n"},
		{"memory in MB below 4 GB", "[wsl2]\nmemory=3500MB\n", 32 * gb,
			"[wsl2]\nmemory=4GB\nvmIdleTimeout=-1\n[general]\ninstanceIdleTimeout=-1\n"},
		{"memory at 4 GB kept", "[wsl2]\nmemory=4GB\nvmIdleTimeout=-1\n[general]\ninstanceIdleTimeout=-1\n", 4 * gb, ""},
		{"memory unparsable is left alone", "[wsl2]\nmemory=lots\nvmIdleTimeout=-1\n[general]\ninstanceIdleTimeout=-1\n", 2 * gb, ""},
		{"timeouts wrong", "[wsl2]\nvmIdleTimeout=5000\n[general]\ninstanceIdleTimeout=0\n", 32 * gb,
			"[wsl2]\nvmIdleTimeout=-1\n[general]\ninstanceIdleTimeout=-1\n"},
		{"host unknown never suggests memory", "", 0,
			"[wsl2]\nvmIdleTimeout=-1\n[general]\ninstanceIdleTimeout=-1\n"},
	}
	for _, c := range cases {
		if got := suggestText(analyze(c.content, c.host)); got != c.want {
			t.Errorf("%s:\n got %q\nwant %q", c.name, got, c.want)
		}
	}
}

func reportLine(key, val string) string { return fmt.Sprintf("  %-20s %s\n", key, val) }

func TestReportText(t *testing.T) {
	e := newEnv(t)
	e.MemoryBytes = func() (uint64, error) { return 16 << 30, nil }
	if code := e.run("wslconfig"); code != 0 {
		t.Fatalf("exit %d: %s", code, e.stderr())
	}
	out := e.stdout()
	for _, want := range []string{
		"not found",
		reportLine("memory", "not set (default 50% of host RAM, 8 GB)"),
		reportLine("processors", "not set (default all logical processors)"),
		reportLine("swap", "not set (default 25% of host RAM)"),
		reportLine("vmIdleTimeout", "not set (default 60000)"),
		reportLine("instanceIdleTimeout", "not set (default 15000)"),
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
	if len(e.starts()) != 0 {
		t.Error("wslconfig must not call wsl.exe")
	}
}

func TestReportShowsSetValues(t *testing.T) {
	e := newEnv(t)
	os.WriteFile(filepath.Join(e.ProfileDir, ".wslconfig"), []byte("[wsl2]\nmemory=6GB\nprocessors=4\nswap=0\nvmIdleTimeout=-1\n[general]\ninstanceIdleTimeout=-1\n"), 0o644)
	e.run("wslconfig")
	for _, want := range []string{reportLine("memory", "6GB"), reportLine("processors", "4"), reportLine("swap", "0"),
		reportLine("vmIdleTimeout", "-1"), reportLine("instanceIdleTimeout", "-1")} {
		if !strings.Contains(e.stdout(), want) {
			t.Errorf("missing %q in:\n%s", want, e.stdout())
		}
	}
}

func TestSuggestAndJSON(t *testing.T) {
	e := newEnv(t)
	if code := e.run("wslconfig", "--suggest"); code != 0 {
		t.Fatal(code)
	}
	if got, want := e.stdout(), "[wsl2]\nvmIdleTimeout=-1\n[general]\ninstanceIdleTimeout=-1\n"; got != want {
		t.Errorf("got %q want %q", got, want)
	}

	e2 := newEnv(t)
	os.WriteFile(filepath.Join(e2.ProfileDir, ".wslconfig"), []byte("[wsl2]\nvmIdleTimeout=-1\n[general]\ninstanceIdleTimeout=-1\n"), 0o644)
	e2.run("wslconfig", "--suggest")
	if e2.stdout() != "Nothing to change.\n" {
		t.Errorf("got %q", e2.stdout())
	}

	e3 := newEnv(t)
	if code := e3.run("wslconfig", "--json"); code != 0 {
		t.Fatal(code)
	}
	var rep wslReport
	if err := json.Unmarshal(e3.out.Bytes(), &rep); err != nil {
		t.Fatalf("not JSON: %v\n%s", err, e3.stdout())
	}
	if rep.Exists || len(rep.Settings) != 5 || len(rep.Suggest) != 2 || rep.HostMemoryBytes != 16<<30 {
		t.Errorf("report %+v", rep)
	}
}

func TestApplyNeedsYes(t *testing.T) {
	e := newEnv(t)
	path := filepath.Join(e.ProfileDir, ".wslconfig")
	if code := e.run("wslconfig", "--apply"); code != 1 {
		t.Errorf("exit %d, want 1", code)
	}
	if !strings.Contains(e.stderr(), "pass --yes to write it") {
		t.Errorf("stderr %q", e.stderr())
	}
	if !strings.Contains(e.stdout(), "vmIdleTimeout=-1") {
		t.Errorf("stdout should show what would change: %q", e.stdout())
	}
	if _, err := os.Stat(path); err == nil {
		t.Error("file written without --yes")
	}
}

func TestApplyRoundTrip(t *testing.T) {
	e := newEnv(t)
	path := filepath.Join(e.ProfileDir, ".wslconfig")
	orig := "\xEF\xBB\xBF# my settings\r\n[WSL2]\r\nMemory = 2GB\r\nprocessors=4\r\n; keep me\r\n\r\n[experimental]\r\nautoMemoryReclaim=gradual\r\nsparseVhd=true\r\n"
	os.WriteFile(path, []byte(orig), 0o644)

	if code := e.run("wslconfig", "--apply", "--yes"); code != 0 {
		t.Fatalf("exit %d: %s", code, e.stderr())
	}
	want := "\xEF\xBB\xBF# my settings\r\n[WSL2]\r\nMemory = 4GB\r\nprocessors=4\r\n; keep me\r\nvmIdleTimeout=-1\r\n\r\n[experimental]\r\nautoMemoryReclaim=gradual\r\nsparseVhd=true\r\n\r\n[general]\r\ninstanceIdleTimeout=-1\r\n"
	got, _ := os.ReadFile(path)
	if string(got) != want {
		t.Errorf("file\n got %q\nwant %q", got, want)
	}
	backups, _ := filepath.Glob(path + ".benchbar-backup-*")
	if len(backups) != 1 || filepath.Base(backups[0]) != ".wslconfig.benchbar-backup-20260102-030405" {
		t.Fatalf("backups %v", backups)
	}
	if b, _ := os.ReadFile(backups[0]); string(b) != orig {
		t.Errorf("backup differs from the original: %q", b)
	}
	if !strings.Contains(e.stdout(), "wsl.exe --shutdown") || !strings.Contains(e.stdout(), "never runs it") {
		t.Errorf("stdout lacks the restart note: %q", e.stdout())
	}
	if len(e.starts()) != 0 {
		t.Error("wsl.exe must not run")
	}

	// a second run changes nothing and makes no new backup
	e.out.Reset()
	if code := e.run("wslconfig", "--apply", "--yes"); code != 0 {
		t.Fatal(code)
	}
	again, _ := os.ReadFile(path)
	if string(again) != want {
		t.Errorf("second apply changed the file: %q", again)
	}
	backups, _ = filepath.Glob(path + ".benchbar-backup-*")
	if len(backups) != 1 {
		t.Errorf("second apply made a backup: %v", backups)
	}
	if e.stdout() != "Nothing to change.\n" {
		t.Errorf("stdout %q", e.stdout())
	}
}

func TestApplyCreatesMissingFileWithoutBackup(t *testing.T) {
	e := newEnv(t)
	path := filepath.Join(e.ProfileDir, ".wslconfig")
	if code := e.run("wslconfig", "--apply", "--yes"); code != 0 {
		t.Fatalf("exit %d: %s", code, e.stderr())
	}
	got, _ := os.ReadFile(path)
	if want := "[wsl2]\r\nvmIdleTimeout=-1\r\n\r\n[general]\r\ninstanceIdleTimeout=-1\r\n"; string(got) != want {
		t.Errorf("got %q want %q", got, want)
	}
	if backups, _ := filepath.Glob(path + ".benchbar-backup-*"); len(backups) != 0 {
		t.Errorf("unexpected backup %v", backups)
	}
}

func TestWslconfigUsage(t *testing.T) {
	e := newEnv(t)
	if code := e.run("wslconfig", "--bogus"); code != 1 {
		t.Errorf("exit %d", code)
	}
	if code := e.run("wslconfig", "--json", "--apply"); code != 1 {
		t.Errorf("exit %d", code)
	}
}

func TestIdleCheck(t *testing.T) {
	ok := idleCheck(analyze("[wsl2]\nvmIdleTimeout=-1\n[general]\ninstanceIdleTimeout=-1\n", 16<<30))
	if ok.Status != "ok" || ok.Fix != "" {
		t.Errorf("%+v", ok)
	}
	bad := idleCheck(analyze("[wsl2]\nvmIdleTimeout=-1\n", 16<<30))
	if bad.Status != "warn" || bad.Fix != "benchbar.exe wslconfig --apply --yes" || !strings.Contains(bad.Message, "instanceIdleTimeout not set") {
		t.Errorf("%+v", bad)
	}
}

func utf16File(t *testing.T, s string, big, bom bool) []byte {
	t.Helper()
	return textEnc{utf16: true, big: big, bom: bom}.encode([]byte(s))
}

func TestUTF16WslconfigIsRead(t *testing.T) {
	text := "[wsl2]\r\nmemory=2GB\r\nvmIdleTimeout=-1\r\n"
	for name, data := range map[string][]byte{
		"LE with BOM": utf16File(t, text, false, true),
		"BE with BOM": utf16File(t, text, true, true),
		"LE without":  utf16File(t, text, false, false),
		"BE without":  utf16File(t, text, true, false),
	} {
		e := newEnv(t)
		os.WriteFile(filepath.Join(e.ProfileDir, ".wslconfig"), data, 0o644)
		if code := e.run("wslconfig", "--json"); code != 0 {
			t.Fatalf("%s: exit %d", name, code)
		}
		var rep wslReport
		if err := json.Unmarshal(e.out.Bytes(), &rep); err != nil {
			t.Fatal(err)
		}
		if !rep.Settings[0].Set || rep.Settings[0].Value != "2GB" || !rep.Settings[3].Set || rep.Settings[3].Value != "-1" {
			t.Errorf("%s: settings %+v", name, rep.Settings)
		}
	}
}

func TestUTF16ApplyKeepsEncodingBOMAndCRLF(t *testing.T) {
	e := newEnv(t)
	path := filepath.Join(e.ProfileDir, ".wslconfig")
	orig := utf16File(t, "# note\r\n[wsl2]\r\nmemory=2GB\r\n", false, true)
	os.WriteFile(path, orig, 0o644)
	if code := e.run("wslconfig", "--apply", "--yes"); code != 0 {
		t.Fatalf("exit %d: %s", code, e.stderr())
	}
	got, _ := os.ReadFile(path)
	want := utf16File(t, "# note\r\n[wsl2]\r\nmemory=4GB\r\nvmIdleTimeout=-1\r\n\r\n[general]\r\ninstanceIdleTimeout=-1\r\n", false, true)
	if !bytes.Equal(got, want) {
		t.Errorf("file\n got % x\nwant % x", got, want)
	}
	if got[0] != 0xFF || got[1] != 0xFE {
		t.Error("BOM lost")
	}
	backups, _ := filepath.Glob(path + ".benchbar-backup-*")
	if len(backups) != 1 {
		t.Fatalf("backups %v", backups)
	}
	if b, _ := os.ReadFile(backups[0]); !bytes.Equal(b, orig) {
		t.Error("backup is not the original bytes")
	}

	e.out.Reset()
	if code := e.run("wslconfig", "--apply", "--yes"); code != 0 {
		t.Fatal(code)
	}
	again, _ := os.ReadFile(path)
	if !bytes.Equal(again, want) || e.stdout() != "Nothing to change.\n" {
		t.Errorf("second apply changed things: %q", e.stdout())
	}
	if backups, _ = filepath.Glob(path + ".benchbar-backup-*"); len(backups) != 1 {
		t.Errorf("second apply made a backup: %v", backups)
	}
}
