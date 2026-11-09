package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
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

// retainUnconfirmedOwner leaves the facade exactly where branch8 stopped: a
// failed native cleanup retains the call's guard across tool calls.
func retainUnconfirmedOwner(t *testing.T, rt *runtime, broker *executionFixtureBroker) *executionGuardOwner {
	t.Helper()
	ctx, finish, err := rt.beginDatabaseCall(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	owner := rt.executionOwner
	rt.backend = &backendInfo{Status: "running", PID: os.Getpid(), URL: "http://fixture"}
	broker.stopError = fmt.Errorf("original process stop unconfirmed")
	rt.mu.Lock()
	callErr := rt.cleanupFailedDatabaseCallLocked(ctx, context.DeadlineExceeded)
	rt.mu.Unlock()
	err = finish("failed", callErr.Error())
	if err == nil || !strings.Contains(err.Error(), "CLEANUP_UNCONFIRMED") || !strings.Contains(err.Error(), branchHolderRepairAction) {
		t.Fatalf("retention did not route to the branch holder repair: %v", err)
	}
	if rt.executionOwner != owner {
		t.Fatal("the original resource owner was not retained")
	}
	return owner
}

// The worktree's own release stops the guard host, as repair-dev-branch-tooling
// and a waiting lifecycle do for a cleanup-unconfirmed holder.
func releaseExternally(t *testing.T, owner *executionGuardOwner) {
	t.Helper()
	if err := owner.command.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-owner.done:
	case <-time.After(10 * time.Second):
		t.Fatal("released guard host did not exit")
	}
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

	owner := retainUnconfirmedOwner(t, rt, broker)
	defer rt.close(context.Background())
	if state := readGuardRecord(t, broker.plan, owner.Proof.ID)["holderState"]; state != holderStateCleanupUnconfirmed {
		t.Fatalf("retained owner did not tell the worktree release that it does no work: %v", state)
	}
}

func TestFacadeResetsItselfAfterItsRetainedGuardWasReleased(t *testing.T) {
	rt, broker := newExecutionRuntimeFixture(t)
	owner := retainUnconfirmedOwner(t, rt, broker)
	defer rt.close(context.Background())
	releaseExternally(t, owner)
	broker.stopError = nil
	stopsBefore := broker.stops

	_, finish, err := rt.beginDatabaseCall(context.Background(), nil)
	if err != nil {
		t.Fatalf("the same facade stayed blocked after its guard was released: %v", err)
	}
	if broker.stops != stopsBefore+1 || rt.backend != nil || rt.cleanupUnconfirmed {
		t.Fatalf("pending owned cleanup did not run under a fresh guard: stops=%d backend=%+v", broker.stops-stopsBefore, rt.backend)
	}
	if rt.executionOwner == nil || rt.executionOwner == owner {
		t.Fatal("the next call did not get its own admission")
	}
	if err := finish("succeeded", ""); err != nil {
		t.Fatal(err)
	}
	assertBaseAdmitsAnotherWriter(t, broker, "e")
}

func TestFacadeDropsAnUnconfirmedReleasedOwnerWithoutRetainingTheNextGuard(t *testing.T) {
	rt, broker := newExecutionRuntimeFixture(t)
	owner := retainUnconfirmedOwner(t, rt, broker)
	defer rt.close(context.Background())
	releaseExternally(t, owner)

	_, _, err := rt.beginDatabaseCall(context.Background(), nil)
	if err == nil || !strings.Contains(err.Error(), "ITL_ONDEMAND_SELF_RESET_CLEANUP_UNCONFIRMED") ||
		!strings.Contains(err.Error(), branchHolderRepairAction) || !strings.Contains(err.Error(), "no call was replayed") {
		t.Fatalf("an unconfirmed stop after external release lost its repair route: %v", err)
	}
	if rt.executionOwner != nil || rt.cleanupUnconfirmed || rt.backend != nil || rt.session != nil {
		t.Fatal("the facade retained state of the dropped backend")
	}
	assertBaseAdmitsAnotherWriter(t, broker, "f")

	stopsBefore := broker.stops
	_, finish, err := rt.beginDatabaseCall(context.Background(), nil)
	if err != nil {
		t.Fatalf("the reset facade did not admit its next call: %v", err)
	}
	if broker.stops != stopsBefore {
		t.Fatal("the reset facade retried the dropped owner's cleanup")
	}
	if err := finish("succeeded", ""); err != nil {
		t.Fatal(err)
	}
}

func TestLiveRetainedOwnerIsNotResetWithoutRelease(t *testing.T) {
	rt, broker := newExecutionRuntimeFixture(t)
	owner := retainUnconfirmedOwner(t, rt, broker)
	defer rt.close(context.Background())
	if _, _, err := rt.beginDatabaseCall(context.Background(), nil); err == nil ||
		!strings.Contains(err.Error(), "CLEANUP_UNCONFIRMED") || !strings.Contains(err.Error(), branchHolderRepairAction) {
		t.Fatalf("a live unconfirmed owner was bypassed: %v", err)
	}
	if rt.executionOwner != owner || !rt.cleanupUnconfirmed {
		t.Fatal("a live retained owner was reset without an external release")
	}
	if state := readGuardRecord(t, broker.plan, owner.Proof.ID)["holderState"]; state != holderStateCleanupUnconfirmed {
		t.Fatalf("failed owned cleanup did not return the holder to cleanup-unconfirmed: %v", state)
	}
	contender := executionGuardRequest{SchemaVersion: 1, Root: broker.plan.GuardRoot, Bases: broker.plan.Bases,
		Operation: "different-writer", ExecutionID: strings.Repeat("a", 32), Timeout: 0.1}
	if unexpected, err := acquireExecutionGuard(context.Background(), broker.plan.Python, broker.runtimeRoot, contender, nil); err == nil {
		_ = unexpected.Close()
		t.Fatal("another writer was admitted while native cleanup is unconfirmed")
	}
}
