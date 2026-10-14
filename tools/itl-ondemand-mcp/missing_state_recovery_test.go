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

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type missingStateBroker struct {
	*fakeBroker
	planner       *executionFixtureBroker
	recoveryError error
}

func (b *missingStateBroker) ExecutionPlan(ctx context.Context) (*facadeExecutionPlan, error) {
	return b.planner.ExecutionPlan(ctx)
}
func (b *missingStateBroker) ExecutionRuntimeRoot() string { return b.planner.runtimeRoot }
func (b *missingStateBroker) Recover(ctx context.Context, previous *backendInfo, next string) (*backendInfo, error) {
	invocation, ok := ctx.Value(executionInvocationKey{}).(*executionInvocation)
	if !ok || invocation.Context.Encoded == "" || previous == nil || len(previous.NativeLaunchProof) == 0 {
		return nil, fmt.Errorf("missing live owner or retained launch proof")
	}
	if b.recoveryError != nil {
		return nil, b.recoveryError
	}
	return b.fakeBroker.Recover(ctx, previous, next)
}

func TestMissingStateRecoversOriginalManageTestClientInTheSameExternalConnection(t *testing.T) {
	definitions := make([]*mcp.Tool, 0, len(vanessaIntegrationTools()))
	for _, tool := range vanessaIntegrationTools() {
		if tool.Name != "connect_test_client" {
			definitions = append(definitions, tool)
		}
	}
	definitions = append(definitions, &mcp.Tool{Name: "manage_test_client", InputSchema: map[string]any{
		"type": "object", "properties": map[string]any{"action": map[string]any{"type": "string"}, "profileName": map[string]any{"type": "string"}}, "required": []string{"action"}}})
	oldConnects, newConnects := 0, 0
	oldCalls, newCalls := map[string]int{}, map[string]int{}
	oldBackend := newVanessaBackendObservedWithTools(t, definitions, "VanessaExt: Истина", []string{"TestClient подключен"}, "Окно: Главное", &oldConnects, oldCalls)
	newBackend := newVanessaBackendObservedWithTools(t, definitions, "VanessaExt: Истина", []string{"TestClient подключен"}, "Окно: Главное", &newConnects, newCalls)
	fake := &fakeBroker{info: &backendInfo{InstanceID: "0123456789abcdef0123456789abcdef", URL: oldBackend.URL, PID: 7001, Port: 9874,
		TestClientProfile: "itl-ondemand", TestClientPort: 48151, NativeLaunchProof: json.RawMessage(`{"schemaVersion":4,"instanceId":"0123456789abcdef0123456789abcdef"}`)},
		recoverInfo: &backendInfo{URL: newBackend.URL, PID: 7003, Port: 9875, TestClientProfile: "itl-ondemand", TestClientPort: 48152}}
	rt, session := newFacadeSessionForFamily(t, "vanessa-ui", definitions, fake, time.Minute, nil)
	_, planner := newExecutionRuntimeFixture(t)
	planner.plan.ProjectRoot, planner.plan.Family = rt.projectRoot, rt.family
	broker := &missingStateBroker{fakeBroker: fake, planner: planner}
	rt.broker = broker
	initialID := rt.instanceID
	configureRecoveryMarkers(t, rt, fake, initialID)
	first, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "get_editor_state", Arguments: map[string]any{}})
	if err != nil || first.IsError {
		t.Fatalf("initial manager call failed: %v %v", first, err)
	}
	if err := os.Remove(filepath.Join(rt.projectRoot, ".agent-1c", "mcp", "ondemand", rt.family, initialID+".json")); err != nil {
		t.Fatal(err)
	}
	connected, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "manage_test_client", Arguments: map[string]any{"action": "connect", "profileName": "itl-ondemand"}})
	if err != nil || connected.IsError {
		t.Fatalf("same-connection original connect failed: %v %v", connected, err)
	}
	if oldConnects != 0 || newConnects != 1 || fake.recoveryCount() != 1 || rt.instanceID == initialID {
		t.Fatalf("unexpected replay/recovery: old=%d new=%d recoveries=%d id=%s", oldConnects, newConnects, fake.recoveryCount(), rt.instanceID)
	}
	following, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "get_window_list_testclient", Arguments: map[string]any{}})
	if err != nil || following.IsError || newCalls["get_window_list_testclient"] == 0 {
		t.Fatalf("replacement was not usable: %v %v", following, err)
	}
}

func TestMissingStatePreservesTheSessionAndDoesNotStartOrReplayWithoutQuiescence(t *testing.T) {
	for _, condition := range []string{"active-call", "unknown-native-result", "unproven-launch"} {
		t.Run(condition, func(t *testing.T) {
			tools := integrationTools()
			_, backend := newBackend(t, tools, false)
			fake := &fakeBroker{info: &backendInfo{InstanceID: "0123456789abcdef0123456789abcdef", URL: backend.URL, PID: 101, Port: 41001, NativeLaunchProof: json.RawMessage(`{"schemaVersion":4}`)}}
			rt, session := newFacadeSession(t, tools, fake, time.Minute, nil)
			_, planner := newExecutionRuntimeFixture(t)
			planner.plan.ProjectRoot = rt.projectRoot
			broker := &missingStateBroker{fakeBroker: fake, planner: planner}
			rt.broker = broker
			writeRuntimeMarker(t, rt, rt.instanceID)
			if result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "echo", Arguments: map[string]any{"value": "before"}}); err != nil || result.IsError {
				t.Fatalf("initial call: %v %v", result, err)
			}
			originalSession, originalID := rt.session, rt.instanceID
			if err := os.Remove(filepath.Join(rt.projectRoot, ".agent-1c", "mcp", "ondemand", rt.family, originalID+".json")); err != nil {
				t.Fatal(err)
			}
			switch condition {
			case "active-call":
				rt.active = 1
			case "unknown-native-result":
				_, finish, err := rt.beginDatabaseCall(context.Background(), nil)
				if err != nil {
					t.Fatal(err)
				}
				rt.cleanupUnconfirmed = true
				if err := finish("failed", "previous native outcome unconfirmed"); err == nil {
					t.Fatal("the unfinished original owner was released")
				}
			case "unproven-launch":
				broker.recoveryError = fmt.Errorf("ITL_ONDEMAND_RECOVERY_LAUNCH_PROOF_REQUIRED")
			}
			result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "second", Arguments: map[string]any{}})
			wanted := "ITL_ONDEMAND_RECOVERY_ACTION_REQUIRED"
			if condition == "unknown-native-result" {
				wanted = "EXECUTION_GUARD_ADMISSION_FAILED"
			}
			if err != nil || !result.IsError || !strings.Contains(resultText(result), wanted) {
				t.Fatalf("missing continuation: %v %v", result, err)
			}
			if fake.recoveryCount() != 0 || rt.session != originalSession || rt.instanceID != originalID {
				t.Fatal("unproven recovery replaced the original session")
			}
			details := result.StructuredContent.(map[string]any)["details"].(map[string]any)
			if details["automaticRetryPerformed"] != false {
				t.Fatal("unknown mutation was replayed")
			}
			if details["callOutcome"] != "not-started" {
				t.Fatal("a pre-dispatch refusal misrepresented the original call as having an unknown result")
			}
			rt.active = 0
		})
	}
}
