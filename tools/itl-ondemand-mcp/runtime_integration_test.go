package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/jsonrpc"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type fakeBroker struct {
	mu                sync.Mutex
	info              *backendInfo
	recoverInfo       *backendInfo
	recoverHook       func(string)
	ensures           int
	recoveries        int
	testClientEnsures int
	stops             int
	stopFailures      int
	testClientErr     error
}

func (b *fakeBroker) Ensure(context.Context) (*backendInfo, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.ensures++
	copy := *b.info
	return &copy, nil
}

func (b *fakeBroker) EnsureTestClient(context.Context) (*backendInfo, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.testClientEnsures++
	if b.testClientErr != nil {
		return nil, b.testClientErr
	}
	copy := *b.info
	if copy.TestClientPID <= 0 {
		copy.TestClientPID = 808
	}
	if copy.TestClientPort <= 0 {
		copy.TestClientPort = 48151
	}
	copy.TestClientState = testClientPortReady
	copy.TestClientReused = b.testClientEnsures > 1
	b.info = &copy
	return &copy, nil
}

func (b *fakeBroker) Recover(_ context.Context, previous *backendInfo, replacementInstanceID string) (*backendInfo, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.recoveries++
	if previous == nil || previous.PID <= 0 || previous.Port <= 0 {
		return nil, fmt.Errorf("recovery identity is incomplete")
	}
	info := b.recoverInfo
	if info == nil {
		info = b.info
	}
	copy := *info
	copy.InstanceID = replacementInstanceID
	b.info = &copy
	if b.recoverHook != nil {
		b.recoverHook(replacementInstanceID)
	}
	return &copy, nil
}

func (b *fakeBroker) Stop(context.Context) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.stops++
	if b.stopFailures > 0 {
		b.stopFailures--
		return fmt.Errorf("simulated broker stop failure")
	}
	return nil
}

func (b *fakeBroker) counts() (int, int) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.ensures, b.stops
}

func (b *fakeBroker) recoveryCount() int {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.recoveries
}

func (b *fakeBroker) testClientEnsureCount() int {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.testClientEnsures
}

func boolPointer(value bool) *bool { return &value }

func writeRuntimeMarker(t *testing.T, rt *runtime, instanceID string) {
	t.Helper()
	path := filepath.Join(rt.projectRoot, ".agent-1c", "mcp", "ondemand", rt.family, instanceID+".json")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
}

func configureRecoveryMarkers(t *testing.T, rt *runtime, broker *fakeBroker, initialInstanceID string) {
	t.Helper()
	writeRuntimeMarker(t, rt, initialInstanceID)
	broker.recoverHook = func(replacementInstanceID string) {
		oldPath := filepath.Join(rt.projectRoot, ".agent-1c", "mcp", "ondemand", rt.family, initialInstanceID+".json")
		_ = os.Remove(oldPath)
		writeRuntimeMarker(t, rt, replacementInstanceID)
	}
}

func integrationTools() []*mcp.Tool {
	return []*mcp.Tool{
		{
			Name: "echo", Description: "echo a value",
			InputSchema:  map[string]any{"type": "object", "properties": map[string]any{"value": map[string]any{"type": "string"}}, "required": []any{"value"}},
			OutputSchema: map[string]any{"type": "object", "properties": map[string]any{"value": map[string]any{"type": "string"}}},
			Annotations:  &mcp.ToolAnnotations{ReadOnlyHint: true, DestructiveHint: boolPointer(false)},
		},
		{Name: "second", Description: "pagination sentinel", InputSchema: map[string]any{"type": "object"}},
	}
}

func newBackend(t *testing.T, tools []*mcp.Tool, progress bool) (*mcp.Server, *httptest.Server) {
	return newBackendWithObserver(t, tools, progress, nil)
}

func newBackendWithObserver(t *testing.T, tools []*mcp.Tool, progress bool, onCall func(string)) (*mcp.Server, *httptest.Server) {
	t.Helper()
	server := mcp.NewServer(&mcp.Implementation{Name: "fake-backend", Version: "1"}, &mcp.ServerOptions{PageSize: 1})
	for _, definition := range tools {
		tool := definition
		server.AddTool(tool, func(ctx context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			if onCall != nil {
				onCall(tool.Name)
			}
			if progress && tool.Name == "echo" && req.Params.GetProgressToken() != nil {
				_ = req.Session.NotifyProgress(ctx, &mcp.ProgressNotificationParams{
					ProgressToken: req.Params.GetProgressToken(), Progress: 1, Total: 1, Message: "forwarded",
				})
			}
			return &mcp.CallToolResult{
				Content:           []mcp.Content{&mcp.TextContent{Text: tool.Name}},
				StructuredContent: map[string]any{"value": tool.Name},
			}, nil
		})
	}
	httpServer := httptest.NewServer(mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server { return server }, nil))
	t.Cleanup(httpServer.Close)
	return server, httpServer
}

func newFacadeSession(t *testing.T, tools []*mcp.Tool, broker *fakeBroker, idle time.Duration, progress chan *mcp.ProgressNotificationParams) (*runtime, *mcp.ClientSession) {
	return newFacadeSessionForFamily(t, "roctup", tools, broker, idle, progress)
}

func newFacadeSessionForFamily(t *testing.T, family string, tools []*mcp.Tool, broker *fakeBroker, idle time.Duration, progress chan *mcp.ProgressNotificationParams) (*runtime, *mcp.ClientSession) {
	t.Helper()
	serverName := "itl-roctup-data"
	if family == "vanessa-ui" {
		serverName = "itl-vanessa-ui"
	}
	rt := &runtime{
		catalog: &loadedCatalog{SHA256: "catalog", Data: catalogFile{SchemaVersion: 1, Family: family, Tools: tools}},
		broker:  broker, projectRoot: t.TempDir(), family: family, instanceID: "0123456789abcdef0123456789abcdef",
		idle: idle, logger: slog.New(slog.NewTextHandler(os.Stderr, nil)), progress: make(map[string]*mcp.ServerSession),
	}
	server := mcp.NewServer(&mcp.Implementation{Name: serverName, Version: version}, nil)
	for _, definition := range tools {
		tool := definition
		server.AddTool(tool, func(ctx context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			return rt.call(ctx, req)
		})
	}
	client := mcp.NewClient(&mcp.Implementation{Name: "test-client", Version: "1"}, &mcp.ClientOptions{
		ProgressNotificationHandler: func(_ context.Context, req *mcp.ProgressNotificationClientRequest) {
			if progress != nil {
				progress <- req.Params
			}
		},
	})
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
		_ = rt.close(context.Background())
	})
	return rt, clientSession
}

func newGatewayFacadeSession(t *testing.T, family string, tools []*mcp.Tool, broker *fakeBroker, progress chan *mcp.ProgressNotificationParams) (*runtime, *mcp.ClientSession) {
	t.Helper()
	rt := &runtime{
		catalog: &loadedCatalog{SHA256: "catalog", Data: catalogFile{SchemaVersion: 1, Family: family, Tools: tools}},
		broker:  broker, projectRoot: t.TempDir(), family: family, instanceID: "0123456789abcdef0123456789abcdef",
		idle: time.Minute, logger: slog.New(slog.NewTextHandler(os.Stderr, nil)), progress: make(map[string]*mcp.ServerSession),
	}
	server := mcp.NewServer(&mcp.Implementation{Name: "itl-" + family, Version: version}, nil)
	addGatewayTools(server, rt)
	client := mcp.NewClient(&mcp.Implementation{Name: "gateway-test-client", Version: "1"}, &mcp.ClientOptions{
		ProgressNotificationHandler: func(_ context.Context, req *mcp.ProgressNotificationClientRequest) {
			if progress != nil {
				progress <- req.Params
			}
		},
	})
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
		_ = rt.close(context.Background())
	})
	return rt, clientSession
}

