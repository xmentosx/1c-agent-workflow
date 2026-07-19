package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type runtime struct {
	mu          sync.Mutex
	catalog     *loadedCatalog
	broker      backendBroker
	projectRoot string
	family      string
	instanceID  string
	idle        time.Duration
	catalogWait time.Duration
	logger      *slog.Logger
	progressMu  sync.Mutex
	progress    map[string]*mcp.ServerSession

	backend  *backendInfo
	session  *mcp.ClientSession
	timer    *time.Timer
	active   int
	mismatch *catalogDiff
	closed   bool
}

func (r *runtime) call(ctx context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
	// Calls, including lazy ensure/start, hold a shared lease. Lifecycle writers
	// acquire lifecycle -> runtime exclusively and therefore wait for the whole
	// operation without requiring a client reload.
	lock, err := acquireRuntimeReadLock(filepath.Join(r.projectRoot, ".agent-1c", "locks", "runtime-mcp.lock"))
	if err != nil {
		return toolError("ITL_ONDEMAND_RUNTIME_LOCK", err.Error(), nil), nil
	}
	defer lock.Close()

	r.mu.Lock()
	if r.timer != nil {
		r.timer.Stop()
	}
	if r.mismatch != nil {
		diff := r.mismatch
		r.mu.Unlock()
		return toolError("ITL_ONDEMAND_CATALOG_MISMATCH", "backend tool catalog changed", diff), nil
	}
	if r.session != nil && r.backend != nil && r.backend.PID > 0 {
		statePath := filepath.Join(r.projectRoot, ".agent-1c", "mcp", "ondemand", r.family, r.instanceID+".json")
		if _, statErr := os.Stat(statePath); os.IsNotExist(statErr) {
			_ = r.session.Close()
			r.session = nil
			r.backend = nil
		}
	}
	if err := r.ensureLocked(ctx); err != nil {
		diff := r.mismatch
		r.mu.Unlock()
		if diff != nil {
			return toolError("ITL_ONDEMAND_CATALOG_MISMATCH", "backend tool catalog changed", diff), nil
		}
		if strings.Contains(err.Error(), "ITL_ONDEMAND_BACKEND_VERSION_MISMATCH") {
			return toolError("ITL_ONDEMAND_BACKEND_VERSION_MISMATCH", err.Error(), nil), nil
		}
		return toolError("ITL_ONDEMAND_START_FAILED", err.Error(), nil), nil
	}
	if r.mismatch != nil {
		diff := r.mismatch
		r.mu.Unlock()
		return toolError("ITL_ONDEMAND_CATALOG_MISMATCH", "backend tool catalog changed", diff), nil
	}
	session := r.session
	r.active++
	r.mu.Unlock()

	arguments := any(map[string]any{})
	if len(req.Params.Arguments) > 0 {
		if err := json.Unmarshal(req.Params.Arguments, &arguments); err != nil {
			return toolError("ITL_ONDEMAND_ARGUMENTS_INVALID", err.Error(), nil), nil
		}
	}
	params := &mcp.CallToolParams{Name: req.Params.Name, Arguments: arguments, Meta: req.Params.Meta}
	progressKey := progressTokenKey(req.Params.GetProgressToken())
	if progressKey != "" {
		r.progressMu.Lock()
		r.progress[progressKey] = req.Session
		r.progressMu.Unlock()
		defer func() {
			r.progressMu.Lock()
			delete(r.progress, progressKey)
			r.progressMu.Unlock()
		}()
	}
	result, err := session.CallTool(ctx, params)

	r.mu.Lock()
	r.active--
	if err == nil && result != nil && !result.IsError {
		r.writeEvidenceLocked(req.Params.Name)
	}
	if r.active == 0 {
		r.armIdleLocked()
	}
	r.mu.Unlock()
	if err != nil {
		return toolError("ITL_ONDEMAND_BACKEND_CALL_FAILED", err.Error(), nil), nil
	}
	return result, nil
}

