//go:build windows

package main

import (
	"fmt"
	"os"
	"path/filepath"

	"golang.org/x/sys/windows"
)

func createAccessDeniedProbe(featureDirectory string) (string, func() error, error) {
	path := filepath.Join(featureDirectory, ".itl-path-access-denied.feature")
	if err := os.WriteFile(path, []byte("#language: ru\r\n"), 0o600); err != nil {
		return "", nil, err
	}
	pathUTF16, err := windows.UTF16PtrFromString(path)
	if err != nil {
		_ = os.Remove(path)
		return "", nil, err
	}
	handle, err := windows.CreateFile(
		pathUTF16,
		windows.GENERIC_READ|windows.GENERIC_WRITE,
		0,
		nil,
		windows.OPEN_EXISTING,
		windows.FILE_ATTRIBUTE_NORMAL,
		0,
	)
	if err != nil {
		_ = os.Remove(path)
		return "", nil, err
	}
	closed := false
	cleanup := func() error {
		if !closed {
			if err := windows.CloseHandle(handle); err != nil {
				return fmt.Errorf("close exclusive probe handle: %w", err)
			}
			closed = true
		}
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("remove exclusive probe file: %w", err)
		}
		return nil
	}
	return path, cleanup, nil
}