func vanessaIntegrationTools() []*mcp.Tool {
	object := map[string]any{"type": "object"}
	filePath := map[string]any{"type": "object", "properties": map[string]any{"filePath": map[string]any{"type": "string"}}, "required": []string{"filePath"}}
	return []*mcp.Tool{
		{Name: "get_environment_data", InputSchema: object},
		{Name: "connect_test_client", InputSchema: map[string]any{"type": "object", "properties": map[string]any{"profileName": map[string]any{"type": "string"}}}},
		{Name: "get_window_list_testclient", InputSchema: object},
		{Name: "manage_test_client_profiles", InputSchema: object},
		{Name: "open_feature_file", InputSchema: filePath},
		{Name: "check_syntax", InputSchema: filePath},
		{Name: "load_features", InputSchema: map[string]any{"type": "object", "properties": map[string]any{"path": map[string]any{"type": "string"}}}},
		{Name: "get_editor_state", InputSchema: object},
		{Name: "run_scenario", InputSchema: object},
		{Name: "close_test_client", InputSchema: object},
	}
}

func newVanessaBackend(t *testing.T, environmentText, connectText, postText string, connectCalls *int) *httptest.Server {
	return newVanessaBackendSequence(t, environmentText, []string{connectText}, postText, connectCalls)
}

func newVanessaBackendSequence(t *testing.T, environmentText string, connectTexts []string, postText string, connectCalls *int) *httptest.Server {
	return newVanessaBackendObserved(t, environmentText, connectTexts, postText, connectCalls, nil)
}

func newVanessaBackendObserved(t *testing.T, environmentText string, connectTexts []string, postText string, connectCalls *int, calls map[string]int) *httptest.Server {
	t.Helper()
	server := mcp.NewServer(&mcp.Implementation{Name: "fake-vanessa", Version: "1"}, nil)
	for _, definition := range vanessaIntegrationTools() {
		tool := definition
		server.AddTool(tool, func(context.Context, *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			if calls != nil {
				calls[tool.Name]++
			}
			text := tool.Name
			switch tool.Name {
			case "get_environment_data":
				text = environmentText
			case "connect_test_client":
				*connectCalls++
				index := *connectCalls - 1
				if index >= len(connectTexts) {
					index = len(connectTexts) - 1
				}
				text = connectTexts[index]
			case "get_window_list_testclient":
				text = postText
			}
			return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: text}}}, nil
		})
	}
	httpServer := httptest.NewServer(mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server { return server }, nil))
	t.Cleanup(httpServer.Close)
	return httpServer
}

func newVanessaBackendWithObserver(t *testing.T, environmentText string, onCall func(string)) *httptest.Server {
	t.Helper()
	server := mcp.NewServer(&mcp.Implementation{Name: "fake-vanessa", Version: "1"}, nil)
	for _, definition := range vanessaIntegrationTools() {
		tool := definition
		server.AddTool(tool, func(context.Context, *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			if onCall != nil {
				onCall(tool.Name)
			}
			text := tool.Name
			if tool.Name == "get_environment_data" {
				text = environmentText
			}
			return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: text}}}, nil
		})
	}
	httpServer := httptest.NewServer(mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server { return server }, nil))
	t.Cleanup(httpServer.Close)
	return httpServer
}

func TestRuntimeLazyHTTPPaginationCallAndProgress(t *testing.T) {
	tools := integrationTools()
	_, backend := newBackend(t, tools, true)
	broker := &fakeBroker{info: &backendInfo{URL: backend.URL, BackendVersion: "test"}}
	progress := make(chan *mcp.ProgressNotificationParams, 1)
	_, session := newFacadeSession(t, tools, broker, time.Minute, progress)

	listed, err := session.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(listed.Tools) != 2 {
		t.Fatalf("facade list has %d tools", len(listed.Tools))
	}
	if ensures, _ := broker.counts(); ensures != 0 {
		t.Fatalf("tools/list started backend: %d", ensures)
	}

	result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "echo", Arguments: map[string]any{"value": "x"}, Meta: mcp.Meta{"progressToken": "p1"}})
	if err != nil {
		t.Fatal(err)
	}
	if result.IsError {
		t.Fatalf("call returned tool error: %#v", result.StructuredContent)
	}
	if ensures, _ := broker.counts(); ensures != 1 {
		t.Fatalf("ensure count=%d", ensures)
	}
	select {
	case got := <-progress:
		if got.Message != "forwarded" || got.ProgressToken != "p1" {
			t.Fatalf("unexpected progress: %#v", got)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("progress was not forwarded")
	}
}

func TestRuntimeStartsFreshBackendAfterExternalOwnedCleanup(t *testing.T) {
	tools := vanessaIntegrationTools()
	var firstCalls, secondCalls int
	firstBackend := newVanessaBackendWithObserver(t, "VanessaExt: Истина", func(name string) {
		if name == "open_feature_file" {
			firstCalls++
		}
	})
	secondBackend := newVanessaBackendWithObserver(t, "VanessaExt: Истина", func(name string) {
		if name == "open_feature_file" {
			secondCalls++
		}
	})
	instanceID := "0123456789abcdef0123456789abcdef"
	broker := &fakeBroker{info: &backendInfo{InstanceID: instanceID, PID: 101, Port: 41001, URL: firstBackend.URL, TestClientProfile: "itl-ondemand", TestClientPort: 48151}}
	rt, session := newGatewayFacadeSession(t, "vanessa-ui", tools, broker, nil)
	writeRuntimeMarker(t, rt, instanceID)

	first, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: gatewayCallTool, Arguments: map[string]any{
		"name": "open_feature_file", "arguments": map[string]any{"filePath": "tests/features/first.feature"},
	}})
	if err != nil || first.IsError {
		t.Fatalf("first editor-only call failed: err=%v result=%#v", err, first)
	}
	statePath := filepath.Join(rt.projectRoot, ".agent-1c", "mcp", "ondemand", rt.family, instanceID+".json")
	if err := os.Remove(statePath); err != nil {
		t.Fatal(err)
	}
	broker.mu.Lock()
	broker.info = &backendInfo{InstanceID: instanceID, PID: 202, Port: 41002, URL: secondBackend.URL, TestClientProfile: "itl-ondemand", TestClientPort: 48151}
	broker.mu.Unlock()

	second, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: gatewayCallTool, Arguments: map[string]any{
		"name": "open_feature_file", "arguments": map[string]any{"filePath": "tests/features/second.feature"},
	}})
	if err != nil || second.IsError {
		t.Fatalf("fresh editor-only call failed without reload: err=%v result=%#v", err, second)
	}
	if ensures, _ := broker.counts(); ensures != 2 {
		t.Fatalf("fresh backend ensure count=%d, want 2", ensures)
	}
	if firstCalls != 1 || secondCalls != 1 {
		t.Fatalf("calls were not isolated across cleanup: first=%d second=%d", firstCalls, secondCalls)
	}
}

