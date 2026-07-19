package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type fakeBroker struct {
	mu           sync.Mutex
	info         *backendInfo
	ensures      int
	stops        int
	stopFailures int
}

func (b *fakeBroker) Ensure(context.Context) (*backendInfo, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.ensures++
	copy := *b.info
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

func boolPointer(value bool) *bool { return &value }

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
	t.Helper()
	server := mcp.NewServer(&mcp.Implementation{Name: "fake-backend", Version: "1"}, &mcp.ServerOptions{PageSize: 1})
	for _, definition := range tools {
		tool := definition
		server.AddTool(tool, func(ctx context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
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

func vanessaIntegrationTools() []*mcp.Tool {
	object := map[string]any{"type": "object"}
	return []*mcp.Tool{
		{Name: "get_environment_data", InputSchema: object},
		{Name: "connect_test_client", InputSchema: map[string]any{"type": "object", "properties": map[string]any{"profileName": map[string]any{"type": "string"}}}},
		{Name: "get_window_list_testclient", InputSchema: object},
		{Name: "manage_test_client_profiles", InputSchema: object},
	}
}

func newVanessaBackend(t *testing.T, environmentText, connectText, postText string, connectCalls *int) *httptest.Server {
	return newVanessaBackendSequence(t, environmentText, []string{connectText}, postText, connectCalls)
}

func newVanessaBackendSequence(t *testing.T, environmentText string, connectTexts []string, postText string, connectCalls *int) *httptest.Server {
	t.Helper()
	server := mcp.NewServer(&mcp.Implementation{Name: "fake-vanessa", Version: "1"}, nil)
	for _, definition := range vanessaIntegrationTools() {
		tool := definition
		server.AddTool(tool, func(context.Context, *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
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
	done := make(chan struct{}, 2)
	for range 2 {
		go func() {
			_, _ = session.CallTool(context.Background(), &mcp.CallToolParams{Name: "wait", Arguments: map[string]any{}})
			done <- struct{}{}
		}()
	}
	for range 2 {
		<-entered
	}
	time.Sleep(80 * time.Millisecond)
	if _, stops := broker.counts(); stops != 0 {
		t.Fatalf("backend stopped with active calls: %d", stops)
	}
	close(release)
	for range 2 {
		<-done
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if _, stops := broker.counts(); stops == 1 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("backend was not stopped after last call became idle")
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
