package main

import (
	"bytes"
	"unicode/utf16"
)

// textEnc is how a text file was stored, so a write can use the same.
type textEnc struct {
	utf16 bool
	big   bool // big endian
	bom   bool
}

// decodeText returns the file as UTF-8 (without any BOM) and its encoding.
// Windows PowerShell 5.1 Out-File writes UTF-16LE with a BOM. UTF-8 and its
// BOM are left to parseINI, which keeps them as they are.
func decodeText(data []byte) ([]byte, textEnc) {
	var enc textEnc
	switch {
	case bytes.HasPrefix(data, []byte{0xFF, 0xFE}):
		enc = textEnc{utf16: true, bom: true}
		data = data[2:]
	case bytes.HasPrefix(data, []byte{0xFE, 0xFF}):
		enc = textEnc{utf16: true, big: true, bom: true}
		data = data[2:]
	case len(data) >= 2 && bytes.IndexByte(data, 0) >= 0 && data[1] == 0:
		enc = textEnc{utf16: true}
	case len(data) >= 2 && bytes.IndexByte(data, 0) >= 0 && data[0] == 0:
		enc = textEnc{utf16: true, big: true}
	default:
		return data, enc
	}
	u := make([]uint16, len(data)/2)
	for i := range u {
		if enc.big {
			u[i] = uint16(data[2*i])<<8 | uint16(data[2*i+1])
		} else {
			u[i] = uint16(data[2*i]) | uint16(data[2*i+1])<<8
		}
	}
	return []byte(string(utf16.Decode(u))), enc
}

func (e textEnc) encode(utf8Text []byte) []byte {
	if !e.utf16 {
		return utf8Text
	}
	u := utf16.Encode([]rune(string(utf8Text)))
	out := make([]byte, 0, 2+2*len(u))
	if e.bom {
		if e.big {
			out = append(out, 0xFE, 0xFF)
		} else {
			out = append(out, 0xFF, 0xFE)
		}
	}
	for _, c := range u {
		if e.big {
			out = append(out, byte(c>>8), byte(c))
		} else {
			out = append(out, byte(c), byte(c>>8))
		}
	}
	return out
}