func TestRuntimeRecoversOnceAndRetriesIdempotentCall(t *testing.T) {
	tools := integrationTools()
	_, staleBackend := newBackend(t, tools, false)
	var replacementCalls int
	var replacementMu sync.Mutex
	_, replacementBackend := newBackendWithObserver(t, tools, false, func(string) {
		replacementMu.Lock()
		replacementCalls++
		replacementMu.Unlock()
	})
	instanceID := "0123456789abcdef0123456789abcdef"
	broker := &fakeBroker{
		info:        &backendInfo{InstanceID: instanceID, PID: 101, Port: 41001, URL: staleBackend.URL},
		recoverInfo: &backendInfo{PID: 202, Port: 41002, URL: replacementBackend.URL},
	}
	rt, session := newFacadeSession(t, tools, broker, time.Minute, nil)
	configureRecoveryMarkers(t, rt, broker, instanceID)

	first, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "echo", Arguments: map[string]any{"value": "before"}})
	if err != nil || first.IsError {
		t.Fatalf("initial call failed: result=%#v err=%v", first, err)
	}
	staleBackend.CloseClientConnections()
	staleBackend.Close()

	recovered, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "echo", Arguments: map[string]any{"value": "after"}})
	if err != nil {
		t.Fatal(err)
	}
	if recovered.IsError || !strings.Contains(resultText(recovered), `"code":"ITL_ONDEMAND_BACKEND_RECOVERED"`) {
		t.Fatalf("idempotent call was not recovered: %#v", recovered)
	}
	if broker.recoveryCount() != 1 {
		t.Fatalf("recovery count=%d", broker.recoveryCount())
	}
	if ensures, _ := broker.counts(); ensures != 1 {
		t.Fatalf("initial ensure count=%d", ensures)
	}
	replacementMu.Lock()
	calls := replacementCalls
	replacementMu.Unlock()
	if calls != 1 {
		t.Fatalf("idempotent tool retry count=%d", calls)
	}
	rt.mu.Lock()
	replacementID := rt.instanceID
	rt.mu.Unlock()
	if replacementID == instanceID || !strings.Contains(resultText(recovered), replacementID) {
		t.Fatalf("replacement instance ID was not returned: old=%s new=%s result=%s", instanceID, replacementID, resultText(recovered))
	}
}

func TestRuntimeRecoversButNeverReplaysNonIdempotentCall(t *testing.T) {
	tools := integrationTools()
	_, staleBackend := newBackend(t, tools, false)
	var replacementCalls int
	var replacementMu sync.Mutex
	replacementServer := mcp.NewServer(&mcp.Implementation{Name: "replacement", Version: "1"}, nil)
	for _, definition := range tools {
		tool := definition
		replacementServer.AddTool(tool, func(context.Context, *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			replacementMu.Lock()
			replacementCalls++
			replacementMu.Unlock()
			return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: tool.Name}}}, nil
		})
	}
	replacementBackend := httptest.NewServer(mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server { return replacementServer }, nil))
	t.Cleanup(replacementBackend.Close)
	instanceID := "0123456789abcdef0123456789abcdef"
	broker := &fakeBroker{
		info:        &backendInfo{InstanceID: instanceID, PID: 301, Port: 42001, URL: staleBackend.URL},
		recoverInfo: &backendInfo{PID: 302, Port: 42002, URL: replacementBackend.URL},
	}
	rt, session := newFacadeSession(t, tools, broker, time.Minute, nil)
	configureRecoveryMarkers(t, rt, broker, instanceID)

	if _, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "echo", Arguments: map[string]any{"value": "prime"}}); err != nil {
		t.Fatal(err)
	}
	staleBackend.CloseClientConnections()
	staleBackend.Close()
	result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "second", Arguments: map[string]any{}})
	if err != nil {
		t.Fatal(err)
	}
	assertToolErrorCode(t, result, "ITL_ONDEMAND_RECOVERY_ACTION_REQUIRED")
	replacementMu.Lock()
	calls := replacementCalls
	replacementMu.Unlock()
	if calls != 0 {
		t.Fatalf("non-idempotent tool was replayed %d time(s)", calls)
	}
	if broker.recoveryCount() != 1 {
		t.Fatalf("recovery count=%d", broker.recoveryCount())
	}
	structured := result.StructuredContent.(map[string]any)
	details := structured["details"].(map[string]any)
	if details["backendRecovered"] != true || details["action"] != "review-and-retry-tool-call" || details["instanceId"] == instanceID {
		t.Fatalf("unexpected structured recovery action: %#v", structured)
	}
}

func TestRuntimeConcurrentStaleCallsShareOneRecovery(t *testing.T) {
	tools := integrationTools()
	_, staleBackend := newBackend(t, tools, false)
	var replacementCalls int
	var replacementMu sync.Mutex
	_, replacementBackend := newBackendWithObserver(t, tools, false, func(string) {
		replacementMu.Lock()
		replacementCalls++
		replacementMu.Unlock()
	})
	instanceID := "0123456789abcdef0123456789abcdef"
	broker := &fakeBroker{
		info:        &backendInfo{InstanceID: instanceID, PID: 401, Port: 43001, URL: staleBackend.URL},
		recoverInfo: &backendInfo{PID: 402, Port: 43002, URL: replacementBackend.URL},
	}
	rt, session := newFacadeSession(t, tools, broker, time.Minute, nil)
	configureRecoveryMarkers(t, rt, broker, instanceID)
	if _, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "echo", Arguments: map[string]any{"value": "prime"}}); err != nil {
		t.Fatal(err)
	}
	staleBackend.CloseClientConnections()
	staleBackend.Close()

	start := make(chan struct{})
	results := make(chan *mcp.CallToolResult, 2)
	errors := make(chan error, 2)
	for range 2 {
		go func() {
			<-start
			result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "echo", Arguments: map[string]any{"value": "concurrent"}})
			results <- result
			errors <- err
		}()
	}
	close(start)
	for range 2 {
		if err := <-errors; err != nil {
			t.Fatal(err)
		}
		result := <-results
		if result == nil || result.IsError || !strings.Contains(resultText(result), `"code":"ITL_ONDEMAND_BACKEND_RECOVERED"`) {
			t.Fatalf("concurrent call did not use recovered backend: %#v", result)
		}
	}
	if broker.recoveryCount() != 1 {
		t.Fatalf("concurrent recovery count=%d", broker.recoveryCount())
	}
	replacementMu.Lock()
	calls := replacementCalls
	replacementMu.Unlock()
	if calls != 2 {
		t.Fatalf("concurrent retry count=%d", calls)
	}
}

func TestGatewayListsTwoToolsAndResolvesWithoutStartingBackend(t *testing.T) {
	tools := integrationTools()
	broker := &fakeBroker{info: &backendInfo{}}
	_, session := newGatewayFacadeSession(t, "roctup", tools, broker, nil)

	listed, err := session.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	names := make([]string, 0, len(listed.Tools))
	for _, tool := range listed.Tools {
		names = append(names, tool.Name)
	}
	sort.Strings(names)
	if len(names) != 2 || names[0] != gatewayCallTool || names[1] != gatewayResolveTool {
		t.Fatalf("unexpected gateway surface: %#v", listed.Tools)
	}
	result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: gatewayResolveTool, Arguments: map[string]any{"query": "echo", "limit": 1}})
	if err != nil {
		t.Fatal(err)
	}
	if result.IsError || !strings.Contains(resultText(result), `"name":"echo"`) || !strings.Contains(resultText(result), `"inputSchema"`) {
		t.Fatalf("unexpected resolve result: %s", resultText(result))
	}
	if ensures, _ := broker.counts(); ensures != 0 {
		t.Fatalf("resolve_tool started backend: %d", ensures)
	}
}

