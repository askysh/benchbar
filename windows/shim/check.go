package main

import (
	"encoding/json"
	"fmt"
	"io"
	"strings"
)

// Check is one doctor style line.
type Check struct {
	ID      string `json:"id"`
	Label   string `json:"-"`
	Status  string `json:"status"` // ok, warn, fail
	Message string `json:"message"`
	Fix     string `json:"fix"`
}

func printCheck(w io.Writer, c Check) {
	fmt.Fprintf(w, "  [%s] %s: %s\n", strings.ToUpper(c.Status), c.Label, c.Message)
	if c.Fix != "" {
		fmt.Fprintf(w, "     fix: %s\n", c.Fix)
	}
}

func printChecks(w io.Writer, checks []Check) {
	for _, c := range checks {
		printCheck(w, c)
	}
}

func printSummary(w io.Writer, checks []Check) {
	fmt.Fprintf(w, "\n  %d ok, %d warn, %d fail\n",
		countStatus(checks, "ok"), countStatus(checks, "warn"), countStatus(checks, "fail"))
}

func countStatus(checks []Check, status string) int {
	n := 0
	for _, c := range checks {
		if c.Status == status {
			n++
		}
	}
	return n
}

func hasFail(checks []Check) bool { return countStatus(checks, "fail") > 0 }

func printJSON(w io.Writer, v any) {
	b, _ := json.Marshal(v)
	fmt.Fprintf(w, "%s\n", b)
}

// problem is a stop with the command that fixes it.
type problem struct {
	Msg string
	Fix string
}

func (p *problem) print(sys *System) {
	fmt.Fprintf(sys.Stderr, "benchbar.exe: %s. fix: %s\n", p.Msg, p.Fix)
}