func (r *runtime) ensureLocked(ctx context.Context) error {
	if r.closed {
		return fmt.Errorf("gateway is closed")
	}
	if r.session != nil {
		return nil
	}
	info, err := r.broker.Ensure(ctx)
	if err != nil {
		return err
	}
	if info.URL == "" {
		return fmt.Errorf("backend broker returned an empty URL")
	}
	if err := validateBackendVersion(r.family, r.catalog.Data.BackendVersions, info.BackendVersion); err != nil {
		_ = r.broker.Stop(context.Background())
		return err
	}
	r.backend = info
	client := mcp.NewClient(&mcp.Implementation{Name: "itl-ondemand-mcp", Version: version}, &mcp.ClientOptions{
		Capabilities: &mcp.ClientCapabilities{},
		ProgressNotificationHandler: func(ctx context.Context, req *mcp.ProgressNotificationClientRequest) {
			r.forwardProgress(ctx, req.Params)
		},
		ToolListChangedHandler: func(ctx context.Context, _ *mcp.ToolListChangedRequest) {
			r.revalidate(ctx)
		},
	})
	transport := &mcp.StreamableClientTransport{
		Endpoint:   info.URL,
		HTTPClient: &http.Client{Timeout: 10 * time.Minute},
		MaxRetries: 2,
	}
	session, err := client.Connect(ctx, transport, nil)
	if err != nil {
		_ = r.broker.Stop(context.Background())
		return fmt.Errorf("connect backend MCP: %w", err)
	}
	_, diff, err := r.waitForCatalog(ctx, session)
	if err != nil {
		_ = session.Close()
		_ = r.broker.Stop(context.Background())
		return fmt.Errorf("list backend tools: %w", err)
	}
	if !diff.empty() {
		r.mismatch = diff
		_ = session.Close()
		_ = r.broker.Stop(context.Background())
		return fmt.Errorf("ITL_ONDEMAND_CATALOG_MISMATCH: added=%v removed=%v changed=%v", diff.Added, diff.Removed, diff.Changed)
	}
	r.session = session
	r.mismatch = nil
	return nil
}

func (r *runtime) waitForCatalog(ctx context.Context, session *mcp.ClientSession) ([]*mcp.Tool, *catalogDiff, error) {
	deadline := time.Now().Add(r.catalogWait)
	for {
		actual, err := listAllTools(ctx, session)
		if err != nil {
			return nil, nil, err
		}
		diff, err := compareTools(r.catalog.Data.Tools, actual)
		if err != nil {
			return nil, nil, err
		}
		if diff.empty() || r.catalogWait <= 0 || !time.Now().Before(deadline) {
			return actual, diff, nil
		}
		timer := time.NewTimer(250 * time.Millisecond)
		select {
		case <-ctx.Done():
			timer.Stop()
			return nil, nil, ctx.Err()
		case <-timer.C:
		}
	}
}

func validateBackendVersion(family string, expected any, actual string) error {
	if expected == nil {
		return nil
	}
	raw, err := json.Marshal(expected)
	if err != nil {
		return err
	}
	versions := map[string]string{}
	if err := json.Unmarshal(raw, &versions); err != nil {
		return fmt.Errorf("decode catalog backend versions: %w", err)
	}
	want := versions["roctup"]
	if family == "vanessa-ui" {
		want = "clientMcp=" + versions["clientMcp"] + ";vaExtension=" + versions["vaExtension"]
	}
	if want != "" && actual != want {
		return fmt.Errorf("ITL_ONDEMAND_BACKEND_VERSION_MISMATCH: expected %q, actual %q", want, actual)
	}
	return nil
}

func listAllTools(ctx context.Context, session *mcp.ClientSession) ([]*mcp.Tool, error) {
	var tools []*mcp.Tool
	cursor := ""
	for {
		result, err := session.ListTools(ctx, &mcp.ListToolsParams{Cursor: cursor})
		if err != nil {
			return nil, err
		}
		tools = append(tools, result.Tools...)
		if result.NextCursor == "" {
			break
		}
		cursor = result.NextCursor
	}
	sort.Slice(tools, func(i, j int) bool { return tools[i].Name < tools[j].Name })
	return tools, nil
}

