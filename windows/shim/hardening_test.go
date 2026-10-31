package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The elevated child must find its wsl.exe from the system folder, never
// from an environment variable a user without admin rights can set.
func TestSystemDirIgnoresTheEnvironment(t *testing.T) {
	fake := t.TempDir()
	os.MkdirAll(filepath.Join(fake, "System32"), 0o755)
	os.WriteFile(filepath.Join(fake, "System32", "wsl.exe"), []byte("x"), 0o755)
	os.WriteFile(filepath.Join(fake, "System32", "schtasks.exe"), []byte("x"), 0o755)
	t.Setenv("SystemRoot", fake)
	t.Setenv("windir", fake)
	if d := systemDir(); d != "" && strings.HasPrefix(strings.ToLower(d), strings.ToLower(fake)) {
		t.Errorf("systemDir followed the environment: %s", d)
	}
	if p, err := systemWSLPath(); err == nil && strings.HasPrefix(strings.ToLower(p), strings.ToLower(fake)) {
		t.Errorf("systemWSLPath followed the environment: %s", p)
	}
	if p, _ := defaultWSLPath(); strings.HasPrefix(strings.ToLower(p), strings.ToLower(fake)) {
		t.Errorf("defaultWSLPath followed the environment: %s", p)
	}
}

func TestDistroUserReportsWhetherTheUserExisted(t *testing.T) {
	e := newEnv(t)
	e.readyEnv()
	e.withPassword("pw")
	e.script(rule("/usr/bin/id -u", 0, "1000\n"), rule("/usr/sbin/usermod", 0, ""),
		rule(rReadConf, 0, "[user]\ndefault=alice\n"))
	e.run("setup", "run", "distro_user", "--user", "alice", "--jsonl")
	last := strings.TrimSpace(e.stdout())
	last = last[strings.LastIndex(last, "\n")+1:]
	if !strings.Contains(last, `"user_existed":true`) {
		t.Errorf("%s", last)
	}

	e = newEnv(t)
	e.readyEnv()
	e.withPassword("pw")
	e.script(rule("/usr/bin/id -u", 1, ""), rule("useradd", 0, ""), ruleStdin("chpasswd", 0),
		rule(rReadConf, 3, ""), rule(rBackup, 0, ""), ruleStdin(rWriteConf, 0), rule("--terminate", 0, ""))
	e.run("setup", "run", "distro_user", "--user", "alice", "--jsonl")
	last = strings.TrimSpace(e.stdout())
	last = last[strings.LastIndex(last, "\n")+1:]
	if !strings.Contains(last, `"user_existed":false`) {
		t.Errorf("%s", last)
	}

	// other actions never carry the field
	e = newEnv(t)
	e.readyEnv()
	e.run("setup", "run", "linger", "--jsonl")
	if strings.Contains(e.stdout(), "user_existed") {
		t.Error("user_existed on another action")
	}
}

func TestWslConfBackupNeverOverwrites(t *testing.T) {
	if !strings.Contains(backupScript, `while [ -e "$b" ]`) || strings.Contains(backupScript, "cp -p \"$0\" \"$0.benchbar-backup-$1\"") {
		t.Errorf("backup script: %s", backupScript)
	}
}