func TestGatewayDefinitionsStayCompactAndDoNotEmbedInnerCatalog(t *testing.T) {
	definitions := []*mcp.Tool{gatewayResolveDefinition("roctup"), gatewayCallDefinition("roctup"), gatewayResolveDefinition("vanessa-ui"), gatewayCallDefinition("vanessa-ui")}
	raw, err := json.Marshal(definitions)
	if err != nil {
		t.Fatal(err)
	}
	if len(raw) > 6000 {
		t.Fatalf("four gateway definitions are too large: %d bytes", len(raw))
	}
	for _, innerName := range []string{"get_metadata", "execute_query", "run_scenario", "get_test_results"} {
		if strings.Contains(string(raw), innerName) {
			t.Fatalf("gateway surface embeds inner tool %q", innerName)
		}
	}
}

func TestGatewayValidatesBeforeStartupAndForwardsExactTool(t *testing.T) {
	tools := integrationTools()
	_, backend := newBackend(t, tools, false)
	broker := &fakeBroker{info: &backendInfo{URL: backend.URL, BackendVersion: "test"}}
	_, session := newGatewayFacadeSession(t, "roctup", tools, broker, nil)

	invalid, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: gatewayCallTool, Arguments: map[string]any{"name": "echo", "arguments": map[string]any{}}})
	if err != nil {
		t.Fatal(err)
	}
	assertToolErrorCode(t, invalid, "ITL_ONDEMAND_ARGUMENTS_INVALID")
	if ensures, _ := broker.counts(); ensures != 0 {
		t.Fatalf("invalid inner arguments started backend: %d", ensures)
	}

	valid, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: gatewayCallTool, Arguments: map[string]any{"name": "echo", "arguments": map[string]any{"value": "x"}}})
	if err != nil {
		t.Fatal(err)
	}
	if valid.IsError || resultText(valid) != "echo" {
		t.Fatalf("gateway did not forward exact tool: %#v", valid)
	}
	if ensures, _ := broker.counts(); ensures != 1 {
		t.Fatalf("valid gateway call ensure count=%d", ensures)
	}
}

func TestGatewayRejectsUnknownToolBeforeStartup(t *testing.T) {
	broker := &fakeBroker{info: &backendInfo{}}
	_, session := newGatewayFacadeSession(t, "roctup", integrationTools(), broker, nil)
	result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: gatewayCallTool, Arguments: map[string]any{"name": "missing", "arguments": map[string]any{}}})
	if err != nil {
		t.Fatal(err)
	}
	assertToolErrorCode(t, result, "ITL_ONDEMAND_TOOL_UNKNOWN")
	if ensures, _ := broker.counts(); ensures != 0 {
		t.Fatalf("unknown inner tool started backend: %d", ensures)
	}
}

func TestGatewayResolvesRussianRoctupAlias(t *testing.T) {
	catalog := &loadedCatalog{Data: catalogFile{Family: "roctup", Tools: []*mcp.Tool{
		{Name: "get_metadata", Description: "Get metadata", InputSchema: map[string]any{"type": "object"}},
		{Name: "execute_query", Description: "Execute query", InputSchema: map[string]any{"type": "object"}},
	}}}
	matches := searchCatalogTools(catalog, "roctup", "структура метаданных", 1)
	if len(matches) != 1 || matches[0].Name != "get_metadata" {
		t.Fatalf("Russian alias did not resolve metadata tool: %#v", matches)
	}
}

func TestGatewayPreservesQualifiedVanessaPathProtocolErrors(t *testing.T) {
	tools := vanessaIntegrationTools()
	server := mcp.NewServer(&mcp.Implementation{Name: "fake-vanessa", Version: "1"}, nil)
	for _, definition := range tools {
		tool := definition
		server.AddTool(tool, func(context.Context, *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			if tool.Name == "get_environment_data" {
				return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: "VanessaExt: true"}}}, nil
			}
			if tool.Name == "open_feature_file" {
				return nil, &jsonrpc.Error{Code: -32603, Message: `PATH_INVALID: invalid path C:\bad<path>\x.feature`}
			}
			return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: tool.Name}}}, nil
		})
	}
	backend := httptest.NewServer(mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server { return server }, nil))
	t.Cleanup(backend.Close)
	broker := &fakeBroker{info: &backendInfo{URL: backend.URL, BackendVersion: "test"}}
	rt, session := newGatewayFacadeSession(t, "vanessa-ui", tools, broker, nil)

	result, err := session.CallTool(context.Background(), &mcp.CallToolParams{
		Name: gatewayCallTool,
		Arguments: map[string]any{
			"name":      "open_feature_file",
			"arguments": map[string]any{"filePath": `C:\bad<path>\x.feature`},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	assertToolErrorCode(t, result, "PATH_INVALID")

	evidencePath := filepath.Join(rt.projectRoot, ".agent-1c", "mcp", "ondemand", "vanessa-ui", rt.instanceID+".evidence.jsonl")
	raw, err := os.ReadFile(evidencePath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), `"resultCode":"PATH_INVALID"`) {
		t.Fatalf("path protocol code was not preserved in evidence: %s", raw)
	}
}

func TestRuntimeRejectsCatalogMismatchAndStopsBackend(t *testing.T) {
	expected := integrationTools()
	actual := integrationTools()
	actual[0] = &mcp.Tool{Name: "echo", Description: "changed", InputSchema: actual[0].InputSchema}
	_, backend := newBackend(t, actual, false)
	broker := &fakeBroker{info: &backendInfo{URL: backend.URL}}
	_, session := newFacadeSession(t, expected, broker, time.Minute, nil)

	result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "echo", Arguments: map[string]any{"value": "x"}})
	if err != nil {
		t.Fatal(err)
	}
	if !result.IsError {
		t.Fatal("catalog mismatch was accepted")
	}
	structured, ok := result.StructuredContent.(map[string]any)
	if !ok || structured["code"] != "ITL_ONDEMAND_CATALOG_MISMATCH" {
		t.Fatalf("unexpected mismatch result: %#v", result.StructuredContent)
	}
	if _, stops := broker.counts(); stops == 0 {
		t.Fatal("mismatched backend was not stopped")
	}
}

func TestRuntimeWaitsForLateToolRegistration(t *testing.T) {
	expected := integrationTools()
	backendServer, backend := newBackend(t, expected[:1], false)
	broker := &fakeBroker{info: &backendInfo{URL: backend.URL}}
	runtime, session := newFacadeSession(t, expected, broker, time.Minute, nil)
	runtime.catalogWait = 2 * time.Second

	go func() {
		time.Sleep(50 * time.Millisecond)
		backendServer.AddTool(expected[1], func(context.Context, *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: "second"}}}, nil
		})
	}()

	result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "echo", Arguments: map[string]any{"value": "x"}})
	if err != nil {
		t.Fatal(err)
	}
	if result.IsError {
		t.Fatalf("late catalog registration was rejected: %#v", result.StructuredContent)
	}
	if _, stops := broker.counts(); stops != 0 {
		t.Fatalf("compatible backend was stopped: %d", stops)
	}
}

