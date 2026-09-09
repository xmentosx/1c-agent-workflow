package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type databaseFixtureBroker struct {
	*fakeBroker
	plan        *facadeDatabasePlan
	runtimeRoot string
	statePath   string
}

func (b *databaseFixtureBroker) DatabaseAccessPlan(context.Context) (*facadeDatabasePlan, error) {
	return b.plan, nil
}
func (b *databaseFixtureBroker) DatabaseRuntimeRoot() string { return b.runtimeRoot }
func (b *databaseFixtureBroker) check(ctx context.Context) error {
	invocation, ok := ctx.Value(databaseInvocationKey{}).(*databaseInvocation)
	if !ok || invocation.Proof == nil || invocation.Plan.ProjectRoot != b.plan.ProjectRoot {
		return fmt.Errorf("missing scoped ownership")
	}
	child, err := acquireDatabasePipeOwner(ctx, b.plan.Python, b.runtimeRoot, databaseAccessRequest{
		SchemaVersion: 1, Coordinator: invocation.Plan.Coordinator, Bases: invocation.Plan.Bases, Timeout: 1,
		Owner: map[string]any{"operation": "native-broker-fixture"}, Inherited: invocation.Proof,
	}, nil)
	if err != nil {
		return err
	}
	defer child.Close()
	_, err = child.Release(ctx, nil)
	return err
}
func (b *databaseFixtureBroker) Ensure(ctx context.Context) (*backendInfo, error) {
	if err := b.check(ctx); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(b.statePath), 0700); err != nil {
		return nil, err
	}
	if err := os.WriteFile(b.statePath, []byte("fixture-native-state"), 0600); err != nil {
		return nil, err
	}
	return b.fakeBroker.Ensure(ctx)
}
func (b *databaseFixtureBroker) Stop(ctx context.Context) error {
	if err := b.check(ctx); err != nil {
		return err
	}
	if _, err := os.Stat(b.statePath); err != nil {
		return fmt.Errorf("ITL_ONDEMAND_STOP_UNCONFIRMED")
	}
	if err := b.fakeBroker.Stop(ctx); err != nil {
		return err
	}
	return os.Remove(b.statePath)
}

func newDatabaseRuntimeFixture(t *testing.T, request databaseAccessRequest, python, runtimeRoot string, handler func(context.Context, *mcp.CallToolRequest) (*mcp.CallToolResult, error)) (*runtime, *databaseFixtureBroker) {
	t.Helper()
	root := filepath.Join(t.TempDir(), "Проект с пробелом")
	id := strings.Repeat("a", 32)
	definitions := integrationTools()
	server := mcp.NewServer(&mcp.Implementation{Name: "database-backend", Version: "1"}, nil)
	for _, definition := range definitions {
		server.AddTool(definition, func(ctx context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			if handler != nil {
				return handler(ctx, req)
			}
			return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: "complete"}}}, nil
		})
	}
	backend := httptest.NewServer(mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server { return server }, nil))
	t.Cleanup(backend.Close)
	plan := &facadeDatabasePlan{SchemaVersion: 1, Family: "roctup", ProjectRoot: root, InstanceID: id, Coordinator: request.Coordinator,
		Python: python, Bases: request.Bases, TargetBase: request.Bases[0], PrimaryBase: &request.Bases[0], WaitTimeoutSeconds: .15}
	broker := &databaseFixtureBroker{fakeBroker: &fakeBroker{info: &backendInfo{URL: backend.URL, PID: 4242, Port: 48111, InstanceID: id}},
		plan: plan, runtimeRoot: runtimeRoot, statePath: filepath.Join(root, ".agent-1c", "mcp", "ondemand", "roctup", id+".json")}
	rt := &runtime{catalog: &loadedCatalog{SHA256: "catalog", Data: catalogFile{SchemaVersion: 1, Family: "roctup", Tools: definitions}},
		broker: broker, projectRoot: root, family: "roctup", instanceID: id, idle: time.Hour, logger: slog.New(slog.NewTextHandler(io.Discard, nil)), progress: make(map[string]*progressRoute)}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = rt.close(ctx)
		if rt.databaseOwner != nil {
			_ = rt.databaseOwner.Close()
		}
	})
	return rt, broker
}

