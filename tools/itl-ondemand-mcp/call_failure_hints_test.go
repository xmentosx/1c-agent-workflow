package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/jsonrpc"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// A hung backend call reproduces PM5 06.11.2026: Vanessa reported every step
// start within a second, then never answered until the request phase expired.
func newHangingBackend(t *testing.T, tools []*mcp.Tool, progress []*mcp.ProgressNotificationParams) *httptest.Server {
	t.Helper()
	server := mcp.NewServer(&mcp.Implementation{Name: "hanging-backend", Version: "1"}, nil)
	for _, definition := range tools {
		tool := definition
		server.AddTool(tool, func(ctx context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			if token := req.Params.GetProgressToken(); token != nil {
				for _, item := range progress {
					notification := *item
					notification.ProgressToken = token
					_ = req.Session.NotifyProgress(ctx, &notification)
				}
			}
			select {
			case <-ctx.Done():
			case <-time.After(3 * time.Second):
			}
			return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: tool.Name}}}, nil
		})
	}
	backend := httptest.NewServer(mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server { return server }, nil))
	t.Cleanup(backend.Close)
	return backend
}

func callAfterReadyBackend(t *testing.T, rt *runtime, session *mcp.ClientSession, params *mcp.CallToolParams) *mcp.CallToolResult {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	// Isolate the action deadline from catalog initialization on loaded hosts.
	rt.mu.Lock()
	ensureErr := rt.ensureLocked(ctx)
	rt.mu.Unlock()
	if ensureErr != nil {
		t.Fatal(ensureErr)
	}
	result, err := session.CallTool(ctx, params)
	if err != nil || result == nil || !result.IsError {
		t.Fatalf("expected a tool error, got %#v, %v", result, err)
	}
	return result
}

func failureDetails(t *testing.T, result *mcp.CallToolResult) map[string]any {
	t.Helper()
	structured, _ := result.StructuredContent.(map[string]any)
	details, _ := structured["details"].(map[string]any)
	if details == nil {
		t.Fatalf("failure has no details: %#v", result.StructuredContent)
	}
	return details
}

func TestPhaseDeadlineOfMutatingCallReportsLastProgressAndUnknownOutcome(t *testing.T) {
	tools := []*mcp.Tool{{Name: "apply_scenario", InputSchema: map[string]any{"type": "object"}}}
	backend := newHangingBackend(t, tools, []*mcp.ProgressNotificationParams{
		{Progress: 1, Total: 3, Message: "Выполнение шага сценария."},
		{Progress: 2, Total: 3, Message: "Шаг: я создаю семью 'Б' в каталоге с пробелом"},
	})
	broker := &fakeBroker{info: &backendInfo{URL: backend.URL, BackendVersion: "test"}}
	rt, session := newFacadeSession(t, tools, broker, time.Minute, make(chan *mcp.ProgressNotificationParams, 8))
	result := callAfterReadyBackend(t, rt, session, &mcp.CallToolParams{Name: "apply_scenario", Arguments: map[string]any{},
		Meta: mcp.Meta{"itlPhaseRemainingMs": 400, "progressToken": "caller-token"}})

	assertToolErrorCode(t, result, "ITL_ONDEMAND_BACKEND_CALL_FAILED")
	details := failureDetails(t, result)
	if details["callOutcome"] != "unknown" || details["partialEffectsPossible"] != true || details["backendResultsRetained"] != false ||
		details["action"] != "probe-state-read-only-before-retry" || details["automaticRetryPerformed"] != false {
		t.Fatalf("unknown mutating outcome was not explicit: %#v", details)
	}
	last, _ := details["lastProgress"].(map[string]any)
	if last == nil || last["progress"] != float64(2) || last["total"] != float64(3) || last["message"] != "Шаг: я создаю семью 'Б' в каталоге с пробелом" {
		t.Fatalf("last received progress was not reported: %#v", details)
	}
	if details["progressNotificationsReceived"] != float64(2) {
		t.Fatalf("received progress count is wrong: %#v", details)
	}
	text := resultText(result)
	for _, fragment := range []string{"context deadline exceeded", "outcome unknown", "step 2/3 (Шаг: я создаю семью 'Б' в каталоге с пробелом)", "partially", "read-only before any retry", "get_test_results"} {
		if !strings.Contains(text, fragment) {
			t.Fatalf("timeout text lacks %q: %s", fragment, text)
		}
	}
	if _, stops := broker.counts(); stops != 1 {
		t.Fatalf("timed out backend was not stopped exactly once: stops=%d", stops)
	}
}

