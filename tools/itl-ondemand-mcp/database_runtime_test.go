package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type executionFixtureBroker struct {
	plan        *facadeExecutionPlan
	runtimeRoot string
	changePlan  bool
	planCalls   int
	stops       int
	stopError   error
}

func (b *executionFixtureBroker) ExecutionPlan(context.Context) (*facadeExecutionPlan, error) {
	b.planCalls++
	copy := *b.plan
	copy.Bases = append([]databaseConnection(nil), b.plan.Bases...)
	if b.changePlan && b.planCalls > 1 {
		copy.TargetBase.Path += " changed"
	}
	return &copy, nil
}
func (b *executionFixtureBroker) ExecutionRuntimeRoot() string { return b.runtimeRoot }
func (b *executionFixtureBroker) Ensure(context.Context) (*backendInfo, error) {
	return &backendInfo{Status: "running", PID: os.Getpid(), URL: "http://fixture", InstanceID: b.plan.InstanceID, Family: b.plan.Family}, nil
}
func (b *executionFixtureBroker) EnsureTestClient(context.Context) (*backendInfo, error) {
	return nil, fmt.Errorf("not used")
}
func (b *executionFixtureBroker) Recover(context.Context, *backendInfo, string) (*backendInfo, error) {
	return nil, fmt.Errorf("not used")
}
func (b *executionFixtureBroker) MarkRunning(context.Context, *backendInfo) (*backendInfo, error) {
	return nil, fmt.Errorf("not used")
}
func (b *executionFixtureBroker) Stop(context.Context) error { b.stops++; return b.stopError }

func newExecutionRuntimeFixture(t *testing.T) (*runtime, *executionFixtureBroker) {
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
	id := "0123456789abcdef0123456789abcdef"
	base := databaseConnection{Kind: "file", Path: filepath.Join(root, "База вызова")}
	plan := &facadeExecutionPlan{SchemaVersion: 2, Family: "roctup", ProjectRoot: root, InstanceID: id,
		GuardRoot: filepath.Join(root, "execution-guards-v2"), ExecutionHost: "localhost",
		WaitTimeoutSeconds: 2, Python: python, Bases: []databaseConnection{base}, TargetBase: base}
	broker := &executionFixtureBroker{plan: plan, runtimeRoot: runtimeRoot}
	rt := &runtime{broker: broker, projectRoot: root, family: "roctup", instanceID: id,
		logger: slog.New(slog.NewTextHandler(os.Stderr, nil)), progress: make(map[string]*progressRoute)}
	return rt, broker
}

