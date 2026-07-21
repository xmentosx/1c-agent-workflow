package main

import (
	"context"
	"crypto/sha256"
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
	mu                 sync.Mutex
	catalog            *loadedCatalog
	broker             backendBroker
	projectRoot        string
	family             string
	instanceID         string
	idle               time.Duration
	catalogWait        time.Duration
	vanessaConnectWait time.Duration
	logger             *slog.Logger
	progressMu         sync.Mutex
	progress           map[string]*mcp.ServerSession

	backend           *backendInfo
	session           *mcp.ClientSession
	timer             *time.Timer
	active            int
	generation        uint64
	stopping          bool
	lastCallCompleted time.Time
	idleDeadline      time.Time
	mismatch          *catalogDiff
	closed            bool
	authoringFeature  string
	authoringLine     int
}

func (r *runtime) call(ctx context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
	arguments := any(map[string]any{})
	if len(req.Params.Arguments) > 0 {
		if err := json.Unmarshal(req.Params.Arguments, &arguments); err != nil {
			return toolError("ITL_ONDEMAND_ARGUMENTS_INVALID", err.Error(), nil), nil
		}
	}
	return r.callNamed(ctx, req, req.Params.Name, arguments)
}

func (r *runtime) callNamed(ctx context.Context, req *mcp.CallToolRequest, toolName string, arguments any) (*mcp.CallToolResult, error) {
	tool := r.catalog.tool(toolName)
	if tool == nil {
		return toolError("ITL_ONDEMAND_TOOL_UNKNOWN", "tool is not present in the verified compatibility catalog", map[string]any{"name": toolName, "repair": "Call resolve_tool with an exact name or short operation description."}), nil
	}
	if err := r.catalog.validate(toolName, arguments); err != nil {
		return toolError("ITL_ONDEMAND_ARGUMENTS_INVALID", err.Error(), map[string]any{
			"name": toolName, "inputSchema": tool.InputSchema,
			"repair": "Retry with only explicitly intended fields; omit absent optional fields.",
		}), nil
	}

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
		r.timer = nil
	}
	r.generation++
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
		for _, code := range []string{
			"ITL_ONDEMAND_BACKEND_VERSION_MISMATCH",
			"ITL_VANESSA_UNSAFE_ACTION_PROTECTION_UNCONFIRMED",
			"ITL_VANESSA_EXT_NOT_READY",
		} {
			if strings.Contains(err.Error(), code) {
				return toolError(code, err.Error(), nil), nil
			}
		}
		return toolError("ITL_ONDEMAND_START_FAILED", err.Error(), nil), nil
	}
	if r.mismatch != nil {
		diff := r.mismatch
		r.mu.Unlock()
		return toolError("ITL_ONDEMAND_CATALOG_MISMATCH", "backend tool catalog changed", diff), nil
	}
	if guarded := r.validateManagedVanessaRequest(arguments, toolName); guarded != nil {
		r.armIdleLocked()
		r.mu.Unlock()
		return guarded, nil
	}
	session := r.session
	r.active++
	r.mu.Unlock()

	params := &mcp.CallToolParams{Name: toolName, Arguments: arguments, Meta: req.Params.Meta}
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
	result, err := r.callUpstream(ctx, session, params)
	r.mu.Lock()
	r.active--
	outcome := "passed"
	resultCode := "ITL_OK"
	if err != nil {
		outcome = "failed"
		resultCode = "ITL_ONDEMAND_BACKEND_CALL_FAILED"
	} else if result == nil {
		outcome = "failed"
		resultCode = "ITL_ONDEMAND_EMPTY_RESULT"
	} else if result.IsError {
		outcome = "failed"
		resultCode = toolResultCode(result)
		if resultCode == "" {
			resultCode = "ITL_ONDEMAND_TOOL_ERROR"
		}
	}
	r.writeEvidenceLocked(toolName, arguments, outcome, resultCode)
	r.lastCallCompleted = time.Now()
	if r.active == 0 {
		r.armIdleLocked()
	}
	r.mu.Unlock()
	if err != nil {
		return toolError("ITL_ONDEMAND_BACKEND_CALL_FAILED", err.Error(), nil), nil
	}
	if result == nil {
		return toolError("ITL_ONDEMAND_EMPTY_RESULT", "backend returned no tool result", nil), nil
	}
	return result, nil
}

