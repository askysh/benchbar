package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// configFile is %LOCALAPPDATA%\BenchBar\config.json. Keys the shim does not
// know are kept when it writes.
type configFile struct {
	path string
	m    map[string]json.RawMessage
	// invalid is set when the file exists but is not a JSON object and the
	// caller chose to go on without it (adopt-distro NAME). save() then moves
	// the old file aside first, so nothing is lost.
	invalid bool
}

// configError is a config.json that cannot be used. The message names the
// file and the fix.
type configError struct {
	path string
	msg  string
}

func (e *configError) Error() string { return e.msg }

func loadConfig(sys *System) (*configFile, error) {
	c := &configFile{m: map[string]json.RawMessage{}}
	if sys.ConfigDir == "" {
		return c, nil
	}
	c.path = filepath.Join(sys.ConfigDir, "config.json")
	data, err := os.ReadFile(c.path)
	if errors.Is(err, os.ErrNotExist) {
		return c, nil
	}
	if err != nil {
		return nil, fmt.Errorf("cannot read %s: %v", c.path, err)
	}
	// Windows PowerShell 5.1 writes UTF-16 with a BOM; others write a UTF-8 BOM
	data, _ = decodeText(data)
	data = bytes.TrimPrefix(data, []byte{0xEF, 0xBB, 0xBF})
	if len(bytes.TrimSpace(data)) == 0 {
		return c, nil
	}
	if err := json.Unmarshal(data, &c.m); err != nil || c.m == nil {
		return nil, &configError{c.path, fmt.Sprintf("%s is not a JSON object. Fix it, or delete it, or run benchbar.exe adopt-distro NAME to write it again (the old file is kept next to it)", c.path)}
	}
	return c, nil
}

func (c *configFile) str(key string) string {
	var s string
	if raw, ok := c.m[key]; ok && json.Unmarshal(raw, &s) == nil {
		return s
	}
	return ""
}

func (c *configFile) setStr(key, value string) {
	raw, _ := json.Marshal(value)
	c.m[key] = raw
}

// save writes the file next to itself and renames it over the old one, so a
// reader (the tray) never sees half a file.
func (c *configFile) save() error {
	if c.path == "" {
		return errors.New("LOCALAPPDATA is not set")
	}
	if c.invalid {
		if err := moveAside(c.path); err != nil {
			return fmt.Errorf("cannot keep the old %s: %v", c.path, err)
		}
		c.invalid = false
	}
	data, err := json.MarshalIndent(c.m, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(c.path, append(data, '\n'))
}

// moveAside renames path to path.invalid, or path.invalid-N when taken.
func moveAside(path string) error {
	name := path + ".invalid"
	for n := 1; ; n++ {
		if _, err := os.Lstat(name); errors.Is(err, os.ErrNotExist) {
			break
		}
		name = fmt.Sprintf("%s.invalid-%d", path, n)
	}
	return os.Rename(path, name)
}

// configLockName is the machine wide name taken around load, change and save
// of config.json, so the shim and the tray do not lose each other's change.
const configLockName = `Local\BenchBarConfig`

// updateConfig reads config.json, lets change edit it and writes it back,
// holding configLockName. It waits up to two seconds for the lock; after
// that it goes on without it, since the write is atomic and a missed update
// is better than no update.
func updateConfig(sys *System, change func(*configFile)) error {
	return updateConfigWith(sys, change, false)
}

// updateConfigWith is updateConfig; with replaceInvalid a config.json that is
// not a JSON object is moved aside (to config.json.invalid) and a new one is
// written, instead of an error.
func updateConfigWith(sys *System, change func(*configFile), replaceInvalid bool) error {
	if sys.Locks != nil {
		for i := 0; i < 20; i++ {
			release, ok, err := sys.Locks.TryLock(configLockName)
			if err != nil {
				break
			}
			if ok {
				defer release()
				break
			}
			sys.Sleep(sys.Ctx, 100*time.Millisecond)
		}
	}
	cfg, err := loadConfig(sys)
	var ce *configError
	if errors.As(err, &ce) && replaceInvalid {
		cfg, err = &configFile{path: ce.path, m: map[string]json.RawMessage{}, invalid: true}, nil
	}
	if err != nil {
		return err
	}
	change(cfg)
	return cfg.save()
}

func configPath(sys *System) string {
	if sys.ConfigDir == "" {
		return "config.json"
	}
	return filepath.Join(sys.ConfigDir, "config.json")
}
