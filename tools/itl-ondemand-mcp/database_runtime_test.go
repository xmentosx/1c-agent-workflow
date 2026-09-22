package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
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
func (b *executionFixtureBroker) Stop(context.Context) error { b.stops++; return nil }

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
