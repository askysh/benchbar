package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// configFile is %LOCALAPPDATA%\BenchBar\config.json. Keys the shim does not
// know are kept when it writes.
type configFile struct {
	path string
	m    map[string]json.RawMessage
}

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
	data = bytes.TrimPrefix(data, []byte{0xEF, 0xBB, 0xBF})
	if len(bytes.TrimSpace(data)) == 0 {
		return c, nil
	}
	if err := json.Unmarshal(data, &c.m); err != nil || c.m == nil {
		return nil, fmt.Errorf("%s is not a JSON object", c.path)
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

func (c *configFile) save() error {
	if c.path == "" {
		return errors.New("LOCALAPPDATA is not set")
	}
	data, err := json.MarshalIndent(c.m, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(c.path, append(data, '\n'))
}
