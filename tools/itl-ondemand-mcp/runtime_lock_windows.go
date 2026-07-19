//go:build windows

package main

import (
	"fmt"
	"os"
	"path/filepath"

	"golang.org/x/sys/windows"
)

type runtimeReadLock struct{ handle windows.Handle }

func acquireRuntimeReadLock(path string) (*runtimeReadLock, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	ptr, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	handle, err := windows.CreateFile(ptr, windows.GENERIC_READ, windows.FILE_SHARE_READ, nil, windows.OPEN_ALWAYS, windows.FILE_ATTRIBUTE_NORMAL, 0)
	if err != nil {
		return nil, fmt.Errorf("acquire shared runtime lock %s: %w", path, err)
	}
	return &runtimeReadLock{handle: handle}, nil
}

func (l *runtimeReadLock) Close() error { return windows.CloseHandle(l.handle) }
