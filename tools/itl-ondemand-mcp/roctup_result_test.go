package main

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// Exact text of ROCTUP v1.10.0 embedded mode with danger_confirm=false for
// `Т.Удалить(0)`: an ordinary result without isError.
const roctupRejectedDelete = `{"success":false,"error":"Операция запрещена: код содержит опасные ключевые слова: Удалить / Operation not allowed: code contains dangerous keywords: Удалить","dangerous_keywords":["Удалить"]}`

func newRoctupTextBackend(t *testing.T, tools []*mcp.Tool, answers map[string]string) *httptest.Server {
	t.Helper()
	server := mcp.NewServer(&mcp.Implementation{Name: "roctup-backend", Version: "1"}, nil)
	for _, definition := range tools {
		tool := definition
		server.AddTool(tool, func(context.Context, *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			text, ok := answers[tool.Name]
			if !ok {
				text = tool.Name
			}
			return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: text}}}, nil
		})
	}
	backend := httptest.NewServer(mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server { return server }, nil))
	t.Cleanup(backend.Close)
	return backend
}

func TestRoctupDangerousKeywordRejectionNamesVanessaRouteAndKeepsBackend(t *testing.T) {
	tools := []*mcp.Tool{{Name: "execute_code", InputSchema: map[string]any{"type": "object"}}}
	backend := newRoctupTextBackend(t, tools, map[string]string{"execute_code": roctupRejectedDelete})
	broker := &fakeBroker{info: &backendInfo{URL: backend.URL, BackendVersion: "test"}}
	_, session := newFacadeSession(t, tools, broker, time.Minute, nil)

	result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "execute_code",
		Arguments: map[string]any{"code": "Т = Новый ТаблицаЗначений; Т.Удалить(0);"}})
	if err != nil {
		t.Fatal(err)
	}
	assertToolErrorCode(t, result, roctupDangerousKeywordsRejected)
	details := failureDetails(t, result)
	keywords, _ := details["dangerousKeywords"].([]any)
	if details["callOutcome"] != "not-started" || details["partialEffectsPossible"] != false || details["automaticRetryPerformed"] != false ||
		details["action"] != "route-code-through-vanessa-code-step" || len(keywords) != 1 || keywords[0] != "Удалить" ||
		!strings.HasPrefix(details["upstreamError"].(string), "Операция запрещена") {
		t.Fatalf("rejection details are wrong: %#v", details)
	}
	text := resultText(result)
	for _, fragment := range []string{"ran nothing", "Удалить", "И я выполняю код встроенного языка на сервере (Расширение)", "run_scenario", "build/agent-artifacts/<task-id>/tmp", "Never rename"} {
		if !strings.Contains(text, fragment) {
			t.Fatalf("rejection text lacks %q: %s", fragment, text)
		}
	}
	// The rejection is an answer: the backend stays for the next call.
	if _, stops := broker.counts(); stops != 0 {
		t.Fatalf("an answered rejection stopped the backend: stops=%d", stops)
	}
}

func TestRoctupDangerousKeywordRejectionLeavesOtherAnswersUnchanged(t *testing.T) {
	declined := `{"success":false,"error":"Операция отклонена пользователем. Код содержит опасные ключевые слова: Удалить"}`
	succeeded := `{"success":true,"data":{"dangerous_keywords":["Удалить"]}}`
	for _, tc := range []struct {
		family, tool, text string
		isError            bool
	}{
		{"roctup", "execute_code", declined, false},
		{"roctup", "execute_code", succeeded, false},
		{"roctup", "execute_code", "Результат: 1", false},
		{"roctup", "execute_code", roctupRejectedDelete, true},
		{"roctup", "execute_query", roctupRejectedDelete, false},
		{"vanessa-ui", "execute_code", roctupRejectedDelete, false},
	} {
		upstream := &mcp.CallToolResult{IsError: tc.isError, Content: []mcp.Content{&mcp.TextContent{Text: tc.text}}}
		if got := roctupDangerousKeywordRejection(tc.family, tc.tool, upstream); got != upstream {
			t.Fatalf("%s/%s answer %q was converted: %#v", tc.family, tc.tool, tc.text, got)
		}
	}
	bom := &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: "\uFEFF" + roctupRejectedDelete + "\r\n"}}}
	assertToolErrorCode(t, roctupDangerousKeywordRejection("roctup", "execute_code", bom), roctupDangerousKeywordsRejected)
}

// PM5 20.11.2026: an unanswered ROCTUP dialog ended as a bare transport 504.
// The answer must say the outcome is unknown, that the backend is already
// stopped, and that a modifying call needs a read-only probe before a retry.
func TestBackendTransportFailureReportsUnknownOutcomeAndOwnedStop(t *testing.T) {
	tools := []*mcp.Tool{
		{Name: "execute_code", InputSchema: map[string]any{"type": "object"}},
		{Name: "execute_query", InputSchema: map[string]any{"type": "object"}, Annotations: &mcp.ToolAnnotations{ReadOnlyHint: true}},
	}
	server := mcp.NewServer(&mcp.Implementation{Name: "gateway-timeout-backend", Version: "1"}, nil)
	for _, definition := range tools {
		tool := definition
		server.AddTool(tool, func(context.Context, *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: tool.Name}}}, nil
		})
	}
	inner := mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server { return server }, nil)
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		body, _ := io.ReadAll(req.Body)
		if bytes.Contains(body, []byte(`"tools/call"`)) {
			http.Error(w, "Gateway Timeout", http.StatusGatewayTimeout)
			return
		}
		req.Body = io.NopCloser(bytes.NewReader(body))
		inner.ServeHTTP(w, req)
	}))
	t.Cleanup(backend.Close)

	for _, tc := range []struct {
		tool, action, fragment string
		mutating               bool
	}{
		{"execute_code", "probe-state-read-only-before-retry", "read-only before any retry", true},
		{"execute_query", "retry-tool-call", "retry is safe", false},
	} {
		broker := &fakeBroker{info: &backendInfo{URL: backend.URL, BackendVersion: "test"}}
		rt, session := newFacadeSession(t, tools, broker, time.Minute, nil)
		result := callAfterReadyBackend(t, rt, session, &mcp.CallToolParams{Name: tc.tool, Arguments: map[string]any{}})

		assertToolErrorCode(t, result, "ITL_ONDEMAND_BACKEND_CALL_FAILED")
		details := failureDetails(t, result)
		if details["callOutcome"] != "unknown" || details["partialEffectsPossible"] != tc.mutating || details["action"] != tc.action ||
			details["backendStopped"] != true || details["automaticRetryPerformed"] != false || details["tool"] != tc.tool {
			t.Fatalf("%s transport failure details are wrong: %#v", tc.tool, details)
		}
		text := resultText(result)
		for _, fragment := range []string{"Gateway Timeout", "outcome unknown", "without " + ownerRecoveryTool, tc.fragment} {
			if !strings.Contains(text, fragment) {
				t.Fatalf("%s transport failure text lacks %q: %s", tc.tool, fragment, text)
			}
		}
		if _, stops := broker.counts(); stops != 1 {
			t.Fatalf("%s failed backend was not stopped exactly once: stops=%d", tc.tool, stops)
		}
	}
}
