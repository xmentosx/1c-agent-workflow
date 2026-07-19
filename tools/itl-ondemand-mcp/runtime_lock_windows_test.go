//go:build windows

package main

import (
	"path/filepath"
	"testing"

	"golang.org/x/sys/windows"
)

func TestRuntimeReadLocksShareAndBlockExclusiveWriter(t *testing.T) {
	path := filepath.Join(t.TempDir(), "runtime-mcp.lock")
	first, err := acquireRuntimeReadLock(path)
	if err != nil {
		t.Fatal(err)
	}
	second, err := acquireRuntimeReadLock(path)
	if err != nil {
		t.Fatal(err)
	}
	ptr, err := windows.UTF16PtrFromString(path)
	if err != nil {
		t.Fatal(err)
	}
	if handle, err := windows.CreateFile(ptr, windows.GENERIC_READ|windows.GENERIC_WRITE, 0, nil, windows.OPEN_ALWAYS, windows.FILE_ATTRIBUTE_NORMAL, 0); err == nil {
		windows.CloseHandle(handle)
		t.Fatal("exclusive writer acquired while shared readers were active")
	}
	if err := second.Close(); err != nil {
		t.Fatal(err)
	}
	if err := first.Close(); err != nil {
		t.Fatal(err)
	}
	handle, err := windows.CreateFile(ptr, windows.GENERIC_READ|windows.GENERIC_WRITE, 0, nil, windows.OPEN_ALWAYS, windows.FILE_ATTRIBUTE_NORMAL, 0)
	if err != nil {
		t.Fatalf("exclusive writer did not acquire after readers closed: %v", err)
	}
	if err := windows.CloseHandle(handle); err != nil {
		t.Fatal(err)
	}
}
