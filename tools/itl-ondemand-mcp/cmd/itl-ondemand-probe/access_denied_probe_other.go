//go:build !windows

package main

import "fmt"

func createAccessDeniedProbe(string) (string, func() error, error) {
	return "", nil, fmt.Errorf("set ITL_VANESSA_ACCESS_DENIED_PROBE_PATH to an existing unreadable file on this platform")
}