func TestRuntimeIdleCleanupStopsOnlyOwnedBroker(t *testing.T) {
	tools := integrationTools()
	_, backend := newBackend(t, tools, false)
	broker := &fakeBroker{info: &backendInfo{URL: backend.URL}}
	_, session := newFacadeSession(t, tools, broker, 40*time.Millisecond, nil)
	if _, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "echo", Arguments: map[string]any{"value": "x"}}); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if _, stops := broker.counts(); stops == 1 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("idle cleanup did not stop backend")
}

func TestRuntimeIdleCleanupRetriesAfterBrokerStopFailure(t *testing.T) {
	tools := integrationTools()
	_, backend := newBackend(t, tools, false)
	broker := &fakeBroker{info: &backendInfo{URL: backend.URL}, stopFailures: 1}
	rt, session := newFacadeSession(t, tools, broker, 30*time.Millisecond, nil)
	if _, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "echo", Arguments: map[string]any{"value": "x"}}); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		_, stops := broker.counts()
		rt.mu.Lock()
		cleaned := rt.backend == nil
		rt.mu.Unlock()
		if stops >= 2 && cleaned {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("idle cleanup did not retry a failed broker stop")
}

func TestRuntimeEOFCleanupRetriesAfterBrokerStopFailure(t *testing.T) {
	tools := integrationTools()
	_, backend := newBackend(t, tools, false)
	broker := &fakeBroker{info: &backendInfo{URL: backend.URL}, stopFailures: 1}
	rt, session := newFacadeSession(t, tools, broker, time.Minute, nil)
	if _, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "echo", Arguments: map[string]any{"value": "x"}}); err != nil {
		t.Fatal(err)
	}
	if err := rt.close(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, stops := broker.counts(); stops != 2 {
		t.Fatalf("EOF cleanup stop attempts=%d", stops)
	}
}

func TestRuntimeVanessaRequiresInstalledExtension(t *testing.T) {
	connectCalls := 0
	backend := newVanessaBackend(t, "VanessaExt: Ложь\nДругое: Истина", "connected", "window", &connectCalls)
	broker := &fakeBroker{info: &backendInfo{URL: backend.URL, TestClientProfile: "itl-ondemand", TestClientPort: 48151}}
	_, session := newFacadeSessionForFamily(t, "vanessa-ui", vanessaIntegrationTools(), broker, time.Minute, nil)

	result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "connect_test_client", Arguments: map[string]any{"profileName": "itl-ondemand"}})
	if err != nil {
		t.Fatal(err)
	}
	assertToolErrorCode(t, result, "ITL_VANESSA_EXT_NOT_READY")
	if connectCalls != 0 {
		t.Fatalf("connect was called before VanessaExt preflight: %d", connectCalls)
	}
	if _, stops := broker.counts(); stops != 1 {
		t.Fatalf("backend stop count=%d", stops)
	}
}

func TestConfirmsVanessaExtRussianYesFromRealEnvironmentShape(t *testing.T) {
	text := "## Внешняя компонента VanessaExt\n- Включено использование внешней компоненты VanessaExt: Да"
	if !confirmsVanessaExt(text) {
		t.Fatal("real get_environment_data answer did not confirm VanessaExt")
	}
	if confirmsVanessaExt("VanessaExt: Нет") {
		t.Fatal("negative VanessaExt answer was accepted")
	}
}

func TestVanessaToolClassificationKeepsEditorToolsProcessFree(t *testing.T) {
	for _, name := range []string{
		"check_syntax", "frequently_used_steps", "get_data_from_knowledge_base", "get_editor_state",
		"get_environment_data", "get_info_about_line_scenario", "get_table_data", "get_test_results",
		"get_VanessaAutomation_state", "get_window_list_os", "get_window_screenshot_os", "infobase_info",
		"load_features", "manage_breakpoints", "manage_test_client_profiles", "manage_variables",
		"open_feature_file", "search_for_steps_by_keywords", "select_scenario", "select_step",
		"stop_scenario", "voice_notification",
	} {
		if classifyVanessaTool(name) != vanessaToolEditorManager {
			t.Fatalf("editor/manager tool %q has class %q", name, classifyVanessaTool(name))
		}
	}
	for _, name := range []string{
		"execute_feature_step", "execute_form_actions", "get_active_window_data", "get_extension_list",
		"get_form_analysis", "get_form_element_data", "get_object_attributes",
		"get_window_list_testclient", "manage_command_interface", "manage_form_elements",
		"run_scenario", "save_table_document_to_file", "user_actions_recording", "window_management",
	} {
		if !vanessaToolRequiresTestClient(name) {
			t.Fatalf("runtime tool %q was not classified as TestClient-dependent", name)
		}
	}
	if classifyVanessaTool("connect_test_client") != vanessaToolConnect ||
		classifyVanessaTool("close_test_client") != vanessaToolDisconnect ||
		classifyVanessaTool("future_unknown_tool") != vanessaToolUnknown {
		t.Fatal("connection-control or unknown Vanessa classification is not fail-closed")
	}
}

func TestRuntimeVanessaEditorOnlyCallDoesNotStartTestClient(t *testing.T) {
	connectCalls := 0
	calls := map[string]int{}
	backend := newVanessaBackendObserved(t, "VanessaExt: Истина", []string{"TestClient подключен"}, "Окно: Главное", &connectCalls, calls)
	broker := &fakeBroker{info: &backendInfo{URL: backend.URL, TestClientProfile: "itl-ondemand", TestClientPort: 48151}}
	_, session := newFacadeSessionForFamily(t, "vanessa-ui", vanessaIntegrationTools(), broker, time.Minute, nil)

	result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "open_feature_file", Arguments: map[string]any{"filePath": "demo.feature"}})
	if err != nil || result.IsError {
		t.Fatalf("editor-only call failed: result=%#v err=%v", result, err)
	}
	if broker.testClientEnsureCount() != 0 || connectCalls != 0 || calls["open_feature_file"] != 1 {
		t.Fatalf("editor-only call started or connected TestClient: ensures=%d connects=%d calls=%#v", broker.testClientEnsureCount(), connectCalls, calls)
	}
}