func (r *runtime) revalidate(ctx context.Context) {
	r.mu.Lock()
	if r.session == nil {
		r.mu.Unlock()
		return
	}
	session := r.session
	r.mu.Unlock()
	tools, err := listAllTools(ctx, session)
	if err != nil {
		r.logger.Error("revalidate backend catalog", "error", err)
		return
	}
	diff, err := compareTools(r.catalog.Data.Tools, tools)
	if err != nil {
		r.logger.Error("compare backend catalog", "error", err)
		return
	}
	if !diff.empty() {
		r.mu.Lock()
		r.mismatch = diff
		r.mu.Unlock()
		go func() {
			cleanupCtx, cancel := context.WithTimeout(context.Background(), time.Minute)
			defer cancel()
			if err := r.stop(cleanupCtx); err != nil {
				r.logger.Error("stop incompatible backend", "error", err)
			}
		}()
	}
}

func progressTokenKey(token any) string {
	if token == nil {
		return ""
	}
	raw, err := json.Marshal(token)
	if err != nil {
		return fmt.Sprint(token)
	}
	return string(raw)
}

func (r *runtime) forwardProgress(ctx context.Context, params *mcp.ProgressNotificationParams) {
	key := progressTokenKey(params.ProgressToken)
	if key == "" {
		return
	}
	r.progressMu.Lock()
	session := r.progress[key]
	r.progressMu.Unlock()
	if session != nil {
		_ = session.NotifyProgress(ctx, params)
	}
}

func (r *runtime) armIdleLocked() {
	if r.idle <= 0 || r.closed {
		return
	}
	r.timer = time.AfterFunc(r.idle, func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
		defer cancel()
		if err := r.stop(ctx); err != nil {
			r.logger.Error("idle backend cleanup", "error", err)
		}
	})
}

func (r *runtime) stop(ctx context.Context) error {
	lock, err := acquireRuntimeReadLock(filepath.Join(r.projectRoot, ".agent-1c", "locks", "runtime-mcp.lock"))
	if err != nil {
		return err
	}
	defer lock.Close()
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.timer != nil {
		r.timer.Stop()
		r.timer = nil
	}
	if r.session != nil {
		_ = r.session.Close()
		r.session = nil
	}
	if r.backend == nil {
		return nil
	}
	err = r.broker.Stop(ctx)
	r.backend = nil
	return err
}

func (r *runtime) close(ctx context.Context) error {
	r.mu.Lock()
	r.closed = true
	r.mu.Unlock()
	return r.stop(ctx)
}

func (r *runtime) writeEvidenceLocked(toolName string) {
	if r.backend == nil {
		return
	}
	directory := filepath.Join(r.projectRoot, ".agent-1c", "mcp", "ondemand", r.family)
	if err := os.MkdirAll(directory, 0o755); err != nil {
		r.logger.Error("create evidence directory", "error", err)
		return
	}
	entry := map[string]any{
		"schemaVersion": 1, "family": r.family, "instanceId": r.instanceID,
		"backendVersion": r.backend.BackendVersion, "catalogSha256": r.catalog.SHA256,
		"tool": toolName, "succeededAt": time.Now().UTC().Format(time.RFC3339Nano),
	}
	raw, _ := json.Marshal(entry)
	path := filepath.Join(directory, r.instanceID+".evidence.jsonl")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err == nil {
		_, _ = file.Write(append(raw, '\n'))
		_ = file.Close()
	}
}

func toolError(code, message string, details any) *mcp.CallToolResult {
	structured := map[string]any{"code": code, "message": message}
	if details != nil {
		structured["details"] = details
	}
	return &mcp.CallToolResult{
		IsError:           true,
		Content:           []mcp.Content{&mcp.TextContent{Text: code + ": " + message}},
		StructuredContent: structured,
	}
}