func TestPhaseDeadlineOfReadOnlyCallWithoutProgressTokenSaysSo(t *testing.T) {
	tools := []*mcp.Tool{{Name: "read_state", InputSchema: map[string]any{"type": "object"}, Annotations: &mcp.ToolAnnotations{ReadOnlyHint: true}}}
	backend := newHangingBackend(t, tools, nil)
	broker := &fakeBroker{info: &backendInfo{URL: backend.URL, BackendVersion: "test"}}
	rt, session := newFacadeSession(t, tools, broker, time.Minute, nil)
	result := callAfterReadyBackend(t, rt, session, &mcp.CallToolParams{Name: "read_state", Arguments: map[string]any{},
		Meta: mcp.Meta{"itlPhaseRemainingMs": 200}})

	assertToolErrorCode(t, result, "ITL_ONDEMAND_BACKEND_CALL_FAILED")
	details := failureDetails(t, result)
	if details["callOutcome"] != "unknown" || details["partialEffectsPossible"] != false || details["action"] != "retry-tool-call" ||
		details["progressTokenProvided"] != false || details["lastProgress"] != nil {
		t.Fatalf("read-only deadline details are wrong: %#v", details)
	}
	if text := resultText(result); !strings.Contains(text, "no progress was requested") || strings.Contains(text, "partially") {
		t.Fatalf("read-only deadline text is wrong: %s", text)
	}
}

func TestVanessaDisconnectedTestClientProtocolErrorNamesRecoveryTool(t *testing.T) {
	const disconnected = "ACTION_FAILED: Клиент тестирования не подключен."
	tools := vanessaIntegrationTools()
	server := mcp.NewServer(&mcp.Implementation{Name: "disconnected-backend", Version: "1"}, nil)
	calls := 0
	for _, definition := range tools {
		tool := definition
		server.AddTool(tool, func(context.Context, *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			text := tool.Name
			switch tool.Name {
			case "run_scenario":
				calls++
				return nil, &jsonrpc.Error{Code: -32603, Message: disconnected}
			case "get_environment_data":
				text = "VanessaExt: true"
			case "connect_test_client":
				text = "TestClient подключен"
			case "get_window_list_testclient":
				text = "Окно: Главное"
			}
			return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: text}}}, nil
		})
	}
	backend := httptest.NewServer(mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server { return server }, nil))
	t.Cleanup(backend.Close)
	broker := &fakeBroker{info: &backendInfo{URL: backend.URL, BackendVersion: "test"}}
	_, session := newGatewayFacadeSession(t, "vanessa-ui", tools, broker, nil)

	result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: gatewayCallTool, Arguments: map[string]any{"name": "run_scenario", "arguments": map[string]any{}}})
	if err != nil || result == nil || !result.IsError {
		t.Fatalf("expected a tool error, got %#v, %v", result, err)
	}
	assertToolErrorCode(t, result, "ITL_VANESSA_TESTCLIENT_NOT_CONNECTED")
	details := failureDetails(t, result)
	if details["action"] != ownerRecoveryTool || details["recoveryTool"] != ownerRecoveryTool || details["automaticRetryPerformed"] != false ||
		!strings.Contains(details["cause"].(string), disconnected) {
		t.Fatalf("recovery hint is missing: %#v", details)
	}
	if text := resultText(result); !strings.Contains(text, ownerRecoveryTool) {
		t.Fatalf("text does not name the recovery tool: %s", text)
	}
	if calls != 1 {
		t.Fatalf("disconnected call was replayed or recovered automatically: calls=%d", calls)
	}
}

func TestTestClientDisconnectMarkersIgnoreGenericTransportText(t *testing.T) {
	for _, message := range []string{"no connection to backend", "нет соединения", "ACTION_FAILED: Недоступный пользователю элемент управления не может выполнять интерактивные действия."} {
		if protocolErrorReportsTestClientDisconnected(errors.New(message)) {
			t.Fatalf("generic text was classified as a disconnected TestClient: %q", message)
		}
	}
	for _, message := range []string{"calling \"tools/call\": ACTION_FAILED: Клиент тестирования не подключен.", "TestClient is not connected"} {
		if !protocolErrorReportsTestClientDisconnected(errors.New(message)) {
			t.Fatalf("disconnected TestClient text was not recognized: %q", message)
		}
	}
}
