package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func TestWaitForStateCountRetriesTransientStateReadFailure(t *testing.T) {
	calls := 0
	states, err := waitForStateCountWithReader("runtime", 0, time.Second, func(string) ([]runtimeState, error) {
		calls++
		if calls == 1 {
			return nil, errors.New("sharing violation")
		}
		return []runtimeState{}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if calls != 2 || len(states) != 0 {
		t.Fatalf("calls=%d states=%#v", calls, states)
	}
}

func TestFirstOSWindowTitleUsesVanessaListResult(t *testing.T) {
	result := &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: "Для снятия скриншотов найдено 1 окон:\n  -dev_test / 1С:Предприятие"}}}
	if got := firstOSWindowTitle(result); got != "dev_test / 1С:Предприятие" {
		t.Fatalf("title=%q", got)
	}
}

func newProbeGatewaySession(t *testing.T, handler func(string, map[string]any) *mcp.CallToolResult) *mcp.ClientSession {
	t.Helper()
	server := mcp.NewServer(&mcp.Implementation{Name: "fake-gateway", Version: "1"}, nil)
	server.AddTool(&mcp.Tool{
		Name: gatewayCallTool,
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"name":          map[string]any{"type": "string"},
				"arguments":     map[string]any{"type": "object", "additionalProperties": true},
				"argumentsJson": map[string]any{"type": "string"},
			},
			"required": []string{"name"},
		},
	}, func(_ context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		var call struct {
			Name          string         `json:"name"`
			Arguments     map[string]any `json:"arguments"`
			ArgumentsJSON string         `json:"argumentsJson"`
		}
		if err := json.Unmarshal(req.Params.Arguments, &call); err != nil {
			t.Fatalf("decode gateway call: %v", err)
		}
		if call.ArgumentsJSON != "" {
			if call.Arguments != nil {
				t.Fatal("probe sent both arguments forms")
			}
			if err := json.Unmarshal([]byte(call.ArgumentsJSON), &call.Arguments); err != nil {
				t.Fatalf("decode probe argumentsJson: %v", err)
			}
		}
		return handler(call.Name, call.Arguments), nil
	})
	client := mcp.NewClient(&mcp.Implementation{Name: "probe-test", Version: "1"}, nil)
	left, right := mcp.NewInMemoryTransports()
	serverSession, err := server.Connect(context.Background(), left, nil)
	if err != nil {
		t.Fatal(err)
	}
	clientSession, err := client.Connect(context.Background(), right, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = clientSession.Close()
		_ = serverSession.Close()
	})
	return clientSession
}

func successfulProbeResult(name string) *mcp.CallToolResult {
	text := name
	if name == "get_window_list_os" {
		text = "Для снятия скриншотов найдено 1 окон:\n  -PM5 / 1С:Предприятие"
	}
	return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: text}}}
}

func TestRunVanessaSmokeCoversColdHotAndSelectedScenarioPathsBeforeUI(t *testing.T) {
	type recordedCall struct {
		name      string
		arguments map[string]any
	}
	var calls []recordedCall
	session := newProbeGatewaySession(t, func(name string, arguments map[string]any) *mcp.CallToolResult {
		calls = append(calls, recordedCall{name: name, arguments: arguments})
		return successfulProbeResult(name)
	})

	featurePath := `D:\Git\PM5 КОРП - work 1-perf1\tests\features\Проверка пути.feature`
	secondaryFeaturePath := `D:\Git\PM5 КОРП - work 1-perf1\tests\features\Проверка второго пути.feature`
	clientCount := 0
	maxClientCount := 0
	outcome, authoringCalls, err := runVanessaSmoke(context.Background(), session, 48151, featurePath, secondaryFeaturePath, func(delta int) {
		clientCount += delta
		if clientCount > maxClientCount {
			maxClientCount = clientCount
		}
	})
	if err != nil {
		t.Fatal(err)
	}
	if clientCount != 0 || maxClientCount != 1 {
		t.Fatalf("unexpected TestClient concurrency observation: current=%d max=%d", clientCount, maxClientCount)
	}
	wantProofs := "run_scenario:cold,get_VanessaAutomation_state:cold,get_test_results:cold,run_scenario:hot,get_VanessaAutomation_state:hot,get_test_results:hot,run_scenario:switch,get_VanessaAutomation_state:switch,get_test_results:switch,open_feature_file:secondary,check_syntax:secondary,load_features:secondary,select_scenario:secondary,run_scenario:selected,get_VanessaAutomation_state:selected,get_test_results:selected"
	if outcome != "passed" || strings.Join(authoringCalls, ",") != wantProofs {
		t.Fatalf("outcome=%q authoringCalls=%#v", outcome, authoringCalls)
	}
	if len(calls) < 21 {
		t.Fatalf("calls=%#v", calls)
	}
	want := []struct {
		name  string
		key   string
		value any
	}{
		{name: "run_scenario", key: "filePath", value: featurePath},
		{name: "get_VanessaAutomation_state"},
		{name: "get_test_results"},
		{name: "run_scenario", key: "filePath", value: featurePath},
		{name: "get_VanessaAutomation_state"},
		{name: "get_test_results"},
		{name: "run_scenario", key: "filePath", value: secondaryFeaturePath},
		{name: "get_VanessaAutomation_state"},
		{name: "get_test_results"},
		{name: "open_feature_file", key: "filePath", value: secondaryFeaturePath},
		{name: "check_syntax", key: "filePath", value: secondaryFeaturePath},
		{name: "load_features", key: "path", value: secondaryFeaturePath},
		{name: "select_scenario", key: "name", value: "MCP cold B"},
		{name: "run_scenario", key: "mode", value: "selected"},
		{name: "get_VanessaAutomation_state"},
		{name: "get_test_results"},
	}
	for index, expected := range want {
		call := calls[index]
		if call.name != expected.name {
			t.Fatalf("call %d changed scenario smoke order: %#v", index, call)
		}
		if expected.key != "" && call.arguments[expected.key] != expected.value {
			t.Fatalf("call %d changed scenario smoke arguments: %#v", index, call)
		}
	}
	if calls[0].name != "run_scenario" || calls[0].arguments["mode"] != "reloadAndRun" {
		t.Fatalf("cold run_scenario was not the first feature operation: %#v", calls[0])
	}
	for index := 0; index < len(want); index++ {
		if calls[index].name == "connect_test_client" || strings.HasPrefix(calls[index].name, "get_window_") {
			t.Fatalf("UI call ran before scenario probes completed: %#v", calls[index])
		}
	}
	if calls[len(calls)-1].name != "close_test_client" {
		t.Fatalf("Vanessa smoke did not release its TestClient before the next facade: %#v", calls)
	}
}

