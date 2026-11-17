//go:build !windows

package main

import "runtime"

func machineArch() string { return runtime.GOARCH }

func systemProxySettings() (server, override string, ok bool) { return "", "", false }

func processImages(string) []string { return nil }
