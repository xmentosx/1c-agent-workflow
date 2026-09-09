//go:build windows

package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/sys/windows"
)

func TestDatabaseRuntimeLockFailureReleasesUnstartedAdmission(t *testing.T) {
	python, runtimeRoot, request := databaseAccessFixture(t)
	rt, broker := newDatabaseRuntimeFixture(t, request, python, runtimeRoot, nil)
	path := filepath.Join(rt.projectRoot, ".agent-1c", "locks", "runtime-mcp.lock")
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	ptr, err := windows.UTF16PtrFromString(path)
	if err != nil {
		t.Fatal(err)
	}
	handle, err := windows.CreateFile(ptr, windows.GENERIC_READ|windows.GENERIC_WRITE, 0, nil, windows.OPEN_ALWAYS, windows.FILE_ATTRIBUTE_NORMAL, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer windows.CloseHandle(handle)
	result, err := databaseRuntimeCall(context.Background(), rt, nil)
	if err != nil || !result.IsError || !strings.Contains(resultText(result), "ITL_ONDEMAND_RUNTIME_LOCK") {
		t.Fatal("exclusive runtime writer was bypassed", err)
	}
	if ensures, _ := broker.counts(); ensures != 0 {
		t.Fatal("native work started behind an exclusive runtime writer")
	}
	owner := acquireDatabaseFixture(t, python, runtimeRoot, request)
	releaseDatabaseFixture(t, owner, nil)
}