func TestValidateVanessaScenarioEvidenceBindsPassedRunsAndResultsToFeatureSHA(t *testing.T) {
	projectRoot := t.TempDir()
	featureRoot := filepath.Join(projectRoot, "tests", "features")
	if err := os.MkdirAll(featureRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	primary := filepath.Join(featureRoot, "cold-a.feature")
	secondary := filepath.Join(featureRoot, "cold-b.feature")
	if err := os.WriteFile(primary, []byte("Feature: A\nScenario: A\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(secondary, []byte("Feature: B\nScenario: B\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	instanceID := "0123456789abcdef0123456789abcdef"
	evidenceRoot := filepath.Join(projectRoot, ".agent-1c", "mcp", "ondemand", "vanessa-ui")
	if err := os.MkdirAll(evidenceRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	paths := []string{primary, primary, primary, primary, secondary, secondary, secondary, secondary}
	tools := []string{"run_scenario", "get_test_results", "run_scenario", "get_test_results", "run_scenario", "get_test_results", "run_scenario", "get_test_results"}
	var lines []string
	for index, path := range paths {
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		hash := sha256.Sum256(raw)
		relative, err := filepath.Rel(projectRoot, path)
		if err != nil {
			t.Fatal(err)
		}
		entry, err := json.Marshal(vanessaScenarioEvidence{Tool: tools[index], Outcome: "passed", ResultCode: "ITL_OK", FeaturePath: filepath.ToSlash(relative), FeatureSHA256: fmt.Sprintf("%x", hash[:])})
		if err != nil {
			t.Fatal(err)
		}
		lines = append(lines, string(entry))
	}
	if err := os.WriteFile(filepath.Join(evidenceRoot, instanceID+".evidence.jsonl"), []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := validateVanessaScenarioEvidence(projectRoot, instanceID, primary, secondary); err != nil {
		t.Fatal(err)
	}
}

func TestRunVanessaSmokeRequiresManagedTestClientClose(t *testing.T) {
	session := newProbeGatewaySession(t, func(name string, _ map[string]any) *mcp.CallToolResult {
		if name == "close_test_client" {
			return &mcp.CallToolResult{IsError: true, StructuredContent: map[string]any{"code": "ITL_VANESSA_TESTCLIENT_STOP_FAILED"}}
		}
		return successfulProbeResult(name)
	})

	outcome, calls, err := runVanessaSmoke(context.Background(), session, 48151, `D:\Git\PM5 КОРП - work 1-perf1\tests\features\Проверка пути.feature`, `D:\Git\PM5 КОРП - work 1-perf1\tests\features\Проверка второго пути.feature`, nil)
	if err == nil || !strings.Contains(err.Error(), "close_test_client returned a tool error") {
		t.Fatalf("unexpected error: %v", err)
	}
	if outcome != "" || calls != nil {
		t.Fatalf("outcome=%q calls=%#v", outcome, calls)
	}
}

func TestRunVanessaSmokeRejectsFileAuthoringBackendFailure(t *testing.T) {
	session := newProbeGatewaySession(t, func(name string, _ map[string]any) *mcp.CallToolResult {
		if name == "open_feature_file" {
			return &mcp.CallToolResult{
				IsError:           true,
				StructuredContent: map[string]any{"code": "ITL_ONDEMAND_BACKEND_CALL_FAILED"},
			}
		}
		return successfulProbeResult(name)
	})

	outcome, calls, err := runVanessaSmoke(context.Background(), session, 48151, `D:\Git\PM5 КОРП\tests\features\Проверка пути.feature`, `D:\Git\PM5 КОРП\tests\features\Проверка второго пути.feature`, nil)
	if err == nil || !strings.Contains(err.Error(), "open_feature_file returned a tool error") {
		t.Fatalf("unexpected error: %v", err)
	}
	if outcome != "" || calls != nil {
		t.Fatalf("outcome=%q calls=%#v", outcome, calls)
	}
}