func TestOnDemandGuardIsCallScopedAndIdleBackendDoesNotRetainIt(t *testing.T) {
	rt, _ := newExecutionRuntimeFixture(t)
	rt.backend = &backendInfo{Status: "running", PID: os.Getpid(), URL: "http://fixture"}
	_, finish, err := rt.beginDatabaseCall(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if rt.executionOwner == nil {
		t.Fatal("call has no execution owner")
	}
	if err := finish("succeeded", ""); err != nil {
		t.Fatal(err)
	}
	if rt.executionOwner != nil {
		t.Fatal("completed call retained database ownership")
	}
	if rt.backend == nil {
		t.Fatal("guard release stopped the warm idle backend")
	}
	_, finish, err = rt.beginDatabaseCall(context.Background(), nil)
	if err != nil {
		t.Fatalf("terminal diagnostics blocked the next call: %v", err)
	}
	if err := finish("failed", "fixture failure"); err != nil {
		t.Fatal(err)
	}
}

func TestClosedRuntimeIdleCleanupDoesNotWaitForAnotherFacadeGuard(t *testing.T) {
	rt, broker := newExecutionRuntimeFixture(t)
	foreignPlan := *broker.plan
	foreignPlan.InstanceID = "fedcba9876543210fedcba9876543210"
	foreignBroker := &executionFixtureBroker{plan: &foreignPlan, runtimeRoot: broker.runtimeRoot}
	foreign := &runtime{broker: foreignBroker, projectRoot: rt.projectRoot, family: rt.family,
		instanceID: foreignPlan.InstanceID, logger: rt.logger}
	_, finish, err := foreign.beginDatabaseCall(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := finish("succeeded", ""); err != nil {
			t.Error(err)
		}
	}()
	// EOF marks the runtime closed before its owned-stop admission completes.
	// A previously armed idle callback must be a no-op even while the successor
	// facade owns the same database; it has no work to admit or cancel there.
	rt.closed = true
	rt.backend = &backendInfo{Status: "running", PID: os.Getpid(), URL: "http://fixture"}
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	if err := rt.stopIdle(ctx, rt.generation); err != nil {
		t.Fatalf("closed idle callback waited for foreign admission: %v", err)
	}
	if broker.planCalls != 0 || broker.stops != 0 || rt.executionOwner != nil {
		t.Fatal("closed idle callback attempted database admission or native stop")
	}
	if rt.backend == nil || !rt.closed {
		t.Fatal("idle no-op discarded terminal cleanup evidence")
	}
}

func TestSupersededIdleCleanupDoesNotWaitForAnotherFacadeGuard(t *testing.T) {
	rt, broker := newExecutionRuntimeFixture(t)
	foreignPlan := *broker.plan
	foreignPlan.InstanceID = "fedcba9876543210fedcba9876543210"
	foreignBroker := &executionFixtureBroker{plan: &foreignPlan, runtimeRoot: broker.runtimeRoot}
	foreign := &runtime{broker: foreignBroker, projectRoot: rt.projectRoot, family: rt.family,
		instanceID: foreignPlan.InstanceID, logger: rt.logger}
	_, finish, err := foreign.beginDatabaseCall(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := finish("succeeded", ""); err != nil {
			t.Error(err)
		}
	}()
	// A timer may already be waiting for the runtime mutex when a new call
	// cancels it and performs recovery. Once it gets the mutex, that timer's
	// generation has no cleanup authority, even if its context has expired.
	rt.backend = &backendInfo{Status: "running", PID: os.Getpid(), URL: "http://fixture"}
	rt.generation = 2
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := rt.stopIdle(ctx, 1); err != nil {
		t.Fatalf("superseded idle callback attempted admission with expired context: %v", err)
	}
	if broker.planCalls != 0 || broker.stops != 0 || rt.executionOwner != nil {
		t.Fatal("superseded idle callback attempted database admission or native stop")
	}
	if rt.backend == nil || rt.closed || rt.generation != 2 {
		t.Fatal("idle no-op changed the replacement runtime or discarded cleanup evidence")
	}
}

func TestOnDemandRevalidatesPlanAfterAdmission(t *testing.T) {
	rt, broker := newExecutionRuntimeFixture(t)
	broker.changePlan = true
	if _, _, err := rt.beginDatabaseCall(context.Background(), nil); err == nil {
		t.Fatal("changed target was not rejected")
	}
	if rt.executionOwner != nil {
		t.Fatal("failed revalidation retained the guard")
	}
}

func TestFailedCallStopsOwnedBackendBeforeGuardRelease(t *testing.T) {
	rt, broker := newExecutionRuntimeFixture(t)
	rt.backend = &backendInfo{Status: "running", PID: os.Getpid(), URL: "http://fixture"}
	rt.mu.Lock()
	callErr := rt.cleanupFailedDatabaseCallLocked(context.Background(), context.DeadlineExceeded)
	rt.mu.Unlock()
	if !errors.Is(callErr, context.DeadlineExceeded) {
		t.Fatalf("primary deadline was lost: %v", callErr)
	}
	if broker.stops != 1 || rt.backend != nil {
		t.Fatalf("owned backend was not drained before release: stops=%d backend=%+v", broker.stops, rt.backend)
	}
}

func TestUnconfirmedNativeCleanupRetainsTheOriginalGuardUntilExplicitOwnedStop(t *testing.T) {
	rt, broker := newExecutionRuntimeFixture(t)
	ctx, finish, err := rt.beginDatabaseCall(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer rt.close(context.Background())
	owner := rt.executionOwner
	rt.backend = &backendInfo{Status: "running", PID: os.Getpid(), URL: "http://fixture"}
	broker.stopError = fmt.Errorf("original process stop unconfirmed")
	rt.mu.Lock()
	callErr := rt.cleanupFailedDatabaseCallLocked(ctx, context.DeadlineExceeded)
	rt.mu.Unlock()
	if !errors.Is(callErr, context.DeadlineExceeded) {
		t.Fatalf("lost original unknown outcome: %v", callErr)
	}
	if err := finish("failed", callErr.Error()); err == nil || !strings.Contains(err.Error(), "CLEANUP_UNCONFIRMED") {
		t.Fatalf("unconfirmed cleanup was released: %v", err)
	}
	if rt.executionOwner != owner {
		t.Fatal("the original resource owner was replaced")
	}
	contender := executionGuardRequest{SchemaVersion: 1, Root: broker.plan.GuardRoot, Bases: broker.plan.Bases, Operation: "different-writer", ExecutionID: strings.Repeat("c", 32), Timeout: 0.1}
	if unexpected, err := acquireExecutionGuard(context.Background(), broker.plan.Python, broker.runtimeRoot, contender, nil); err == nil {
		_ = unexpected.Close()
		t.Fatal("another writer was admitted before native cleanup")
	}
	if _, _, err := rt.beginDatabaseCall(context.Background(), nil); err == nil || !strings.Contains(err.Error(), "CLEANUP_UNCONFIRMED") {
		t.Fatalf("a new tool call inherited the pending execution: %v", err)
	}
	broker.stopError = nil
	if err := rt.stop(context.Background()); err != nil {
		t.Fatalf("explicit owned cleanup could not continue its original guard: %v", err)
	}
	if rt.executionOwner != nil || rt.cleanupUnconfirmed || rt.backend != nil {
		t.Fatal("confirmed stop did not finalize its original owner")
	}
	contender.Timeout = 2
	contender.ExecutionID = strings.Repeat("d", 32)
	next, err := acquireExecutionGuard(context.Background(), broker.plan.Python, broker.runtimeRoot, contender, nil)
	if err != nil {
		t.Fatalf("confirmed cleanup did not admit the next writer: %v", err)
	}
	_ = next.Close()
}

func TestNestedOnDemandCallUsesSignedParentContextWithoutReacquisition(t *testing.T) {
	parentRuntime, _ := newExecutionRuntimeFixture(t)
	_, finishParent, err := parentRuntime.beginDatabaseCall(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer finishParent("succeeded", "")
	proof := parentRuntime.executionOwner.Proof
	if !executionIDPattern.MatchString(proof.ID) {
		t.Fatalf("parent context exposed a non-canonical execution id: %q", proof.ID)
	}

	childRuntime, childBroker := newExecutionRuntimeFixture(t)
	childBroker.plan.GuardRoot = parentRuntime.executionPlan.GuardRoot
	childBroker.plan.Bases = append([]databaseConnection(nil), parentRuntime.executionPlan.Bases...)
	childBroker.plan.TargetBase = parentRuntime.executionPlan.TargetBase
	meta := mcp.Meta{executionContextMetaKey: proof.Encoded, executionContextKeyMetaKey: proof.Key}
	_, finishChild, err := childRuntime.beginDatabaseCall(context.Background(), meta)
	if err != nil {
		t.Fatalf("nested call tried to reacquire the parent guard: %v", err)
	}
	if childRuntime.executionOwner.Proof.ID != proof.ID {
		t.Fatalf("nested context changed execution id: parent=%s child=%s", proof.ID, childRuntime.executionOwner.Proof.ID)
	}
	if err := finishChild("succeeded", ""); err != nil {
		t.Fatal(err)
	}
}

func TestSameBaseCallWaitIsVisibleAndBounded(t *testing.T) {
	first, _ := newExecutionRuntimeFixture(t)
	_, finishFirst, err := first.beginDatabaseCall(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer finishFirst("succeeded", "")
	second, secondBroker := newExecutionRuntimeFixture(t)
	secondBroker.plan.GuardRoot = first.executionPlan.GuardRoot
	secondBroker.plan.Bases = append([]databaseConnection(nil), first.executionPlan.Bases...)
	secondBroker.plan.TargetBase = first.executionPlan.TargetBase
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancel()
	if _, _, err := second.beginDatabaseCall(ctx, nil); err == nil {
		t.Fatal("second same-base call did not wait")
	}
}
