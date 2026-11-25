package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func readGuardRecord(t *testing.T, plan *facadeExecutionPlan, executionID string) map[string]any {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(plan.GuardRoot, "executions", executionID+".json"))
	if err != nil {
		t.Fatal(err)
	}
	var record map[string]any
	if err := json.Unmarshal(raw, &record); err != nil {
		t.Fatal(err)
	}
	return record
}

func assertBaseAdmitsAnotherWriter(t *testing.T, broker *executionFixtureBroker, id string) {
	t.Helper()
	contender := executionGuardRequest{SchemaVersion: 1, Root: broker.plan.GuardRoot, Bases: broker.plan.Bases,
		Operation: "different-writer", ExecutionID: strings.Repeat(id, 32), Timeout: 2}
	next, err := acquireExecutionGuard(context.Background(), broker.plan.Python, broker.runtimeRoot, contender, nil)
	if err != nil {
		t.Fatalf("the facade still holds the base: %v", err)
	}
	if err := next.Release(context.Background(), "succeeded", ""); err != nil {
		t.Fatal(err)
	}
}

func TestFacadeGuardPublishesWorktreeAndHolderPhase(t *testing.T) {
	rt, broker := newExecutionRuntimeFixture(t)
	broker.plan.ProjectRoot = filepath.Join(rt.projectRoot, "Рабочая копия ветки")
	_, finish, err := rt.beginDatabaseCall(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	record := readGuardRecord(t, broker.plan, rt.executionOwner.Proof.ID)
	if record["projectRoot"] != broker.plan.ProjectRoot || record["holderState"] != holderStateActiveNativeCall {
		t.Fatalf("active call did not publish its worktree and phase: %v", record)
	}
	if err := finish("succeeded", ""); err != nil {
		t.Fatal(err)
	}
	assertBaseAdmitsAnotherWriter(t, broker, "b")
}

// Branch8 reproducer at the facade boundary: a failed owned stop used to keep
// the guard until the same facade proved cleanup. The facade now ends that
// execution itself, so neither repair nor a waiting lifecycle is needed to
// admit the base, and the next call through the same facade starts afresh.
func TestFacadeResetsItselfWhenItsOwnedStopStaysUnconfirmed(t *testing.T) {
	rt, broker := newExecutionRuntimeFixture(t)
	ctx, finish, err := rt.beginDatabaseCall(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	rt.backend = &backendInfo{Status: "running", PID: os.Getpid(), URL: "http://fixture"}
	broker.stopError = fmt.Errorf("original process stop unconfirmed")
	rt.mu.Lock()
	callErr := rt.cleanupFailedDatabaseCallLocked(ctx, context.DeadlineExceeded)
	rt.mu.Unlock()
	err = finish("failed", callErr.Error())
	if err == nil || !strings.Contains(err.Error(), "CLEANUP_UNCONFIRMED") || !strings.Contains(err.Error(), "no uncertain call was replayed") {
		t.Fatalf("an unconfirmed stop lost its unknown-outcome report: %v", err)
	}
	if rt.executionOwner != nil || rt.cleanupUnconfirmed || rt.backend != nil || rt.session != nil {
		t.Fatal("the facade retained state of the dropped backend")
	}
	assertBaseAdmitsAnotherWriter(t, broker, "f")

	stopsBefore := broker.stops
	_, finish, err = rt.beginDatabaseCall(context.Background(), nil)
	if err != nil {
		t.Fatalf("the reset facade did not admit its next call: %v", err)
	}
	if broker.stops != stopsBefore {
		t.Fatal("the reset facade retried the dropped backend's cleanup")
	}
	if err := finish("succeeded", ""); err != nil {
		t.Fatal(err)
	}
}

// A dropped backend's registration must not block the next start: the facade
// continues under a new instance and leaves the old one to the lifecycle drain.
func TestResetRotatesThePowerShellBrokerInstance(t *testing.T) {
	broker := &powershellBroker{InstanceID: strings.Repeat("a", 32), cleanupConfirmed: true,
		lastBackend: &backendInfo{InstanceID: strings.Repeat("a", 32), PID: 10, Port: 20}}
	rt := &runtime{broker: broker, instanceID: broker.InstanceID, cleanupUnconfirmed: true,
		backend: broker.lastBackend, progress: make(map[string]*progressRoute)}
	rt.resetBackendLocked()
	if rt.instanceID == strings.Repeat("a", 32) || broker.InstanceID != rt.instanceID || len(rt.instanceID) != 32 {
		t.Fatalf("reset did not rotate the instance: runtime=%s broker=%s", rt.instanceID, broker.InstanceID)
	}
	if broker.lastBackend != nil || broker.cleanupConfirmed || rt.backend != nil || rt.cleanupUnconfirmed {
		t.Fatal("reset kept the dropped backend's identity")
	}
}
