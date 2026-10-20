package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/jsonrpc"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type ownerRecoveryFixture struct {
	*fakeBroker
	planner    *executionFixtureBroker
	idleError  error
	stopOwners []string
}

func (b *ownerRecoveryFixture) ExecutionPlan(ctx context.Context) (*facadeExecutionPlan, error) {
	return b.planner.ExecutionPlan(ctx)
}
func (b *ownerRecoveryFixture) ExecutionRuntimeRoot() string                      { return b.planner.runtimeRoot }
func (b *ownerRecoveryFixture) PrivateRuntime() bool                              { return true }
func (b *ownerRecoveryFixture) StopOwnedIdle(context.Context, *backendInfo) error { return b.idleError }
func (b *ownerRecoveryFixture) Stop(ctx context.Context) error {
	invocation, ok := ctx.Value(executionInvocationKey{}).(*executionInvocation)
	if !ok || invocation.Context.ID == "" {
		return fmt.Errorf("stop lost its signed owner")
	}
	b.stopOwners = append(b.stopOwners, invocation.Context.ID)
	return b.fakeBroker.Stop(ctx)
}

func recoveryReadName(family string) string {
	if family == "vanessa-ui" {
		return "search_for_steps_by_keywords"
	}
	return "get_metadata"
}

func recoveryMutationName(family string) string {
	if family == "vanessa-ui" {
		return "manage_variables"
	}
	return "execute_code"
}

func newOwnerRecoveryFixture(t *testing.T, family string, invoke func(string) (*mcp.CallToolResult, error)) (*runtime, *mcp.ClientSession, *ownerRecoveryFixture) {
	t.Helper()
	tools := []*mcp.Tool{
		{Name: recoveryReadName(family), Description: "safe read", InputSchema: map[string]any{"type": "object"}, Annotations: &mcp.ToolAnnotations{ReadOnlyHint: true}},
		{Name: recoveryMutationName(family), InputSchema: map[string]any{"type": "object"}},
	}
	if family == "vanessa-ui" {
		tools = append(tools, &mcp.Tool{Name: "get_environment_data", InputSchema: map[string]any{"type": "object"}})
	}
	server := mcp.NewServer(&mcp.Implementation{Name: "owned-recovery-backend", Version: "1"}, nil)
	for _, definition := range tools {
		tool := definition
		server.AddTool(tool, func(context.Context, *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			if tool.Name == "get_environment_data" {
				return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: "VanessaExt: Истина"}}}, nil
			}
			return invoke(tool.Name)
		})
	}
	backend := httptest.NewServer(mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server { return server }, nil))
	t.Cleanup(backend.Close)
	fake := &fakeBroker{info: &backendInfo{InstanceID: "0123456789abcdef0123456789abcdef", URL: backend.URL, PID: 101, Port: 41001, NativeLaunchProof: json.RawMessage(`{"schemaVersion":4}`)}}
	rt, session := newGatewayFacadeSession(t, family, tools, fake, nil)
	_, planner := newExecutionRuntimeFixture(t)
	planner.plan.ProjectRoot, planner.plan.Family = rt.projectRoot, family
	broker := &ownerRecoveryFixture{fakeBroker: fake, planner: planner}
	rt.broker = broker
	writeRuntimeMarker(t, rt, rt.instanceID)
	return rt, session, broker
}

func recoveryGatewayCall(t *testing.T, session *mcp.ClientSession, name string) *mcp.CallToolResult {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	result, err := session.CallTool(ctx, &mcp.CallToolParams{Name: gatewayCallTool, Arguments: map[string]any{"name": name, "arguments": map[string]any{}}})
	if err != nil {
		t.Fatal(err)
	}
	return result
}

func TestOwnerRecoveryDrainsIdleDebtBeforeDispatchForBothFamilies(t *testing.T) {
	for _, family := range []string{"roctup", "vanessa-ui"} {
		t.Run(family, func(t *testing.T) {
			reads := 0
			rt, session, broker := newOwnerRecoveryFixture(t, family, func(string) (*mcp.CallToolResult, error) {
				reads++
				return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: "safe search result"}}}, nil
			})
			if result := recoveryGatewayCall(t, session, recoveryReadName(family)); result.IsError {
				t.Fatal(resultText(result))
			}
			broker.idleError = errors.New("native idle cleanup unconfirmed")
			rt.idleDeadline = time.Now().Add(-time.Second)
			if err := rt.stopIdle(context.Background(), rt.generation); err == nil {
				t.Fatal("fixture did not reproduce idle cleanup debt")
			}
			if !rt.cleanupUnconfirmed || rt.executionOwner != nil {
				t.Fatal("fixture did not retain debt without a database owner")
			}
			if result := recoveryGatewayCall(t, session, recoveryReadName(family)); result.IsError || resultText(result) != "safe search result" {
				t.Fatalf("original safe call did not resume: %v", result)
			}
			if reads != 2 || len(broker.stopOwners) != 1 || rt.cleanupUnconfirmed || rt.executionOwner != nil {
				t.Fatalf("debt leaked into new execution or read replayed: reads=%d stops=%v", reads, broker.stopOwners)
			}
		})
	}
}