func (r *runtime) callUpstream(ctx context.Context, session *mcp.ClientSession, params *mcp.CallToolParams) (*mcp.CallToolResult, error) {
	deadline := time.Now().Add(r.vanessaConnectWait)
	for {
		result, err := session.CallTool(ctx, params)
		if err != nil || result == nil || result.IsError {
			return result, err
		}
		result = r.validateVanessaResult(ctx, params.Name, result, session)
		if r.family != "vanessa-ui" || params.Name != "connect_test_client" || r.vanessaConnectWait <= 0 || toolResultCode(result) != "ITL_VANESSA_TESTCLIENT_CONNECT_FAILED" || !time.Now().Before(deadline) {
			return result, nil
		}
		wait := 500 * time.Millisecond
		if remaining := time.Until(deadline); remaining < wait {
			wait = remaining
		}
		timer := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			timer.Stop()
			return nil, ctx.Err()
		case <-timer.C:
		}
	}
}

func toolResultCode(result *mcp.CallToolResult) string {
	if result == nil || !result.IsError {
		return ""
	}
	structured, ok := result.StructuredContent.(map[string]any)
	if !ok {
		return ""
	}
	code, _ := structured["code"].(string)
	return code
}

func (r *runtime) ensureLocked(ctx context.Context) error {
	if r.closed {
		return fmt.Errorf("gateway is closed")
	}
	if r.session != nil {
		return nil
	}
	r.logger.Info("ensure backend", "family", r.family, "instanceId", r.instanceID, "stage", "broker-start")
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
	r.logger.Info("ensure backend", "family", r.family, "instanceId", r.instanceID, "stage", "mcp-connect", "url", info.URL)
	client := mcp.NewClient(&mcp.Implementation{Name: "itl-ondemand-mcp", Version: version}, &mcp.ClientOptions{
		Capabilities: &mcp.ClientCapabilities{},
		ProgressNotificationHandler: func(ctx context.Context, req *mcp.ProgressNotificationClientRequest) {
			r.forwardProgress(ctx, req.Params)
		},
		ToolListChangedHandler: func(_ context.Context, _ *mcp.ToolListChangedRequest) {
			// A backend may announce its catalog while Connect still owns r.mu.
			// Notification handlers run on the MCP receive path, so waiting for that
			// mutex here deadlocks Connect and leaves the first tools/call hanging.
			go func() {
				ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
				defer cancel()
				r.revalidate(ctx)
			}()
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
	r.logger.Info("ensure backend", "family", r.family, "instanceId", r.instanceID, "stage", "catalog-verify")
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
	r.logger.Info("ensure backend", "family", r.family, "instanceId", r.instanceID, "stage", "preflight")
	if err := r.preflightVanessa(ctx, session); err != nil {
		r.session = nil
		_ = session.Close()
		_ = r.broker.Stop(context.Background())
		r.backend = nil
		return err
	}
	r.logger.Info("ensure backend", "family", r.family, "instanceId", r.instanceID, "stage", "ready")
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
		if versions["vanessaAutomation"] != "" || versions["vanessaExt"] != "" {
			want += ";vanessaAutomation=" + versions["vanessaAutomation"] + ";vanessaExt=" + versions["vanessaExt"]
		}
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
	generation := r.generation
	r.idleDeadline = time.Now().Add(r.idle)
	r.timer = time.AfterFunc(r.idle, func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
		defer cancel()
		if err := r.stopIdle(ctx, generation); err != nil {
			r.logger.Error("idle backend cleanup", "error", err)
		}
	})
}

func (r *runtime) stopIdle(ctx context.Context, generation uint64) error {
	lock, err := acquireRuntimeReadLock(filepath.Join(r.projectRoot, ".agent-1c", "locks", "runtime-mcp.lock"))
	if err != nil {
		return err
	}
	defer lock.Close()
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed || r.backend == nil || r.active > 0 || r.generation != generation {
		return nil
	}
	if time.Now().Before(r.idleDeadline) {
		r.armIdleLocked()
		return nil
	}
	r.stopping = true
	err = r.broker.Stop(ctx)
	r.stopping = false
	if err != nil {
		r.armIdleLocked()
		return err
	}
	if r.session != nil {
		_ = r.session.Close()
		r.session = nil
	}
	r.backend = nil
	r.timer = nil
	r.logger.Info("idle backend cleanup completed", "lastCallCompletedAt", r.lastCallCompleted, "reason", "idle")
	return nil
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
	if r.backend == nil {
		return nil
	}
	err = r.broker.Stop(ctx)
	if err != nil {
		return err
	}
	if r.session != nil {
		_ = r.session.Close()
		r.session = nil
	}
	r.backend = nil
	return nil
}

func (r *runtime) validateManagedVanessaRequest(arguments any, toolName string) *mcp.CallToolResult {
	if r.family != "vanessa-ui" || r.backend == nil {
		return nil
	}
	args, _ := arguments.(map[string]any)
	if toolName == "connect_test_client" {
		profile, _ := args["profileName"].(string)
		if profile != r.backend.TestClientProfile {
			return toolError("ITL_VANESSA_MANAGED_PROFILE_REQUIRED", "connect_test_client must use profileName=\""+r.backend.TestClientProfile+"\"", map[string]any{"profileName": r.backend.TestClientProfile, "testClientPort": r.backend.TestClientPort})
		}
	}
	if toolName == "manage_test_client_profiles" {
		action, _ := args["action"].(string)
		name, _ := args["name"].(string)
		if (action == "add" || action == "edit") && name == r.backend.TestClientProfile {
			return toolError("ITL_VANESSA_MANAGED_PROFILE_REQUIRED", "the itl-ondemand profile is managed by the gateway", map[string]any{"profileName": r.backend.TestClientProfile})
		}
	}
	return nil
}

func (r *runtime) preflightVanessa(ctx context.Context, session *mcp.ClientSession) error {
	if r.family != "vanessa-ui" {
		return nil
	}
	result, err := session.CallTool(ctx, &mcp.CallToolParams{Name: "get_environment_data", Arguments: map[string]any{}})
	if err != nil {
		return fmt.Errorf("ITL_VANESSA_EXT_NOT_READY: environment preflight failed: %w", err)
	}
	if result == nil || result.IsError || !confirmsVanessaExt(resultText(result)) {
		return fmt.Errorf("ITL_VANESSA_EXT_NOT_READY: get_environment_data did not confirm VanessaExt")
	}
	return nil
}

func confirmsVanessaExt(text string) bool {
	for _, line := range strings.Split(strings.ToLower(text), "\n") {
		if !strings.Contains(line, "vanessaext") {
			continue
		}
		if strings.Contains(line, "ложь") || strings.Contains(line, "false") || strings.Contains(line, "не установлен") || strings.Contains(line, "not installed") {
			return false
		}
		if strings.Contains(line, "истина") || strings.Contains(line, "true") || strings.Contains(line, "установлен") || strings.Contains(line, "enabled") || strings.HasSuffix(strings.TrimSpace(line), ": да") {
			return true
		}
	}
	return false
}

func (r *runtime) validateVanessaResult(ctx context.Context, name string, result *mcp.CallToolResult, session *mcp.ClientSession) *mcp.CallToolResult {
	if r.family != "vanessa-ui" {
		return result
	}
	if marker := vanessaSemanticFailureMarker(name, resultText(result)); marker != "" {
		return toolError("ITL_VANESSA_TOOL_RESULT_FAILED", "Vanessa returned a runtime/editor failure", map[string]any{"tool": name, "marker": marker})
	}
	if name != "connect_test_client" {
		return result
	}
	text := strings.ToLower(resultText(result))
	if strings.Contains(text, "безопасн") && strings.Contains(text, "запрещ") {
		return toolError("ITL_VANESSA_UNSAFE_ACTION_PROTECTION", resultText(result), nil)
	}
	if strings.Contains(text, "не удалось подключить") || strings.Contains(text, "failed to connect") {
		return toolError("ITL_VANESSA_TESTCLIENT_CONNECT_FAILED", resultText(result), nil)
	}
	post, err := session.CallTool(ctx, &mcp.CallToolParams{Name: "get_window_list_testclient", Arguments: map[string]any{}})
	postText := strings.ToLower(resultText(post))
	if err != nil || post == nil || post.IsError ||
		strings.Contains(postText, "testclient не подключ") || strings.Contains(postText, "test client is not connected") ||
		strings.Contains(postText, "нет соединения") {
		message := "TestClient connection postcondition failed"
		if err != nil {
			message += ": " + err.Error()
		} else if post != nil {
			message += ": " + resultText(post)
		}
		return toolError("ITL_VANESSA_TESTCLIENT_CONNECT_FAILED", message, nil)
	}
	return result
}

func vanessaSemanticFailureMarker(name, text string) string {
	if !isVanessaAuthoringTool(name) {
		return ""
	}
	normalized := strings.ToLower(text)
	markers := []string{
		"ошибка при вызове конструктора (файл)",
		"значение не является значением объектного типа",
		"ошибка доступа к редактору",
		"internal error:",
		"внутренняя ошибка",
	}
	for _, marker := range markers {
		if strings.Contains(normalized, marker) {
			return marker
		}
	}
	return ""
}

func isVanessaAuthoringTool(name string) bool {
	switch name {
	case "search_for_steps_by_keywords", "open_feature_file", "check_syntax", "get_info_about_line_scenario", "run_scenario", "get_test_results", "get_editor_state", "load_features":
		return true
	default:
		return false
	}
}

func resultText(result *mcp.CallToolResult) string {
	if result == nil {
		return ""
	}
	var parts []string
	for _, content := range result.Content {
		if item, ok := content.(*mcp.TextContent); ok {
			parts = append(parts, item.Text)
		}
	}
	return strings.Join(parts, "\n")
}

func (r *runtime) close(ctx context.Context) error {
	r.mu.Lock()
	r.closed = true
	r.mu.Unlock()
	var lastErr error
	for attempt := 0; attempt < 3; attempt++ {
		if err := r.stop(ctx); err == nil {
			return nil
		} else {
			lastErr = err
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("cleanup owned backend after stdio EOF: %w", lastErr)
		case <-time.After(250 * time.Millisecond):
		}
	}
	return fmt.Errorf("cleanup owned backend after stdio EOF after 3 attempts: %w", lastErr)
}

func (r *runtime) writeEvidenceLocked(toolName string, arguments any, outcome, resultCode string) {
	if r.backend == nil {
		return
	}
	directory := filepath.Join(r.projectRoot, ".agent-1c", "mcp", "ondemand", r.family)
	if err := os.MkdirAll(directory, 0o755); err != nil {
		r.logger.Error("create evidence directory", "error", err)
		return
	}
	argumentsRaw, _ := json.Marshal(arguments)
	argumentsHash := sha256.Sum256(argumentsRaw)
	featurePath, featureSHA, scenarioLine := r.authoringEvidenceContextLocked(toolName, arguments, outcome)
	entry := map[string]any{
		"schemaVersion": 2, "family": r.family, "instanceId": r.instanceID,
		"backendVersion": r.backend.BackendVersion, "catalogSha256": r.catalog.SHA256,
		"tool": toolName, "outcome": outcome, "resultCode": resultCode,
		"argumentsSha256": fmt.Sprintf("%x", argumentsHash[:]),
		"featurePath":     featurePath, "featureSha256": featureSHA, "scenarioLine": scenarioLine,
		"recordedAt": time.Now().UTC().Format(time.RFC3339Nano),
	}
	raw, _ := json.Marshal(entry)
	path := filepath.Join(directory, r.instanceID+".evidence.jsonl")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err == nil {
		_, _ = file.Write(append(raw, '\n'))
		_ = file.Close()
	}
}

func (r *runtime) authoringEvidenceContextLocked(toolName string, arguments any, outcome string) (string, string, int) {
	if r.family != "vanessa-ui" || !isVanessaAuthoringTool(toolName) {
		return "", "", 0
	}
	if toolName == "search_for_steps_by_keywords" {
		return "", "", 0
	}
	args, _ := arguments.(map[string]any)
	pathValue, _ := args["filePath"].(string)
	if pathValue == "" && toolName == "load_features" {
		pathValue, _ = args["path"].(string)
	}
	featurePath := r.projectRelativeFeature(pathValue)
	if featurePath == "" {
		featurePath = r.authoringFeature
	}
	line := integerArgument(args["lineNumber"])
	if line == 0 {
		line = r.authoringLine
	}
	if outcome == "passed" {
		if featurePath != "" && toolName != "search_for_steps_by_keywords" {
			r.authoringFeature = featurePath
		}
		if line > 0 && (toolName == "get_info_about_line_scenario" || toolName == "run_scenario") {
			r.authoringLine = line
		}
	}
	featureSHA := ""
	if featurePath != "" {
		if raw, err := os.ReadFile(filepath.Join(r.projectRoot, filepath.FromSlash(featurePath))); err == nil {
			hash := sha256.Sum256(raw)
			featureSHA = fmt.Sprintf("%x", hash[:])
		}
	}
	return featurePath, featureSHA, line
}

func (r *runtime) projectRelativeFeature(value string) string {
	if strings.TrimSpace(value) == "" {
		return ""
	}
	full := value
	if !filepath.IsAbs(full) {
		full = filepath.Join(r.projectRoot, full)
	}
	abs, err := filepath.Abs(full)
	if err != nil || !strings.EqualFold(filepath.Ext(abs), ".feature") {
		return ""
	}
	relative, err := filepath.Rel(r.projectRoot, abs)
	if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return ""
	}
	return filepath.ToSlash(relative)
}

func integerArgument(value any) int {
	switch typed := value.(type) {
	case float64:
		return int(typed)
	case int:
		return typed
	case int64:
		return int(typed)
	case json.Number:
		parsed, _ := typed.Int64()
		return int(parsed)
	default:
		return 0
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
