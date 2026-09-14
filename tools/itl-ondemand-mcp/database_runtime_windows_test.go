//go:build windows

package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/windows"
)

func acquireExclusiveRuntimeHandle(path string) (windows.Handle, error) {
	ptr, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return 0, err
	}
	return windows.CreateFile(ptr, windows.GENERIC_READ|windows.GENERIC_WRITE, 0, nil, windows.OPEN_ALWAYS, windows.FILE_ATTRIBUTE_NORMAL, 0)
}

func TestDatabaseRuntimeLockFailureReleasesUnstartedAdmission(t *testing.T) {
	python, runtimeRoot, request := databaseAccessFixture(t)
	rt, broker := newDatabaseRuntimeFixture(t, request, python, runtimeRoot, nil)
	path := filepath.Join(rt.projectRoot, ".agent-1c", "locks", "runtime-mcp.lock")
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	handle, err := acquireExclusiveRuntimeHandle(path)
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

func TestDatabaseRuntimePhaseHandleSurvivesIdleAndReacquiresAfterFinish(t *testing.T) {
	python, runtimeRoot, request := databaseAccessFixture(t)
	rt, _ := newDatabaseRuntimeFixture(t, request, python, runtimeRoot, nil)
	path := filepath.Join(rt.projectRoot, ".agent-1c", "locks", "runtime-mcp.lock")
	requireDatabaseRuntimeCall(t, rt, nil)
	if handle, err := acquireExclusiveRuntimeHandle(path); err == nil {
		windows.CloseHandle(handle)
		t.Fatal("lifecycle writer entered between database calls")
	}
	rt.mu.Lock()
	rt.idleDeadline = time.Now().Add(-time.Second)
	generation := rt.generation
	rt.mu.Unlock()
	if err := rt.stopIdle(context.Background(), generation); err != nil {
		t.Fatal(err)
	}
	if handle, err := acquireExclusiveRuntimeHandle(path); err == nil {
		windows.CloseHandle(handle)
		t.Fatal("idle cleanup handed the phase to a lifecycle writer")
	}
	if _, err := rt.finishDatabaseAccess(context.Background()); err != nil {
		t.Fatal(err)
	}
	handle, err := acquireExclusiveRuntimeHandle(path)
	if err != nil {
		t.Fatal("explicit finish did not release the runtime phase:", err)
	}
	windows.CloseHandle(handle)
	requireDatabaseRuntimeCall(t, rt, nil)
	if handle, err := acquireExclusiveRuntimeHandle(path); err == nil {
		windows.CloseHandle(handle)
		t.Fatal("next database call did not reacquire the runtime phase")
	}
	if _, err := rt.finishDatabaseAccess(context.Background()); err != nil {
		t.Fatal(err)
	}
}