func TestOwnerRecoveryLifecycleDrainBeforeIdleThenOriginalSearch(t *testing.T) {
	for _, family := range []string{"roctup", "vanessa-ui"} {
		t.Run(family, func(t *testing.T) {
			reads := 0
			rt, session, broker := newOwnerRecoveryFixture(t, family, func(string) (*mcp.CallToolResult, error) {
				reads++
				return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: "original search result"}}}, nil
			})
			if result := recoveryGatewayCall(t, session, recoveryReadName(family)); result.IsError {
				t.Fatal(resultText(result))
			}
			// The lifecycle owner has stopped its native runtime and removed the
			// registration. The old facade and its armed timer remain connected.
			path := filepath.Join(rt.projectRoot, ".agent-1c", "mcp", "ondemand", family, rt.instanceID+".json")
			if err := os.Remove(path); err != nil {
				t.Fatal(err)
			}
			broker.idleError = errIdleChildActive // guarded continuation selected by StopOwnedIdle
			rt.idleDeadline = time.Now().Add(-time.Second)
			if err := rt.stopIdle(context.Background(), rt.generation); err != nil {
				t.Fatal(err)
			}
			if rt.cleanupUnconfirmed || rt.executionOwner != nil || rt.backend != nil {
				t.Fatal("normal lifecycle drain became cleanup debt")
			}
			if result := recoveryGatewayCall(t, session, recoveryReadName(family)); result.IsError || resultText(result) != "original search result" {
				t.Fatal("original search did not restart through the same facade")
			}
			if reads != 2 || len(broker.stopOwners) != 1 || rt.executionOwner != nil {
				t.Fatal("search replayed or signed cleanup retained a guard")
			}
		})
	}
}

func TestOwnerRecoveryGatewayResumesRetainedOwnerWithoutReplayingMutation(t *testing.T) {
	for _, family := range []string{"roctup", "vanessa-ui"} {
		t.Run(family, func(t *testing.T) {
			mutations := 0
			rt, session, broker := newOwnerRecoveryFixture(t, family, func(name string) (*mcp.CallToolResult, error) {
				if name == recoveryMutationName(family) {
					mutations++
					return nil, &jsonrpc.Error{Code: -32603, Message: "native modification may have completed"}
				}
				return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: "read"}}}, nil
			})
			broker.stopFailures = 1
			result := recoveryGatewayCall(t, session, recoveryMutationName(family))
			if !result.IsError || rt.executionOwner == nil || !rt.cleanupUnconfirmed || mutations != 1 {
				t.Fatalf("unknown mutation was not retained: %v", result)
			}
			owner := rt.executionOwner.Proof.ID
			broker.stopFailures = 1
			failed := recoveryGatewayCall(t, session, ownerRecoveryTool)
			if !failed.IsError || rt.executionOwner == nil || rt.executionOwner.Proof.ID != owner || mutations != 1 {
				t.Fatal("failed recovery released ownership or replayed mutation")
			}
			result = recoveryGatewayCall(t, session, ownerRecoveryTool)
			if result.IsError || rt.executionOwner != nil || rt.cleanupUnconfirmed || rt.session == nil || mutations != 1 {
				t.Fatalf("agent-owned recovery did not restore connection: %v", result)
			}
			for _, id := range broker.stopOwners {
				if id != owner {
					t.Fatalf("cleanup reacquired or expanded original owner: %s != %s", id, owner)
				}
			}
			if result := recoveryGatewayCall(t, session, recoveryReadName(family)); result.IsError {
				t.Fatal(resultText(result))
			}
			if result := recoveryGatewayCall(t, session, ownerRecoveryTool); result.IsError || mutations != 1 {
				t.Fatal("repeated recovery failed or replayed previous mutation")
			}
		})
	}
}

func TestOwnerRecoveryPreservesSuccessAndFinalizationEvidence(t *testing.T) {
	var rt *runtime
	var broker *ownerRecoveryFixture
	rt, session, broker := newOwnerRecoveryFixture(t, "roctup", func(string) (*mcp.CallToolResult, error) {
		// Native cleanup fails after the backend has produced a successful result.
		rt.mu.Lock()
		ctx := withExecutionInvocation(context.Background(), rt.executionOwner.Proof, rt.executionPlan)
		_ = rt.cleanupFailedDatabaseCallLocked(ctx, errors.New("late native failure"))
		rt.mu.Unlock()
		return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: "retained successful result"}}, StructuredContent: map[string]any{"answer": 42}}, nil
	})
	broker.stopFailures = 1
	result := recoveryGatewayCall(t, session, recoveryReadName("roctup"))
	if !result.IsError || !strings.Contains(resultText(result), "retained successful result") {
		t.Fatal("cleanup erased upstream result")
	}
	structured := result.StructuredContent.(map[string]any)
	if structured["upstreamResult"].(map[string]any)["answer"] != float64(42) {
		t.Fatalf("structured upstream result lost: %#v", structured)
	}
	path := filepath.Join(rt.projectRoot, ".agent-1c", "mcp", "ondemand", rt.family, rt.instanceID+".evidence.jsonl")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), `"outcome":"cleanup-failed"`) || strings.Contains(string(raw), "retained successful result") {
		t.Fatal("finalization failure missing or successful payload persisted")
	}
}

