package main

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func sessionLifecycleTools() []*mcp.Tool {
	tools := integrationTools()
	for _, name := range []string{roctupCloseSessionTool, roctupRestartSessionTool} {
		tools = append(tools, &mcp.Tool{Name: name, Description: "upstream session lifecycle", InputSchema: map[string]any{"type": "object", "properties": map[string]any{}}})
	}
	return tools
}

type upstreamCallLog struct {
	mu    sync.Mutex
	calls map[string]int
}

func (l *upstreamCallLog) observe(name string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.calls[name]++
}

func (l *upstreamCallLog) count(name string) int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.calls[name]
}

func callLifecycleTool(t *testing.T, session *mcp.ClientSession, name string, arguments map[string]any) *mcp.CallToolResult {
	t.Helper()
	result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: name, Arguments: arguments})
	if err != nil {
		t.Fatalf("%s transport error: %v", name, err)
	}
	return result
}

func TestRoctupCloseSessionRetiresOwnedBackendWithoutForwarding(t *testing.T) {
	tools := sessionLifecycleTools()
	log := &upstreamCallLog{calls: map[string]int{}}
	_, backend := newBackendWithObserver(t, tools, false, log.observe)
	broker := &fakeBroker{info: &backendInfo{URL: backend.URL, PID: 44408, Port: 6003}}
	rt, session := newFacadeSession(t, tools, broker, time.Minute, nil)
	writeRuntimeMarker(t, rt, rt.instanceID)

	if result := callLifecycleTool(t, session, "echo", map[string]any{"value": "x"}); result.IsError {
		t.Fatalf("first call failed: %#v", result)
	}
	closed := callLifecycleTool(t, session, roctupCloseSessionTool, map[string]any{})
	if closed.IsError {
		t.Fatalf("close failed: %#v", closed)
	}
	if text := resultText(closed); !strings.Contains(text, "next tool call starts a new session") || strings.Contains(strings.ToLower(text), "powershell") {
		t.Fatalf("close result must replace the upstream launcher instruction: %q", text)
	}
	if structured, _ := closed.StructuredContent.(map[string]any); structured["facadeHandled"] != true {
		t.Fatalf("close result is not marked facade-handled: %#v", closed.StructuredContent)
	}
	if ensures, stops := broker.counts(); ensures != 1 || stops != 1 {
		t.Fatalf("close must stop the owned backend exactly once: ensures=%d stops=%d", ensures, stops)
	}
	if log.count(roctupCloseSessionTool) != 0 {
		t.Fatal("close_1c_session reached the backend; its process would outlive the registration")
	}
	if result := callLifecycleTool(t, session, "echo", map[string]any{"value": "y"}); result.IsError {
		t.Fatalf("call after close failed: %#v", result)
	}
	if ensures, _ := broker.counts(); ensures != 2 {
		t.Fatalf("call after close must start a fresh backend: ensures=%d", ensures)
	}
}

func TestRoctupCloseSessionWithoutBackendStartsNothing(t *testing.T) {
	tools := sessionLifecycleTools()
	_, backend := newBackend(t, tools, false)
	broker := &fakeBroker{info: &backendInfo{URL: backend.URL, PID: 44408, Port: 6003}}
	rt, session := newFacadeSession(t, tools, broker, time.Minute, nil)
	writeRuntimeMarker(t, rt, rt.instanceID)

	if result := callLifecycleTool(t, session, roctupCloseSessionTool, map[string]any{}); result.IsError {
		t.Fatalf("close without a backend failed: %#v", result)
	}
	if ensures, stops := broker.counts(); ensures != 0 || stops != 0 {
		t.Fatalf("close without a backend must not start or stop one: ensures=%d stops=%d", ensures, stops)
	}
}

func TestRoctupRestartSessionReplacesBackendThroughFacade(t *testing.T) {
	tools := sessionLifecycleTools()
	log := &upstreamCallLog{calls: map[string]int{}}
	_, backend := newBackendWithObserver(t, tools, false, log.observe)
	broker := &fakeBroker{info: &backendInfo{URL: backend.URL, PID: 44408, Port: 6003}}
	rt, session := newFacadeSession(t, tools, broker, time.Minute, nil)
	writeRuntimeMarker(t, rt, rt.instanceID)

	if result := callLifecycleTool(t, session, "echo", map[string]any{"value": "x"}); result.IsError {
		t.Fatalf("first call failed: %#v", result)
	}
	restarted := callLifecycleTool(t, session, roctupRestartSessionTool, map[string]any{})
	if restarted.IsError {
		t.Fatalf("restart failed: %#v", restarted)
	}
	if ensures, stops := broker.counts(); ensures != 2 || stops != 1 {
		t.Fatalf("restart must stop and start through the broker: ensures=%d stops=%d", ensures, stops)
	}
	if log.count(roctupRestartSessionTool) != 0 {
		t.Fatal("restart_1c_session reached the backend; the new 1C PID would not match the registration")
	}
	if result := callLifecycleTool(t, session, "echo", map[string]any{"value": "y"}); result.IsError {
		t.Fatalf("call after restart failed: %#v", result)
	}
	if ensures, _ := broker.counts(); ensures != 2 {
		t.Fatalf("call after restart must reuse the restarted backend: ensures=%d", ensures)
	}
}

func TestRoctupCloseSessionStopFailureNeverStrandsTheFacade(t *testing.T) {
	tools := sessionLifecycleTools()
	_, backend := newBackend(t, tools, false)
	broker := &fakeBroker{info: &backendInfo{URL: backend.URL, PID: 44408, Port: 6003}}
	rt, session := newFacadeSession(t, tools, broker, time.Minute, nil)
	writeRuntimeMarker(t, rt, rt.instanceID)

	if result := callLifecycleTool(t, session, "echo", map[string]any{"value": "x"}); result.IsError {
		t.Fatalf("first call failed: %#v", result)
	}
	broker.mu.Lock()
	broker.stopFailures = 3
	broker.mu.Unlock()
	failed := callLifecycleTool(t, session, roctupCloseSessionTool, map[string]any{})
	if !failed.IsError || !strings.Contains(resultText(failed), "ITL_ONDEMAND_STOP_FAILED") {
		t.Fatalf("unconfirmed close must report its stop failure: %#v", failed)
	}
	structured, _ := failed.StructuredContent.(map[string]any)
	details, _ := structured["details"].(map[string]any)
	if details["action"] != ownerRecoveryTool || details["continuation"] != connectionRecoveryContinuation {
		t.Fatalf("stop failure lacks the owner continuation: %#v", failed.StructuredContent)
	}
	if result := callLifecycleTool(t, session, "echo", map[string]any{"value": "y"}); result.IsError {
		t.Fatalf("next call must start a fresh backend after an unconfirmed close: %#v", result)
	}
	if ensures, _ := broker.counts(); ensures != 2 {
		t.Fatalf("unconfirmed close must not keep the old backend: ensures=%d", ensures)
	}
}

func TestVanessaFamilyForwardsSameNamedTools(t *testing.T) {
	if isFacadeSessionLifecycleTool("vanessa-ui", roctupCloseSessionTool) || isFacadeSessionLifecycleTool("vanessa-ui", roctupRestartSessionTool) {
		t.Fatal("only the ROCTUP family owns these session lifecycle tools")
	}
	if isFacadeSessionLifecycleTool("roctup", "execute_code") {
		t.Fatal("ordinary ROCTUP tools must be forwarded")
	}
}