func databaseRuntimeCall(ctx context.Context, rt *runtime, meta mcp.Meta) (*mcp.CallToolResult, error) {
	return rt.callNamed(ctx, &mcp.CallToolRequest{Params: &mcp.CallToolParamsRaw{Meta: meta}}, "echo", map[string]any{"value": "test"})
}

func requireDatabaseRuntimeCall(t *testing.T, rt *runtime, meta mcp.Meta) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	result, err := databaseRuntimeCall(ctx, rt, meta)
	if err != nil || result == nil || result.IsError {
		t.Fatalf("runtime call: %v %s", err, resultText(result))
	}
}

func TestDatabaseRuntimeRetainsIdleBackendAndAllowsUnrelatedDatabase(t *testing.T) {
	python, runtimeRoot, request := databaseAccessFixture(t)
	first, _ := newDatabaseRuntimeFixture(t, request, python, runtimeRoot, nil)
	second, secondBroker := newDatabaseRuntimeFixture(t, request, python, runtimeRoot, nil)
	requireDatabaseRuntimeCall(t, first, nil)
	result, err := databaseRuntimeCall(context.Background(), second, nil)
	if err != nil || !result.IsError || !strings.Contains(resultText(result), "WAIT_TIMEOUT") {
		t.Fatalf("second owner was not excluded: %v %s", err, resultText(result))
	}
	if ensures, _ := secondBroker.counts(); ensures != 0 {
		t.Fatal("waiting project started a backend")
	}
	if _, err := os.Stat(filepath.Join(second.projectRoot, ".agent-1c", "locks", "runtime-mcp.lock")); !os.IsNotExist(err) {
		t.Fatal("global admission waiter touched the local runtime lock")
	}
	otherRequest := request
	otherRequest.Bases = []databaseConnection{{Kind: "file", Path: request.Bases[0].Path + " другая"}}
	other, _ := newDatabaseRuntimeFixture(t, otherRequest, python, runtimeRoot, nil)
	requireDatabaseRuntimeCall(t, other, nil)
	first.mu.Lock()
	first.idleDeadline = time.Now().Add(-time.Second)
	generation := first.generation
	first.mu.Unlock()
	if err := first.stopIdle(context.Background(), generation); err != nil {
		t.Fatal(err)
	}
	requireDatabaseRuntimeCall(t, second, nil)
}

func TestDatabaseRuntimeSerializesCallsWithCancellableWait(t *testing.T) {
	python, runtimeRoot, request := databaseAccessFixture(t)
	entered, release := make(chan struct{}), make(chan struct{})
	var calls atomic.Int32
	rt, _ := newDatabaseRuntimeFixture(t, request, python, runtimeRoot, func(ctx context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		calls.Add(1)
		close(entered)
		select {
		case <-release:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
		return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: "complete"}}}, nil
	})
	finished := make(chan error, 1)
	go func() {
		result, err := databaseRuntimeCall(context.Background(), rt, nil)
		if err == nil && result.IsError {
			err = fmt.Errorf("%s", resultText(result))
		}
		finished <- err
	}()
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("first call did not enter backend")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	result, err := databaseRuntimeCall(ctx, rt, nil)
	cancel()
	close(release)
	if err != nil || !result.IsError {
		t.Fatalf("queued call did not cancel: %v", err)
	}
	if err := <-finished; err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 1 {
		t.Fatal("cancelled queued call reached backend")
	}
}

