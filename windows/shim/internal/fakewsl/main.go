// fakewsl stands in for wsl.exe in the shim's tests. Env:
//
//	FAKE_WSL_RECORD        file that gets one JSON line per event
//	FAKE_WSL_RECORD_STDIN  1: record the stdin bytes (echo-stdin mode)
//	FAKE_WSL_MODE          exit:N | seq:N,N,... | echo-stdin | run | wait-signal | probe:FILE
//	FAKE_WSL_READY         wait-signal: file created once the handler is set
//	FAKE_WSL_PROBE_AFTER   probe: file printed after a loginctl call was recorded
package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
)

type record struct {
	Event   string   `json:"event"`
	Args    []string `json:"args,omitempty"`
	Distro  string   `json:"distro,omitempty"`
	Cd      string   `json:"cd,omitempty"`
	Exec    []string `json:"exec,omitempty"`
	WSLUTF8 string   `json:"wsl_utf8,omitempty"`
	Stdin   string   `json:"stdin_b64,omitempty"`
	Signal  string   `json:"signal,omitempty"`
}

// blob is written to stdout in echo-stdin mode: CRLF, LF, NUL, UTF-8 and
// bytes that are not UTF-8.
var blob = []byte("bin\r\nline\nnul\x00end é 日本 \U0001F600 \xff\xfe\r\n")

func write(r record) {
	path := os.Getenv("FAKE_WSL_RECORD")
	if path == "" {
		return
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	b, _ := json.Marshal(r)
	f.Write(append(b, '\n'))
}

func loginctlSeen() bool {
	data, err := os.ReadFile(os.Getenv("FAKE_WSL_RECORD"))
	return err == nil && bytes.Contains(data, []byte(`"exec":["loginctl"`))
}

// startCount is the number of start events recorded so far, this one included.
func startCount() int {
	data, err := os.ReadFile(os.Getenv("FAKE_WSL_RECORD"))
	if err != nil {
		return 1
	}
	return bytes.Count(data, []byte(`"event":"start"`))
}

func main() {
	args := os.Args[1:]
	r := record{Event: "start", Args: args, WSLUTF8: os.Getenv("WSL_UTF8")}
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "-d", "--distribution":
			if i+1 < len(args) {
				r.Distro = args[i+1]
				i++
			}
		case "--cd":
			if i+1 < len(args) {
				r.Cd = args[i+1]
				i++
			}
		case "--exec", "-e", "--":
			r.Exec = args[i+1:]
			i = len(args)
		}
	}
	write(r)

	mode := os.Getenv("FAKE_WSL_MODE")
	switch {
	case strings.HasPrefix(mode, "seq:"):
		// seq:127,0 exits 127 on the first call, 0 on the second, then the last again
		codes := strings.Split(strings.TrimPrefix(mode, "seq:"), ",")
		n := startCount() - 1
		if n >= len(codes) {
			n = len(codes) - 1
		}
		c, _ := strconv.Atoi(codes[n])
		os.Exit(c)
	case strings.HasPrefix(mode, "exit:"):
		n, _ := strconv.Atoi(strings.TrimPrefix(mode, "exit:"))
		os.Exit(n)
	case mode == "echo-stdin":
		in, _ := io.ReadAll(os.Stdin)
		if os.Getenv("FAKE_WSL_RECORD_STDIN") == "1" {
			write(record{Event: "stdin", Stdin: base64.StdEncoding.EncodeToString(in)})
		}
		os.Stdout.Write(in)
		os.Stdout.Write(blob)
	case mode == "run":
		if len(r.Exec) == 0 {
			os.Exit(1)
		}
		cmd := exec.Command(r.Exec[0], r.Exec[1:]...)
		cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
		if err := cmd.Run(); err != nil {
			if ee, ok := err.(*exec.ExitError); ok {
				os.Exit(ee.ExitCode())
			}
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	case mode == "wait-signal":
		ch := make(chan os.Signal, 1)
		signal.Notify(ch, os.Interrupt)
		if ready := os.Getenv("FAKE_WSL_READY"); ready != "" {
			os.WriteFile(ready, []byte("ready"), 0o644)
		}
		<-ch
		write(record{Event: "signal", Signal: "interrupt"})
		os.Exit(130)
	case strings.HasPrefix(mode, "probe:"):
		if len(r.Exec) > 0 && r.Exec[0] == "loginctl" {
			// FAKE_WSL_LINGER_REFUSE: refuse as polkit does outside a session
			if os.Getenv("FAKE_WSL_LINGER_REFUSE") != "" {
				fmt.Fprintln(os.Stderr, "Could not enable linger: Interactive authentication required.")
				os.Exit(1)
			}
			os.Exit(0)
		}
		file := strings.TrimPrefix(mode, "probe:")
		if after := os.Getenv("FAKE_WSL_PROBE_AFTER"); after != "" && loginctlSeen() {
			file = after
		}
		data, err := os.ReadFile(file)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		os.Stdout.Write(data)
	}
}