func TestInteractiveVanessaProfileConnectsLoadsWithoutRunAndStaysOpen(t *testing.T) {
	connectCalls := 0
	calls := map[string]int{}
	backend := newVanessaBackendObserved(t, "VanessaExt: Истина", []string{"TestClient подключен"}, "Окно: Главное", &connectCalls, calls)
	broker := &fakeBroker{info: &backendInfo{
		URL: backend.URL, PID: 7001, Port: 9874,
		TestClientProfile: "itl-ondemand", TestClientPID: 7002, TestClientPort: 48151,
		TestClientState: testClientPortReady,
	}}
	rt, _ := newFacadeSessionForFamily(t, "vanessa-ui", vanessaIntegrationTools(), broker, time.Hour, nil)
	rt.suppressEvidence = true
	writeRuntimeMarker(t, rt, rt.instanceID)
	featurePath := filepath.Join(rt.projectRoot, "tests", "features", "profile.feature")
	if err := os.MkdirAll(filepath.Dir(featurePath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(featurePath, []byte("Feature: Profile\nScenario: Manual\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	result, err := startInteractiveVanessaProfile(context.Background(), rt, featurePath)
	if err != nil {
		t.Fatal(err)
	}
	if result.TestClientState != testClientManagerConnected || result.ScenarioWasStarted {
		t.Fatalf("unexpected interactive state: %#v", result)
	}
	if calls["connect_test_client"] != 1 || calls["open_feature_file"] != 1 || calls["run_scenario"] != 0 {
		t.Fatalf("interactive profile used unexpected tools: %#v", calls)
	}
	if broker.testClientEnsureCount() != 1 {
		t.Fatalf("managed TestClient preflight count=%d", broker.testClientEnsureCount())
	}
	if _, stops := broker.counts(); stops != 0 {
		t.Fatalf("interactive profile performed automatic cleanup: %d", stops)
	}
	evidenceRoot := filepath.Join(rt.projectRoot, ".agent-1c", "mcp", "ondemand", "vanessa-ui")
	if matches, _ := filepath.Glob(filepath.Join(evidenceRoot, "*.evidence.jsonl")); len(matches) != 0 {
		t.Fatalf("interactive profile wrote evidence verdicts: %#v", matches)
	}
}

func TestRuntimeVanessaAutoConnectsRuntimeToolAndRecordsLifecycle(t *testing.T) {
	connectCalls := 0
	calls := map[string]int{}
	backend := newVanessaBackendObserved(t, "VanessaExt: Истина", []string{"TestClient подключен"}, "Окно: Главное", &connectCalls, calls)
	broker := &fakeBroker{info: &backendInfo{
		URL: backend.URL, TestClientProfile: "itl-ondemand", TestClientPort: 48151,
		PreviousTestClientPID: 707, PreviousTestClientState: testClientExited,
	}}
	rt, session := newFacadeSessionForFamily(t, "vanessa-ui", vanessaIntegrationTools(), broker, time.Minute, nil)

	result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "run_scenario", Arguments: map[string]any{}})
	if err != nil || result.IsError {
		t.Fatalf("runtime call failed: result=%#v err=%v", result, err)
	}
	if broker.testClientEnsureCount() != 1 || connectCalls != 1 || calls["run_scenario"] != 1 {
		t.Fatalf("unexpected runtime preflight calls: ensures=%d connects=%d calls=%#v", broker.testClientEnsureCount(), connectCalls, calls)
	}
	meta, _ := result.Meta["itlTestClient"].(map[string]any)
	if meta["state"] != testClientManagerConnected {
		t.Fatalf("logical connection metadata was not attached: %#v", result.Meta)
	}

	closed, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "close_test_client", Arguments: map[string]any{}})
	if err != nil || closed.IsError {
		t.Fatalf("close_test_client failed: result=%#v err=%v", closed, err)
	}
	if broker.testClientEnsureCount() != 1 {
		t.Fatalf("close_test_client started another TestClient: %d", broker.testClientEnsureCount())
	}
	closeMeta, _ := closed.Meta["itlTestClient"].(map[string]any)
	if closeMeta["state"] != testClientDisconnected {
		t.Fatalf("disconnect metadata missing: %#v", closed.Meta)
	}

	lifecyclePath := filepath.Join(rt.projectRoot, ".agent-1c", "mcp", "ondemand", "vanessa-ui", rt.instanceID+".testclient-lifecycle.jsonl")
	raw, err := os.ReadFile(lifecyclePath)
	if err != nil {
		t.Fatal(err)
	}
	for _, state := range []string{testClientExited, testClientProcessStarted, testClientPortReady, testClientManagerConnected, testClientDisconnected} {
		if !strings.Contains(string(raw), `"state":"`+state+`"`) {
			t.Fatalf("lifecycle state %q missing: %s", state, raw)
		}
	}
}

func TestRuntimeVanessaLicenseLimitDoesNotCallConnectOrRuntimeTool(t *testing.T) {
	connectCalls := 0
	calls := map[string]int{}
	backend := newVanessaBackendObserved(t, "VanessaExt: Истина", []string{"TestClient подключен"}, "Окно: Главное", &connectCalls, calls)
	broker := &fakeBroker{
		info:          &backendInfo{URL: backend.URL, TestClientProfile: "itl-ondemand", TestClientPort: 48151},
		testClientErr: fmt.Errorf("ITL_VANESSA_LICENSE_LIMIT: capacity=2 active=2"),
	}
	_, session := newFacadeSessionForFamily(t, "vanessa-ui", vanessaIntegrationTools(), broker, time.Minute, nil)

	result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "run_scenario", Arguments: map[string]any{}})
	if err != nil {
		t.Fatal(err)
	}
	assertToolErrorCode(t, result, "ITL_VANESSA_LICENSE_LIMIT")
	if connectCalls != 0 || calls["run_scenario"] != 0 {
		t.Fatalf("license-limited preflight reached backend runtime: connects=%d calls=%#v", connectCalls, calls)
	}
}

func TestRuntimeVanessaFailsClosedWhenConnectionStateIsNotProvable(t *testing.T) {
	connectCalls := 0
	calls := map[string]int{}
	backend := newVanessaBackendObserved(t, "VanessaExt: Истина", []string{"TestClient подключен"}, "Состояние клиента неизвестно", &connectCalls, calls)
	broker := &fakeBroker{info: &backendInfo{URL: backend.URL, TestClientProfile: "itl-ondemand", TestClientPort: 48151}}
	rt, session := newFacadeSessionForFamily(t, "vanessa-ui", vanessaIntegrationTools(), broker, time.Minute, nil)

	result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "run_scenario", Arguments: map[string]any{}})
	if err != nil {
		t.Fatal(err)
	}
	assertToolErrorCode(t, result, "ITL_VANESSA_TESTCLIENT_CONNECTION_STATE_UNAVAILABLE")
	if calls["run_scenario"] != 0 {
		t.Fatalf("runtime tool ran without connection proof: %#v", calls)
	}
	lifecyclePath := filepath.Join(rt.projectRoot, ".agent-1c", "mcp", "ondemand", "vanessa-ui", rt.instanceID+".testclient-lifecycle.jsonl")
	raw, err := os.ReadFile(lifecyclePath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), `"state":"connection-failed"`) {
		t.Fatalf("connection failure lifecycle evidence missing: %s", raw)
	}
}

func TestRuntimeVanessaReturnsNotConnectedAndSkipsRuntimeTool(t *testing.T) {
	connectCalls := 0
	calls := map[string]int{}
	backend := newVanessaBackendObserved(t, "VanessaExt: Истина", []string{"TestClient подключен"}, "TestClient не подключен", &connectCalls, calls)
	broker := &fakeBroker{info: &backendInfo{URL: backend.URL, TestClientProfile: "itl-ondemand", TestClientPort: 48151}}
	_, session := newFacadeSessionForFamily(t, "vanessa-ui", vanessaIntegrationTools(), broker, time.Minute, nil)

	result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "run_scenario", Arguments: map[string]any{}})
	if err != nil {
		t.Fatal(err)
	}
	assertToolErrorCode(t, result, "ITL_VANESSA_TESTCLIENT_NOT_CONNECTED")
	if calls["run_scenario"] != 0 {
		t.Fatalf("runtime tool ran while disconnected: %#v", calls)
	}
}

func TestRuntimeVanessaRejectsUnmanagedProfileBeforeUpstreamCall(t *testing.T) {
	connectCalls := 0
	backend := newVanessaBackend(t, "VanessaExt: Истина", "connected", "window", &connectCalls)
	broker := &fakeBroker{info: &backendInfo{URL: backend.URL, TestClientProfile: "itl-ondemand", TestClientPort: 48151}}
	_, session := newFacadeSessionForFamily(t, "vanessa-ui", vanessaIntegrationTools(), broker, time.Minute, nil)

	result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "connect_test_client", Arguments: map[string]any{"profileName": "custom"}})
	if err != nil {
		t.Fatal(err)
	}
	assertToolErrorCode(t, result, "ITL_VANESSA_MANAGED_PROFILE_REQUIRED")
	if connectCalls != 0 {
		t.Fatalf("unmanaged profile reached upstream: %d", connectCalls)
	}
}

