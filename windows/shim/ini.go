package main

import (
	"bytes"
	"strings"
)

const (
	lineOther = iota
	lineSection
	lineKey
)

type iniLine struct {
	text    string // without the line ending
	eol     string
	kind    int
	section string // lower case, for key lines and section lines
	key     string // lower case
	value   string
}

// ini keeps every line as it was read, so a write changes only what was
// asked: comments, blank lines, unknown keys, key spelling, spacing,
// line endings and a UTF-8 BOM stay.
type ini struct {
	bom   bool
	enc   textEnc // how the file is stored on disk
	lines []iniLine
}

var utf8BOM = []byte{0xEF, 0xBB, 0xBF}

func parseINI(data []byte) *ini {
	f := &ini{bom: bytes.HasPrefix(data, utf8BOM)}
	s := string(bytes.TrimPrefix(data, utf8BOM))
	section := ""
	for len(s) > 0 {
		var l iniLine
		if i := strings.IndexByte(s, '\n'); i < 0 {
			l.text, s = s, ""
		} else {
			l.text, s = s[:i], s[i+1:]
			l.eol = "\n"
			if strings.HasSuffix(l.text, "\r") {
				l.text = strings.TrimSuffix(l.text, "\r")
				l.eol = "\r\n"
			}
		}
		t := strings.TrimSpace(l.text)
		switch {
		case t == "" || t[0] == '#' || t[0] == ';':
		case t[0] == '[' && strings.HasSuffix(t, "]"):
			section = strings.ToLower(strings.TrimSpace(t[1 : len(t)-1]))
			l.kind, l.section = lineSection, section
		case strings.Contains(t, "="):
			k, v, _ := strings.Cut(t, "=")
			l.kind, l.section = lineKey, section
			l.key, l.value = strings.ToLower(strings.TrimSpace(k)), strings.TrimSpace(v)
		}
		f.lines = append(f.lines, l)
	}
	return f
}

func (f *ini) render() []byte {
	var b bytes.Buffer
	if f.bom {
		b.Write(utf8BOM)
	}
	for _, l := range f.lines {
		b.WriteString(l.text)
		b.WriteString(l.eol)
	}
	return b.Bytes()
}

// eol is the line ending new lines get: the file's first one, else CRLF.
func (f *ini) eol() string {
	for _, l := range f.lines {
		if l.eol != "" {
			return l.eol
		}
	}
	return "\r\n"
}

// get returns the last value set for the key; later lines win.
func (f *ini) get(section, key string) (string, bool) {
	section, key = strings.ToLower(section), strings.ToLower(key)
	val, ok := "", false
	for _, l := range f.lines {
		if l.kind == lineKey && l.section == section && l.key == key {
			val, ok = l.value, true
		}
	}
	return val, ok
}

// set replaces the key's line in place (original key spelling and spacing),
// or adds it after the section's last line, or adds the section at the end.
func (f *ini) set(section, key, value string) {
	lsec, lkey := strings.ToLower(section), strings.ToLower(key)
	at := -1
	for i, l := range f.lines {
		if l.kind == lineKey && l.section == lsec && l.key == lkey {
			at = i
		}
	}
	if at >= 0 {
		l := &f.lines[at]
		eq := strings.Index(l.text, "=")
		rest := l.text[eq+1:]
		gap := rest[:len(rest)-len(strings.TrimLeft(rest, " \t"))]
		l.text = l.text[:eq+1] + gap + value
		l.value = value
		return
	}
	newLine := iniLine{text: key + "=" + value, kind: lineKey, section: lsec, key: lkey, value: value}
	eol := f.eol()
	head, last := -1, -1
	for i, l := range f.lines {
		if l.kind == lineSection && l.section == lsec {
			head, last = i, i
			continue
		}
		if head >= 0 && l.kind == lineSection {
			break
		}
		if head >= 0 && strings.TrimSpace(l.text) != "" {
			last = i
		}
	}
	if head >= 0 {
		f.insertAfter(last, newLine, eol)
		return
	}
	if n := len(f.lines); n > 0 {
		if f.lines[n-1].eol == "" {
			f.lines[n-1].eol = eol
		}
		if strings.TrimSpace(f.lines[n-1].text) != "" {
			f.lines = append(f.lines, iniLine{eol: eol})
		}
	}
	f.lines = append(f.lines,
		iniLine{text: "[" + section + "]", eol: eol, kind: lineSection, section: lsec},
		newLine)
	f.lines[len(f.lines)-1].eol = eol
}

func (f *ini) insertAfter(i int, l iniLine, eol string) {
	if f.lines[i].eol == "" {
		// the file did not end with a newline; keep it that way
		f.lines[i].eol = eol
	} else {
		l.eol = eol
	}
	f.lines = append(f.lines, iniLine{})
	copy(f.lines[i+2:], f.lines[i+1:])
	f.lines[i+1] = l
}

func (f *ini) hasSection(section string) bool {
	section = strings.ToLower(section)
	for _, l := range f.lines {
		if l.kind == lineSection && l.section == section {
			return true
		}
	}
	return false
}

// bytes is the file as it goes to disk, in the encoding it was read in.
func (f *ini) bytes() []byte { return f.enc.encode(f.render()) }
