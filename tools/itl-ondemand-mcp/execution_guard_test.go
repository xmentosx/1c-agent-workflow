package main

import (
	"context"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func executionGuardFixture(t *testing.T) (string, string, executionGuardRequest) {
	t.Helper()
	python, err := exec.LookPath("python")
	if err != nil {
		t.Skip("python is unavailable")
	}
	runtimeRoot, err := filepath.Abs(filepath.Join("..", "..", ".agents", "skills", "itl-remote-runner", "scripts"))
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	request := executionGuardRequest{SchemaVersion: 1, Root: filepath.Join(root, "execution-guards-v2"),
		Bases:     []databaseConnection{{Kind: "file", Path: filepath.Join(root, "База с пробелом")}},
		Operation: "ondemand-test-call", ExecutionID: strings.Repeat("a", 32), Timeout: 2}
	return python, runtimeRoot, request
}

func TestNewExecutionIDUsesCanonicalCrossProcessFormat(t *testing.T) {
	first, err := newExecutionID()
	if err != nil {
		t.Fatal(err)
	}
	second, err := newExecutionID()
	if err != nil {
		t.Fatal(err)
	}
	if !executionIDPattern.MatchString(first) || !executionIDPattern.MatchString(second) {
		t.Fatalf("non-canonical execution IDs: %q %q", first, second)
	}
	if first == second {
		t.Fatal("execution IDs unexpectedly collided")
	}
}

func TestExecutionGuardHostReleasesTerminalCall(t *testing.T) {
	python, runtimeRoot, request := executionGuardFixture(t)
	owner, err := acquireExecutionGuard(context.Background(), python, runtimeRoot, request, nil)
	if err != nil {
		t.Fatal(err)
	}
	if owner.Proof.Encoded == "" || owner.Proof.Key == "" || owner.Proof.ID == "" || len(owner.Proof.Resources) != 1 {
		t.Fatalf("invalid proof: %#v", owner.Proof)
	}
	if err := owner.Release(context.Background(), "succeeded", ""); err != nil {
		t.Fatal(err)
	}

	request.ExecutionID = strings.Repeat("b", 32)
	next, err := acquireExecutionGuard(context.Background(), python, runtimeRoot, request, nil)
	if err != nil {
		t.Fatalf("terminal diagnostics blocked the next call: %v", err)
	}
	if err := next.Release(context.Background(), "failed", "fixture failure"); err != nil {
		t.Fatal(err)
	}
}

func TestExecutionGuardHostWaitIsBoundedAndOwnerSurvivesWaiterCancel(t *testing.T) {
	python, runtimeRoot, request := executionGuardFixture(t)
	owner, err := acquireExecutionGuard(context.Background(), python, runtimeRoot, request, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer owner.Close()
	waiterRequest := request
	waiterRequest.ExecutionID = strings.Repeat("c", 32)
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancel()
	if _, err := acquireExecutionGuard(ctx, python, runtimeRoot, waiterRequest, nil); err == nil {
		t.Fatal("same-base waiter unexpectedly acquired the live owner")
	}
	if owner.command.ProcessState != nil {
		t.Fatal("cancelling a waiter stopped the owner")
	}
	if err := owner.Release(context.Background(), "succeeded", ""); err != nil {
		t.Fatal(err)
	}
}