func TestIdleMissingRegistrationContinuesThroughGuardedStop(t *testing.T) {
	body := `throw 'ITL_ONDEMAND_STOP_UNCONFIRMED: original registration is missing or has a retained claim; continue through its cleanup owner.'`
	broker := &powershellBroker{privateRuntime: true, HelperPath: writeBrokerFixture(t, body), ProjectRoot: t.TempDir(), Family: "vanessa-ui", InstanceID: strings.Repeat("a", 32)}
	if err := broker.StopOwnedIdle(context.Background(), &backendInfo{PID: 101}); !errors.Is(err, errIdleChildActive) {
		t.Fatalf("missing state did not select signed cleanup continuation: %v", err)
	}
}

func TestOwnerRecoveryDiscoveryIsStaticAndArgumentsCannotExpandAuthority(t *testing.T) {
	for _, family := range []string{"roctup", "vanessa-ui"} {
		t.Run(family, func(t *testing.T) {
			broker := &fakeBroker{info: &backendInfo{}}
			_, session := newGatewayFacadeSession(t, family, integrationTools(), broker, nil)
			result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: gatewayResolveTool, Arguments: map[string]any{"query": ownerRecoveryTool, "limit": 1}})
			if err != nil || !strings.Contains(resultText(result), ownerRecoveryTool) {
				t.Fatalf("recovery not discoverable: %v %v", result, err)
			}
			result, err = session.CallTool(context.Background(), &mcp.CallToolParams{Name: gatewayCallTool, Arguments: map[string]any{"name": ownerRecoveryTool, "arguments": map[string]any{"pid": 999}}})
			if err != nil || !result.IsError {
				t.Fatal("recovery accepted foreign target selector")
			}
			if ensures, stops := broker.counts(); ensures != 0 || stops != 0 {
				t.Fatal("discovery or invalid recovery started native work")
			}
		})
	}
}

func TestOwnerRecoveryDoesNotAcquireOrReleaseForeignGuard(t *testing.T) {
	for _, family := range []string{"roctup", "vanessa-ui"} {
		t.Run(family, func(t *testing.T) {
			_, session, broker := newOwnerRecoveryFixture(t, family, func(string) (*mcp.CallToolResult, error) {
				t.Error("foreign guard admitted an upstream call")
				return nil, nil
			})
			plan := broker.planner.plan
			foreign, err := acquireExecutionGuard(context.Background(), plan.Python, broker.planner.runtimeRoot,
				executionGuardRequest{SchemaVersion: 1, Root: plan.GuardRoot, Bases: plan.Bases,
					Operation: "foreign-writer", ExecutionID: strings.Repeat("f", 32), Timeout: 2}, nil)
			if err != nil {
				t.Fatal(err)
			}
			defer foreign.Close()
			result := recoveryGatewayCall(t, session, ownerRecoveryTool)
			details := result.StructuredContent.(map[string]any)["details"].(map[string]any)
			if !result.IsError || !strings.Contains(fmt.Sprint(details["reason"]), "EXECUTION_GUARD_WAIT_TIMEOUT") {
				t.Fatalf("foreign admission was bypassed: %v", result)
			}
			if ensures, stops := broker.counts(); ensures != 0 || stops != 0 {
				t.Fatal("foreign owner caused native mutation")
			}
			if err := foreign.Release(context.Background(), "succeeded", ""); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestOwnerRecoveryCancellationPreservesOriginalExecution(t *testing.T) {
	rt, _, broker := newOwnerRecoveryFixture(t, "roctup", func(string) (*mcp.CallToolResult, error) { return nil, nil })
	_, finish, err := rt.beginDatabaseCall(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	rt.cleanupUnconfirmed = true
	if err := finish("failed", "unknown original outcome"); err == nil {
		t.Fatal("fixture released original execution")
	}
	owner := rt.executionOwner
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	result := rt.recoverConnection(ctx, nil, map[string]any{})
	if !result.IsError || rt.executionOwner != owner || !rt.cleanupUnconfirmed {
		t.Fatal("cancelled recovery lost original owner")
	}
	if ensures, stops := broker.counts(); ensures != 0 || stops != 0 {
		t.Fatal("cancelled recovery dispatched native work")
	}
}