func TestGatewayForwardsVanessaFileArgumentsWithoutRenamingOrNormalization(t *testing.T) {
	tools := vanessaIntegrationTools()
	type recordedCall struct {
		name      string
		arguments map[string]any
	}
	var calls []recordedCall
	server := mcp.NewServer(&mcp.Implementation{Name: "fake-vanessa", Version: "1"}, nil)
	for _, definition := range tools {
		tool := definition
		server.AddTool(tool, func(_ context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			var arguments map[string]any
			if err := json.Unmarshal(req.Params.Arguments, &arguments); err != nil {
				t.Fatalf("decode %s arguments: %v", tool.Name, err)
			}
			if tool.Name == "open_feature_file" || tool.Name == "check_syntax" || tool.Name == "load_features" {
				calls = append(calls, recordedCall{name: tool.Name, arguments: arguments})
			}
			text := tool.Name
			if tool.Name == "get_environment_data" {
				text = "VanessaExt: Истина"
			}
			return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: text}}}, nil
		})
	}
	backend := httptest.NewServer(mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server { return server }, nil))
	t.Cleanup(backend.Close)
	broker := &fakeBroker{info: &backendInfo{URL: backend.URL, BackendVersion: "test"}}
	_, session := newGatewayFacadeSession(t, "vanessa-ui", tools, broker, nil)

	featurePath := `D:\Git\PM5 КОРП - work 1-perf1\tests\features\Проверка пути.feature`
	for _, call := range []struct {
		name string
		key  string
	}{
		{name: "open_feature_file", key: "filePath"},
		{name: "load_features", key: "path"},
		{name: "check_syntax", key: "filePath"},
	} {
		result, err := session.CallTool(context.Background(), &mcp.CallToolParams{
			Name: gatewayCallTool,
			Arguments: map[string]any{
				"name":      call.name,
				"arguments": map[string]any{call.key: featurePath},
			},
		})
		if err != nil {
			t.Fatal(err)
		}
		if result.IsError {
			t.Fatalf("%s returned tool error: %#v", call.name, result.StructuredContent)
		}
	}

	if len(calls) != 3 {
		t.Fatalf("recorded %d file calls: %#v", len(calls), calls)
	}
	for index, expected := range []struct {
		name string
		key  string
	}{
		{name: "open_feature_file", key: "filePath"},
		{name: "load_features", key: "path"},
		{name: "check_syntax", key: "filePath"},
	} {
		got := calls[index]
		if got.name != expected.name || len(got.arguments) != 1 || got.arguments[expected.key] != featurePath {
			t.Fatalf("call %d changed the Vanessa file contract: %#v", index, got)
		}
	}
}

func TestRuntimeVanessaRejectsFalseSuccessfulConnection(t *testing.T) {
	connectCalls := 0
	backend := newVanessaBackend(t, "VanessaExt: Истина", "Не удалось подключить TestClient", "TestClient НЕ подключен", &connectCalls)
	broker := &fakeBroker{info: &backendInfo{URL: backend.URL, TestClientProfile: "itl-ondemand", TestClientPort: 48151}}
	_, session := newFacadeSessionForFamily(t, "vanessa-ui", vanessaIntegrationTools(), broker, time.Minute, nil)

	result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "connect_test_client", Arguments: map[string]any{"profileName": "itl-ondemand"}})
	if err != nil {
		t.Fatal(err)
	}
	assertToolErrorCode(t, result, "ITL_VANESSA_TESTCLIENT_CONNECT_FAILED")
	if connectCalls != 1 {
		t.Fatalf("connect call count=%d", connectCalls)
	}
}

func TestRuntimeVanessaRetriesManagedConnectionUntilPostcondition(t *testing.T) {
	connectCalls := 0
	backend := newVanessaBackendSequence(t, "VanessaExt: Истина", []string{"Не удалось подключить TestClient", "TestClient подключен"}, "Окно: Главное", &connectCalls)
	broker := &fakeBroker{info: &backendInfo{URL: backend.URL, TestClientProfile: "itl-ondemand", TestClientPort: 48151}}
	rt, session := newFacadeSessionForFamily(t, "vanessa-ui", vanessaIntegrationTools(), broker, time.Minute, nil)
	rt.vanessaConnectWait = 2 * time.Second

	result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "connect_test_client", Arguments: map[string]any{"profileName": "itl-ondemand"}})
	if err != nil {
		t.Fatal(err)
	}
	if result.IsError {
		t.Fatalf("managed connection was not retried: %#v", result.StructuredContent)
	}
	if connectCalls != 2 {
		t.Fatalf("connect call count=%d", connectCalls)
	}
}

func TestRuntimeVanessaWritesEvidenceOnlyAfterConnectionPostcondition(t *testing.T) {
	connectCalls := 0
	backend := newVanessaBackend(t, "VanessaExt: Истина", "TestClient подключен", "Окно: Главное", &connectCalls)
	broker := &fakeBroker{info: &backendInfo{URL: backend.URL, BackendVersion: "test", TestClientProfile: "itl-ondemand", TestClientPort: 48151}}
	rt, session := newFacadeSessionForFamily(t, "vanessa-ui", vanessaIntegrationTools(), broker, time.Minute, nil)

	result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "connect_test_client", Arguments: map[string]any{"profileName": "itl-ondemand"}})
	if err != nil {
		t.Fatal(err)
	}
	if result.IsError {
		t.Fatalf("valid managed connection failed: %#v", result.StructuredContent)
	}
	evidencePath := filepath.Join(rt.projectRoot, ".agent-1c", "mcp", "ondemand", "vanessa-ui", rt.instanceID+".evidence.jsonl")
	raw, err := os.ReadFile(evidencePath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), `"tool":"connect_test_client"`) {
		t.Fatalf("connection evidence missing: %s", raw)
	}
	if strings.Contains(string(raw), "TestClient подключен") {
		t.Fatalf("successful result content leaked into evidence: %s", raw)
	}
}

