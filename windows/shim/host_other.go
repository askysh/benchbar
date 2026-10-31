//go:build !windows

package main

import (
	"errors"
	"time"
)

type unsupportedHost struct{}

func (unsupportedHost) WindowsBuild() (int, error)           { return 0, errNotWindows }
func (unsupportedHost) VirtualizationEnabled() (bool, error) { return false, errNotWindows }
func (unsupportedHost) BootTime() (time.Time, error)         { return time.Time{}, errNotWindows }
func (unsupportedHost) IsAdmin() bool                        { return false }

type unsupportedElevator struct{}

func (unsupportedElevator) Start(string, []string) (ElevatedProc, error) {
	return nil, errors.New("elevation is only available on Windows")
}

func osHost() (HostInfo, Elevator) { return unsupportedHost{}, unsupportedElevator{} }
