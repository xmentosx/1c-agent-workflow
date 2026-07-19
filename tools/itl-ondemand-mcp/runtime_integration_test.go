package main

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type fakeBroker struct {
	mu      sync.Mutex
	info    *backendInfo
	ensures int
	stops   int
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
	t.Helper()
	rt := &runtime{
		catalog: &loadedCatalog{SHA256: "catalog", Data: catalogFile{SchemaVersion: 1, Family: "roctup", Tools: tools}},
		broker:  broker, projectRoot: t.TempDir(), family: "roctup", instanceID: "0123456789abcdef0123456789abcdef",
		idle: idle, logger: slog.New(slog.NewTextHandler(os.Stderr, nil)), progress: make(map[string]*mcp.ServerSession),
	}
	server := mcp.NewServer(&mcp.Implementation{Name: "itl-roctup-data", Version: version}, nil)
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
