package main

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func awaitProgressEvidence(t *testing.T, path string, count int) []map[string]any {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		raw, _ := os.ReadFile(path)
		var events []map[string]any
		for _, line := range bytes.Split(bytes.TrimSpace(raw), []byte{'\n'}) {
			var event map[string]any
			if json.Unmarshal(line, &event) == nil {
				events = append(events, event)
			}
		}
		if len(events) >= count {
			return events
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("missing asynchronous progress evidence: %s", path)
	return nil
}

func TestProgressAfterResponseIsRecordedAndReusedCallerTokenIsIsolated(t *testing.T) {
	tools := integrationTools()
	server, backend := newBackend(t, tools, false)
	release := make(chan struct{})
	var once sync.Once
	t.Cleanup(func() { once.Do(func() { close(release) }) })
	var calls atomic.Int32
	server.AddTool(tools[0], func(ctx context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		params := &mcp.ProgressNotificationParams{ProgressToken: req.Params.GetProgressToken(), Progress: 1, Total: 1, Message: "forwarded"}
		if calls.Add(1) == 1 {
			go func() { <-release; _ = req.Session.NotifyProgress(context.Background(), params) }()
		} else {
			_ = req.Session.NotifyProgress(ctx, params)
		}
		return &mcp.CallToolResult{StructuredContent: map[string]any{"value": "echo"}}, nil
	})
	broker := &fakeBroker{info: &backendInfo{URL: backend.URL, BackendVersion: "test"}}
	progress := make(chan *mcp.ProgressNotificationParams, 2)
	rt, session := newFacadeSession(t, tools, broker, time.Minute, progress)
	for i := 0; i < 2; i++ {
		result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "echo", Arguments: map[string]any{"value": "x"}, Meta: mcp.Meta{"progressToken": "same-caller-token"}})
		if err != nil || result.IsError {
			t.Fatalf("call %d: %#v, %v", i, result, err)
		}
	}
	once.Do(func() { close(release) })
	for i := 0; i < 2; i++ {
		select {
		case params := <-progress:
			if params.ProgressToken != "same-caller-token" {
				t.Fatalf("internal token escaped to caller: %#v", params)
			}
		case <-time.After(2 * time.Second):
			t.Fatal("late progress was dropped")
		}
	}
	path := filepath.Join(rt.projectRoot, ".agent-1c", "mcp", "ondemand", "roctup", rt.instanceID+".progress.jsonl")
	events := awaitProgressEvidence(t, path, 2)
	if events[0]["progressEvidenceId"] == events[1]["progressEvidenceId"] {
		t.Fatalf("two requests merged: %#v", events)
	}
	for _, event := range events {
		if event["forwardedCount"] != float64(1) || event["outcome"] != "progress-forwarded" {
			t.Fatalf("wrong progress evidence: %#v", event)
		}
	}
	if err := rt.stop(context.Background()); err != nil {
		t.Fatal(err)
	}
	rt.progressMu.Lock()
	defer rt.progressMu.Unlock()
	if len(rt.progress) != 0 {
		t.Fatal("closed backend retained progress routes")
	}
}