func TestRuntimeVanessaSemanticFailureWritesBoundFailedEvidence(t *testing.T) {
	tools := vanessaIntegrationTools()
	server := mcp.NewServer(&mcp.Implementation{Name: "fake-vanessa", Version: "1"}, nil)
	for _, definition := range tools {
		tool := definition
		server.AddTool(tool, func(context.Context, *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			text := tool.Name
			if tool.Name == "get_environment_data" {
				text = "VanessaExt: true"
			}
			if tool.Name == "open_feature_file" {
				text = "Internal error: Ошибка при вызове конструктора (Файл)"
			}
			return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: text}}}, nil
		})
	}
	backend := httptest.NewServer(mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server { return server }, nil))
	t.Cleanup(backend.Close)
	broker := &fakeBroker{info: &backendInfo{URL: backend.URL, BackendVersion: "test", LogPath: "backend.log"}}
	rt, session := newFacadeSessionForFamily(t, "vanessa-ui", tools, broker, time.Minute, nil)
	featurePath := filepath.Join(rt.projectRoot, "tests", "features", "demo.feature")
	if err := os.MkdirAll(filepath.Dir(featurePath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(featurePath, []byte("Feature: Demo\nScenario: Check\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "open_feature_file", Arguments: map[string]any{"filePath": featurePath}})
	if err != nil {
		t.Fatal(err)
	}
	assertToolErrorCode(t, result, "ITL_VANESSA_TOOL_RESULT_FAILED")

	evidencePath := filepath.Join(rt.projectRoot, ".agent-1c", "mcp", "ondemand", "vanessa-ui", rt.instanceID+".evidence.jsonl")
	raw, err := os.ReadFile(evidencePath)
	if err != nil {
		t.Fatal(err)
	}
	var evidence map[string]any
	if err := json.Unmarshal(bytes.TrimSpace(raw), &evidence); err != nil {
		t.Fatal(err)
	}
	if evidence["schemaVersion"] != float64(2) || evidence["outcome"] != "failed" || evidence["resultCode"] != "ITL_VANESSA_TOOL_RESULT_FAILED" {
		t.Fatalf("unexpected failure evidence: %#v", evidence)
	}
	if evidence["resultMessage"] != "Vanessa returned a runtime/editor failure" || evidence["logPath"] != "backend.log" {
		t.Fatalf("safe runner error details were not persisted: %#v", evidence)
	}
	if evidence["featurePath"] != "tests/features/demo.feature" || len(evidence["featureSha256"].(string)) != 64 || len(evidence["argumentsSha256"].(string)) != 64 {
		t.Fatalf("failure evidence was not feature-bound: %#v", evidence)
	}
}

func TestResultEvidenceMessageRedactsSecretsAndTruncates(t *testing.T) {
	message := resultEvidenceMessage(toolError(
		"ITL_ONDEMAND_BACKEND_CALL_FAILED",
		`Internal error password=super-secret Bearer abc.def https://user:pass@example.invalid?token=query-secret config={"server":"internal","user":"admin"} `+strings.Repeat("x", 300),
		nil,
	), nil)
	if strings.Contains(message, "super-secret") || strings.Contains(message, "abc.def") || strings.Contains(message, "user:pass") || strings.Contains(message, "query-secret") || strings.Contains(message, "internal") || strings.Contains(message, "admin") {
		t.Fatalf("safe evidence message leaked a secret: %q", message)
	}
	if !strings.Contains(message, "password=[redacted]") || !strings.Contains(message, "Bearer [redacted]") || !strings.Contains(message, "[configuration redacted]") || len([]rune(message)) > 240 {
		t.Fatalf("safe evidence message was not redacted or bounded: %q", message)
	}
}

func assertToolErrorCode(t *testing.T, result *mcp.CallToolResult, expected string) {
	t.Helper()
	if result == nil || !result.IsError {
		t.Fatalf("expected %s tool error, got %#v", expected, result)
	}
	structured, ok := result.StructuredContent.(map[string]any)
	if !ok || structured["code"] != expected {
		t.Fatalf("expected %s, got %#v", expected, result.StructuredContent)
	}
}

func TestRuntimeIdleTimeoutStartsAfterLastConcurrentCall(t *testing.T) {
	tools := []*mcp.Tool{{Name: "wait", InputSchema: map[string]any{"type": "object"}}}
	release := make(chan struct{})
	var releaseOnce sync.Once
	releaseCalls := func() {
		releaseOnce.Do(func() { close(release) })
	}
	entered := make(chan struct{}, 2)
	backendServer := mcp.NewServer(&mcp.Implementation{Name: "idle-backend", Version: "1"}, nil)
	backendServer.AddTool(tools[0], func(ctx context.Context, _ *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		entered <- struct{}{}
		select {
		case <-release:
			return &mcp.CallToolResult{}, nil
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	})
	httpServer := httptest.NewServer(mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server { return backendServer }, nil))
	t.Cleanup(httpServer.Close)
	broker := &fakeBroker{info: &backendInfo{URL: httpServer.URL}}
	_, session := newFacadeSession(t, tools, broker, 40*time.Millisecond, nil)
	callCtx, cancelCalls := context.WithTimeout(context.Background(), 3*time.Second)
	t.Cleanup(func() {
		cancelCalls()
		releaseCalls()
	})
	done := make(chan error, 2)
	for range 2 {
		go func() {
			_, err := session.CallTool(callCtx, &mcp.CallToolParams{Name: "wait", Arguments: map[string]any{}})
			done <- err
		}()
	}
	for range 2 {
		select {
		case <-entered:
		case <-callCtx.Done():
			t.Fatalf("concurrent backend calls did not both start: %v", callCtx.Err())
		}
	}
	select {
	case <-time.After(80 * time.Millisecond):
	case <-callCtx.Done():
		t.Fatalf("concurrent calls did not remain active through the idle interval: %v", callCtx.Err())
	}
	if _, stops := broker.counts(); stops != 0 {
		t.Fatalf("backend stopped with active calls: %d", stops)
	}
	releaseCalls()
	for range 2 {
		select {
		case err := <-done:
			if err != nil {
				t.Fatalf("concurrent facade call failed: %v", err)
			}
		case <-callCtx.Done():
			t.Fatalf("concurrent facade call did not return after release: %v", callCtx.Err())
		}
	}
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			if _, stops := broker.counts(); stops == 1 {
				return
			}
		case <-callCtx.Done():
			_, stops := broker.counts()
			t.Fatalf("backend was not stopped after last call became idle: stops=%d err=%v", stops, callCtx.Err())
		}
	}
}

func TestRuntimeToolsListChangedInvalidatesSession(t *testing.T) {
	tools := integrationTools()
	backendServer, backend := newBackend(t, tools, false)
	broker := &fakeBroker{info: &backendInfo{URL: backend.URL}}
	_, session := newFacadeSession(t, tools, broker, time.Minute, nil)
	if _, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "echo", Arguments: map[string]any{"value": "x"}}); err != nil {
		t.Fatal(err)
	}
	backendServer.RemoveTools("second")
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if _, stops := broker.counts(); stops >= 1 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "echo", Arguments: map[string]any{"value": "x"}})
	if err != nil {
		t.Fatal(err)
	}
	if !result.IsError {
		t.Fatal("changed catalog was accepted")
	}
}

func TestRuntimeForwardsCancellationToBackend(t *testing.T) {
	tools := []*mcp.Tool{{Name: "wait", InputSchema: map[string]any{"type": "object"}}}
	entered := make(chan struct{})
	cancelled := make(chan struct{})
	backendServer := mcp.NewServer(&mcp.Implementation{Name: "cancel-backend", Version: "1"}, nil)
	backendServer.AddTool(tools[0], func(ctx context.Context, _ *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		close(entered)
		<-ctx.Done()
		close(cancelled)
		return nil, ctx.Err()
	})
	httpServer := httptest.NewServer(mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server { return backendServer }, nil))
	t.Cleanup(httpServer.Close)
	broker := &fakeBroker{info: &backendInfo{URL: httpServer.URL}}
	_, session := newFacadeSession(t, tools, broker, time.Minute, nil)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		_, _ = session.CallTool(ctx, &mcp.CallToolParams{Name: "wait", Arguments: map[string]any{}})
		close(done)
	}()
	select {
	case <-entered:
	case <-time.After(2 * time.Second):
		t.Fatal("backend call did not start")
	}
	cancel()
	select {
	case <-cancelled:
	case <-time.After(2 * time.Second):
		t.Fatal("backend context was not cancelled")
	}
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("facade call did not return after cancellation")
	}
}