func TestDatabaseRuntimeInheritedCallStopsBeforeReturnAndStripsPrivateMeta(t *testing.T) {
	python, runtimeRoot, request := databaseAccessFixture(t)
	parent := acquireDatabaseFixture(t, python, runtimeRoot, request)
	seen := make(chan mcp.Meta, 1)
	rt, broker := newDatabaseRuntimeFixture(t, request, python, runtimeRoot, func(ctx context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		seen <- req.Params.Meta
		return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: "complete"}}}, nil
	})
	meta := mcp.Meta{databaseProofMetaKey: parent.Proof, "sentinel": "kept"}
	requireDatabaseRuntimeCall(t, rt, meta)
	if _, stops := broker.counts(); stops != 1 {
		t.Fatal("inherited backend outlived call return")
	}
	forwarded := <-seen
	if _, found := forwarded[databaseProofMetaKey]; found || forwarded["sentinel"] != "kept" {
		t.Fatal("private metadata was forwarded or ordinary metadata lost")
	}
	encoded, _ := json.Marshal(forwarded)
	if strings.Contains(string(encoded), parent.Proof.Token) {
		t.Fatal("private proof leaked to backend")
	}
	if err := parent.Validate(context.Background()); err != nil {
		t.Fatal("nested cleanup released parent", err)
	}
	releaseDatabaseFixture(t, parent, nil)
	result, err := databaseRuntimeCall(context.Background(), rt, meta)
	if err != nil || !result.IsError {
		t.Fatal("ended parent was accepted", err)
	}
	if ensures, _ := broker.counts(); ensures != 1 {
		t.Fatal("ended parent started another backend")
	}
}

func TestDatabaseRuntimeFailedStopKeepsReservationUntilConfirmedRetry(t *testing.T) {
	python, runtimeRoot, request := databaseAccessFixture(t)
	rt, broker := newDatabaseRuntimeFixture(t, request, python, runtimeRoot, nil)
	requireDatabaseRuntimeCall(t, rt, nil)
	broker.mu.Lock()
	broker.stopFailures = 1
	broker.mu.Unlock()
	if err := rt.stop(context.Background()); err == nil {
		t.Fatal("failed stop reported success")
	}
	other, err := acquireDatabasePipeOwner(context.Background(), python, runtimeRoot, request, nil)
	if other != nil {
		_ = other.Close()
	}
	if err == nil || !strings.Contains(err.Error(), "WAIT_TIMEOUT") {
		t.Fatal("failed stop released database", err)
	}
	if err := rt.stop(context.Background()); err != nil {
		t.Fatal(err)
	}
	owner := acquireDatabaseFixture(t, python, runtimeRoot, request)
	releaseDatabaseFixture(t, owner, nil)
}

func TestDatabaseRuntimeMissingStateDoesNotEraseNativeOwnership(t *testing.T) {
	python, runtimeRoot, request := databaseAccessFixture(t)
	rt, broker := newDatabaseRuntimeFixture(t, request, python, runtimeRoot, nil)
	requireDatabaseRuntimeCall(t, rt, nil)
	data, err := os.ReadFile(broker.statePath)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(broker.statePath); err != nil {
		t.Fatal(err)
	}
	result, err := databaseRuntimeCall(context.Background(), rt, nil)
	if err != nil || !result.IsError || rt.backend == nil || rt.databaseOwner == nil {
		t.Fatal("missing state erased pending native work", err)
	}
	if err := rt.stop(context.Background()); err == nil {
		t.Fatal("missing state was treated as quiescence")
	}
	// Restore only this simulated native boundary for fixture-owned cleanup.
	if err := os.WriteFile(broker.statePath, data, 0600); err != nil {
		t.Fatal(err)
	}
	if err := rt.stop(context.Background()); err != nil {
		t.Fatal(err)
	}
}

