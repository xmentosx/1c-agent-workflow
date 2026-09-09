package main

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func TestPhaseBudgetAllowsLongOperationAndBrokerWithoutRestart(t *testing.T) {
	ctx, cancel, err := phaseRequestContext(context.Background(), mcp.Meta{"itlPhaseRemainingMs": 1800000})
	if err != nil {
		t.Fatal(err)
	}
	defer cancel()
	deadline, _ := ctx.Deadline()
	if left := time.Until(deadline); left < 29*time.Minute || left > 30*time.Minute {
		t.Fatalf("long calculation was capped: %s", left)
	}
	first := brokerCallTimeout(ctx, 0)
	time.Sleep(2 * time.Millisecond)
	second := brokerCallTimeout(ctx, 0)
	if second >= first || second < 29*time.Minute {
		t.Fatalf("broker restarted or truncated phase: %s -> %s", first, second)
	}
	if got := brokerCallTimeout(context.Background(), 0); got != 5*time.Minute {
		t.Fatalf("default broker timeout changed: %s", got)
	}
}

func TestPhaseBudgetCannotExtendParentAndRejectsInvalidMetadata(t *testing.T) {
	parent, stop := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer stop()
	ctx, cancel, err := phaseRequestContext(parent, mcp.Meta{"itlPhaseRemainingMs": 1800000})
	if err != nil {
		t.Fatal(err)
	}
	defer cancel()
	select {
	case <-ctx.Done():
	case <-time.After(time.Second):
		t.Fatal("phase extended its parent")
	}
	for _, value := range []any{0, -1, true, "1800000", 86400001, map[string]any{}} {
		_, cancel, err := phaseRequestContext(context.Background(), mcp.Meta{"itlPhaseRemainingMs": value})
		if cancel != nil {
			cancel()
		}
		if err == nil {
			t.Fatalf("accepted invalid phase budget: %#v", value)
		}
	}
}

func TestRuntimePhaseDeadlineBoundsHTTPCallAndDoesNotReplay(t *testing.T) {
	tools := integrationTools()
	var calls atomic.Int32
	_, backend := newBackendWithObserver(t, tools, false, func(string) {
		calls.Add(1)
		time.Sleep(200 * time.Millisecond)
	})
	broker := &fakeBroker{info: &backendInfo{URL: backend.URL, BackendVersion: "test"}}
	rt, session := newFacadeSession(t, tools, broker, time.Minute, nil)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	// Isolate the action deadline from catalog initialization on loaded hosts.
	rt.mu.Lock()
	ensureErr := rt.ensureLocked(ctx)
	rt.mu.Unlock()
	if ensureErr != nil {
		t.Fatal(ensureErr)
	}
	result, err := session.CallTool(ctx, &mcp.CallToolParams{Name: "echo", Arguments: map[string]any{"value": "x"}, Meta: mcp.Meta{"itlPhaseRemainingMs": 100}})
	if err != nil || result == nil || !result.IsError {
		t.Fatalf("deadline did not fail the request: %#v, %v", result, err)
	}
	time.Sleep(250 * time.Millisecond)
	if calls.Load() != 1 {
		t.Fatalf("timed out call was replayed or never dispatched: %d", calls.Load())
	}
}