func TestDatabaseRuntimeInheritedStopFailurePreventsParentReleaseAndReplay(t *testing.T) {
	python, runtimeRoot, request := databaseAccessFixture(t)
	parent := acquireDatabaseFixture(t, python, runtimeRoot, request)
	rt, broker := newDatabaseRuntimeFixture(t, request, python, runtimeRoot, nil)
	broker.mu.Lock()
	broker.stopFailures = 1
	broker.mu.Unlock()
	meta := mcp.Meta{databaseProofMetaKey: parent.Proof}
	result, err := databaseRuntimeCall(context.Background(), rt, meta)
	if err != nil || result == nil || !result.IsError {
		t.Fatalf("inherited stop failure became a successful call: %v %s", err, resultText(result))
	}
	if got := releaseDatabaseFixture(t, parent, nil); got != "needs-attention" {
		t.Fatalf("parent freed unfinished inherited runtime: %s", got)
	}
	other, err := acquireDatabasePipeOwner(context.Background(), python, runtimeRoot, request, nil)
	if other != nil {
		_ = other.Close()
	}
	if err == nil || !strings.Contains(err.Error(), "RECOVERY_REQUIRED") {
		t.Fatalf("another task acquired unfinished runtime: %v", err)
	}
	beforeEnsure, beforeStop := broker.counts()
	result, err = databaseRuntimeCall(context.Background(), rt, meta)
	if err != nil || result == nil || !result.IsError {
		t.Fatalf("fenced parent replayed work: %v %s", err, resultText(result))
	}
	if ensures, stops := broker.counts(); ensures != beforeEnsure || stops != beforeStop {
		t.Fatal("fenced parent reached native runtime work")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := rt.close(ctx); err == nil {
		t.Fatal("terminal transport close erased the native cleanup failure")
	}
	if rt.session != nil || !rt.databaseNativePending || rt.backend == nil {
		t.Fatal("terminal close must close HTTP while retaining native recovery evidence")
	}
}

func TestDatabaseRuntimeInteractiveLifetimeRequiresAndRetainsOuterOwner(t *testing.T) {
	python, runtimeRoot, request := databaseAccessFixture(t)
	rt, broker := newDatabaseRuntimeFixture(t, request, python, runtimeRoot, nil)
	rt.databaseRetainInherited = true
	result, err := databaseRuntimeCall(context.Background(), rt, nil)
	if err != nil || !result.IsError || !strings.Contains(resultText(result), "PROFILE_OUTER_OWNERSHIP_REQUIRED") {
		t.Fatal("interactive lifetime accepted no outer owner", err)
	}
	parent := acquireDatabaseFixture(t, python, runtimeRoot, request)
	t.Setenv("ITL_INFOBASE_ACCESS_LEASE", string(mustJSON(t, parent.Proof)))
	requireDatabaseRuntimeCall(t, rt, nil)
	requireDatabaseRuntimeCall(t, rt, nil)
	if ensures, stops := broker.counts(); ensures != 1 || stops != 0 {
		t.Fatalf("interactive backend lifetime was broken: ensures=%d stops=%d", ensures, stops)
	}
	if err := rt.stop(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := parent.Validate(context.Background()); err != nil {
		t.Fatal(err)
	}
	releaseDatabaseFixture(t, parent, nil)
}

func mustJSON(t *testing.T, value any) []byte {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestDatabaseRuntimeRechecksCachedBackendTargetBeforeAnotherCall(t *testing.T) {
	python, runtimeRoot, request := databaseAccessFixture(t)
	var calls atomic.Int32
	rt, broker := newDatabaseRuntimeFixture(t, request, python, runtimeRoot, func(ctx context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		calls.Add(1)
		return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: "complete"}}}, nil
	})
	requireDatabaseRuntimeCall(t, rt, nil)
	changed := *broker.plan
	changed.TargetBase.Path += " новая"
	broker.plan = &changed
	result, err := databaseRuntimeCall(context.Background(), rt, nil)
	if err != nil || !result.IsError || !strings.Contains(resultText(result), "DATABASE_PLAN_CHANGED") {
		t.Fatal("cached backend ignored target drift", err)
	}
	if calls.Load() != 1 {
		t.Fatal("changed target reached cached backend")
	}
	if err := rt.stop(context.Background()); err != nil {
		t.Fatal("old owned backend could not stop after target drift", err)
	}
}
