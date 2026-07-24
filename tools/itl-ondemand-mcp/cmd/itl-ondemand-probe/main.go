package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type runtimeState struct {
	InstanceID                            string `json:"instanceId"`
	PID                                   int    `json:"pid"`
	Port                                  int    `json:"port"`
	TestClientProfile                     string `json:"testClientProfile,omitempty"`
	TestClientPID                         int    `json:"testClientPid,omitempty"`
	TestClientPort                        int    `json:"testClientPort,omitempty"`
	VanessaAutomationCompatibilityVersion string `json:"vanessaAutomationCompatibilityVersion,omitempty"`
	VanessaAutomationDownstreamRevision   string `json:"vanessaAutomationDownstreamRevision,omitempty"`
	VanessaAutomationArchiveSHA256        string `json:"vanessaAutomationArchiveSha256,omitempty"`
	VanessaAutomationEpfSHA256            string `json:"vanessaAutomationEpfSha256,omitempty"`
}

type probeSession struct {
	session *mcp.ClientSession
	count   int
	state   *runtimeState
}

const gatewayCallTool = "call_tool"

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	exe := flag.String("exe", "", "itl-ondemand-mcp executable")
	family := flag.String("family", "", "roctup or vanessa-ui")
	projectRoot := flag.String("project-root", "", "ITL development worktree")
	catalog := flag.String("catalog", "", "compatibility catalog")
	helper := flag.String("helper", "", "agent-1c.ps1 path")
	tool := flag.String("tool", "", "safe live tool to call")
	argumentsJSON := flag.String("arguments-json", "{}", "tool arguments")
	instances := flag.Int("instances", 1, "number of simultaneous facade clients")
	output := flag.String("output", "", "evidence JSON path")
	idleTimeout := flag.Duration("idle-timeout", 10*time.Minute, "facade backend idle timeout")
	verifyIdle := flag.Bool("verify-idle", false, "keep stdio open and prove idle cleanup")
	vanessaSmoke := flag.Bool("vanessa-ui-smoke", false, "connect the managed TestClient and call UI/OS screenshot tools")
	vanessaFeature := flag.String("vanessa-feature", "", "release feature file for Vanessa open/check authoring smoke")
	flag.Parse()
	if *exe == "" || *projectRoot == "" || *catalog == "" || *helper == "" || *tool == "" {
		return fmt.Errorf("--exe, --project-root, --catalog, --helper, and --tool are required")
	}
	if *family != "roctup" && *family != "vanessa-ui" {
		return fmt.Errorf("invalid --family %q", *family)
	}
	if *instances < 1 || *instances > 2 {
		return fmt.Errorf("--instances must be 1 or 2")
	}
	var arguments any
	if err := json.Unmarshal([]byte(*argumentsJSON), &arguments); err != nil {
		return fmt.Errorf("decode --arguments-json: %w", err)
	}
	expectedCount, err := catalogToolCount(*catalog)
	if err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	connected := make([]*probeSession, 0, *instances)
	vanessaFileAuthoringOutcome := ""
	var vanessaFileAuthoringCodes []string
	defer func() {
		for _, item := range connected {
			_ = item.session.Close()
		}
	}()
	for index := 0; index < *instances; index++ {
		item, err := connect(ctx, *exe, *family, *projectRoot, *catalog, *helper, *idleTimeout)
		if err != nil {
			return err
		}
		connected = append(connected, item)
		if item.count != 2 {
			return fmt.Errorf("facade gateway tools/list count=%d, expected=2; internal catalog count=%d", item.count, expectedCount)
		}
		stopHeartbeat := keepSessionsAlive(ctx, connected[:len(connected)-1], *idleTimeout, *tool, arguments)
		result, err := callInnerTool(ctx, item.session, *tool, arguments)
		if err != nil {
			stopHeartbeat()
			return fmt.Errorf("call %s: %w", *tool, err)
		}
		if result.IsError {
			stopHeartbeat()
			return fmt.Errorf("call %s returned a tool error: %#v", *tool, result.StructuredContent)
		}
		runtimeRoot := filepath.Join(*projectRoot, ".agent-1c", "mcp", "ondemand", *family)
		states, err := waitForStateCount(runtimeRoot, index+1, 30*time.Second)
		if err != nil {
			stopHeartbeat()
			return err
		}
		known := map[string]bool{}
		for _, connectedItem := range connected[:len(connected)-1] {
			if connectedItem.state != nil {
				known[connectedItem.state.InstanceID] = true
			}
		}
		for stateIndex := range states {
			if !known[states[stateIndex].InstanceID] {
				item.state = &states[stateIndex]
				break
			}
		}
		if item.state == nil {
			stopHeartbeat()
			return fmt.Errorf("could not bind facade session to its runtime state")
		}
		if *vanessaSmoke {
			if *family != "vanessa-ui" {
				return fmt.Errorf("--vanessa-ui-smoke requires --family vanessa-ui")
			}
			outcome, codes, err := runVanessaSmoke(ctx, item.session, item.state.TestClientPort, *vanessaFeature)
			if err != nil {
				stopHeartbeat()
				return err
			}
			if vanessaFileAuthoringOutcome == "" {
				vanessaFileAuthoringOutcome = outcome
			}
			for _, code := range codes {
				if !containsString(vanessaFileAuthoringCodes, code) {
					vanessaFileAuthoringCodes = append(vanessaFileAuthoringCodes, code)
				}
			}
		}
		stopHeartbeat()
	}

	runtimeRoot := filepath.Join(*projectRoot, ".agent-1c", "mcp", "ondemand", *family)
	states, err := waitForStateCount(runtimeRoot, *instances, 30*time.Second)
	if err != nil {
		return err
	}
	if err := distinctInstances(*family, states); err != nil {
		return err
	}
	initial := append([]runtimeState(nil), states...)

	secondSurvived := false
	if *instances == 2 {
		if err := connected[0].session.Close(); err != nil {
			return fmt.Errorf("close first facade: %w", err)
		}
		connected = connected[1:]
		if _, err := waitForStateCount(runtimeRoot, 1, 30*time.Second); err != nil {
			return fmt.Errorf("first facade cleanup: %w", err)
		}
		result, err := callInnerTool(ctx, connected[0].session, *tool, arguments)
		if err != nil || result.IsError {
			return fmt.Errorf("second facade stopped with the first: err=%v result=%#v", err, result)
		}
		secondSurvived = true
	}
	idleCleanupPassed := false
	if *verifyIdle {
		if _, err := waitForStateCount(runtimeRoot, 0, *idleTimeout+30*time.Second); err != nil {
			return fmt.Errorf("idle cleanup: %w", err)
		}
		idleCleanupPassed = true
		result, err := callInnerTool(ctx, connected[0].session, *tool, arguments)
		if err != nil || result.IsError {
			return fmt.Errorf("facade did not restart after idle cleanup: err=%v result=%#v", err, result)
		}
		if _, err := waitForStateCount(runtimeRoot, 1, 30*time.Second); err != nil {
			return fmt.Errorf("post-idle restart: %w", err)
		}
	}
	for _, item := range connected {
		if err := item.session.Close(); err != nil {
			return fmt.Errorf("close facade: %w", err)
		}
	}
	connected = nil
	if _, err := waitForStateCount(runtimeRoot, 0, 30*time.Second); err != nil {
		return fmt.Errorf("EOF cleanup: %w", err)
	}

	evidence := map[string]any{
		"schemaVersion": 1, "family": *family, "publicToolCount": 2, "catalogToolCount": expectedCount,
		"tool": *tool, "instances": initial, "secondSurvivedFirstClose": secondSurvived,
		"cleanupPassed": true, "idleCleanupPassed": idleCleanupPassed, "vanessaUiSmokePassed": *vanessaSmoke,
		"capturedAt": time.Now().UTC().Format(time.RFC3339Nano),
	}
	if *vanessaSmoke {
		evidence["vanessaFileAuthoringOutcome"] = vanessaFileAuthoringOutcome
		evidence["vanessaFileAuthoringCodes"] = vanessaFileAuthoringCodes
		evidence["vanessaFeature"] = *vanessaFeature
	}
	raw, _ := json.MarshalIndent(evidence, "", "  ")
	if *output != "" {
		if err := os.MkdirAll(filepath.Dir(*output), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(*output, append(raw, '\n'), 0o600); err != nil {
			return err
		}
	}
	fmt.Println(string(raw))
	return nil
}

func keepSessionsAlive(ctx context.Context, sessions []*probeSession, idleTimeout time.Duration, tool string, arguments any) func() {
	if len(sessions) == 0 || idleTimeout <= 0 {
		return func() {}
	}
	interval := idleTimeout / 3
	if interval < 250*time.Millisecond {
		interval = 250 * time.Millisecond
	}
	stop := make(chan struct{})
	var workers sync.WaitGroup
	for _, item := range sessions {
		workers.Add(1)
		go func(session *mcp.ClientSession) {
			defer workers.Done()
			ticker := time.NewTicker(interval)
			defer ticker.Stop()
			for {
				select {
				case <-ctx.Done():
					return
				case <-stop:
					return
				case <-ticker.C:
					_, _ = callInnerTool(ctx, session, tool, arguments)
				}
			}
		}(item.session)
	}
	var once sync.Once
	return func() {
		once.Do(func() { close(stop) })
		workers.Wait()
	}
}

func callInnerTool(ctx context.Context, session *mcp.ClientSession, name string, arguments any) (*mcp.CallToolResult, error) {
	return session.CallTool(ctx, &mcp.CallToolParams{
		Name:      gatewayCallTool,
		Arguments: map[string]any{"name": name, "arguments": arguments},
	})
}

func connect(ctx context.Context, exe, family, projectRoot, catalog, helper string, idleTimeout time.Duration) (*probeSession, error) {
	command := exec.Command(exe, "serve", "--family", family, "--project-root", projectRoot, "--catalog", catalog, "--helper", helper, "--idle-timeout", idleTimeout.String())
	command.Stderr = os.Stderr
	client := mcp.NewClient(&mcp.Implementation{Name: "itl-ondemand-live-probe", Version: "0.1.0"}, nil)
	session, err := client.Connect(ctx, &mcp.CommandTransport{Command: command, TerminateDuration: time.Minute}, nil)
	if err != nil {
		return nil, fmt.Errorf("connect facade: %w", err)
	}
	count := 0
	cursor := ""
	for {
		page, err := session.ListTools(ctx, &mcp.ListToolsParams{Cursor: cursor})
		if err != nil {
			_ = session.Close()
			return nil, fmt.Errorf("facade tools/list: %w", err)
		}
		count += len(page.Tools)
		if page.NextCursor == "" {
			break
		}
		cursor = page.NextCursor
	}
	return &probeSession{session: session, count: count}, nil
}

func catalogToolCount(path string) (int, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	var value struct {
		Tools []json.RawMessage `json:"tools"`
	}
	if err := json.Unmarshal(raw, &value); err != nil {
		return 0, err
	}
	return len(value.Tools), nil
}

func readStates(root string) ([]runtimeState, error) {
	files, err := filepath.Glob(filepath.Join(root, "*.json"))
	if err != nil {
		return nil, err
	}
	states := make([]runtimeState, 0, len(files))
	for _, path := range files {
		name := strings.TrimSuffix(filepath.Base(path), ".json")
		if len(name) != 32 || strings.Contains(name, ".") {
			continue
		}
		raw, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		var state runtimeState
		if err := json.Unmarshal(raw, &state); err != nil {
			return nil, err
		}
		states = append(states, state)
	}
	sort.Slice(states, func(i, j int) bool { return states[i].InstanceID < states[j].InstanceID })
	return states, nil
}

func waitForStateCount(root string, count int, timeout time.Duration) ([]runtimeState, error) {
	deadline := time.Now().Add(timeout)
	for {
		states, err := readStates(root)
		if err != nil {
			return nil, err
		}
		if len(states) == count {
			return states, nil
		}
		if !time.Now().Before(deadline) {
			return nil, fmt.Errorf("runtime instance count=%d, expected=%d", len(states), count)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func distinctInstances(family string, states []runtimeState) error {
	pids := map[int]bool{}
	ports := map[int]bool{}
	testClientPorts := map[int]bool{}
	for _, state := range states {
		if state.PID <= 0 || state.Port <= 0 || pids[state.PID] || ports[state.Port] {
			return fmt.Errorf("runtime instances do not have distinct positive PID/port values: %#v", states)
		}
		pids[state.PID] = true
		ports[state.Port] = true
		if family == "vanessa-ui" {
			if state.TestClientProfile != "itl-ondemand" || state.TestClientPID <= 0 || pids[state.TestClientPID] || state.TestClientPort <= 0 || testClientPorts[state.TestClientPort] {
				return fmt.Errorf("Vanessa instances do not have distinct managed TestClient profiles/ports: %#v", states)
			}
			pids[state.TestClientPID] = true
			testClientPorts[state.TestClientPort] = true
		}
	}
	return nil
}

func runVanessaSmoke(ctx context.Context, session *mcp.ClientSession, testClientPort int, featurePath string) (string, []string, error) {
	if featurePath == "" {
		return "", nil, fmt.Errorf("Vanessa authoring smoke requires --vanessa-feature")
	}
	if !filepath.IsAbs(featurePath) || !strings.Contains(featurePath, " ") || !containsCyrillic(featurePath) {
		return "", nil, fmt.Errorf("Vanessa authoring smoke requires an absolute Windows path containing spaces and Cyrillic text: %q", featurePath)
	}
	featureDirectory := filepath.Dir(featurePath)
	for _, call := range []struct {
		name      string
		arguments map[string]any
	}{
		{name: "open_feature_file", arguments: map[string]any{"filePath": featurePath}},
		{name: "check_syntax", arguments: map[string]any{"filePath": featurePath}},
		{name: "load_features", arguments: map[string]any{"path": featurePath}},
		{name: "load_features", arguments: map[string]any{"path": featureDirectory}},
	} {
		result, err := callInnerTool(ctx, session, call.name, call.arguments)
		if err != nil {
			return "", nil, fmt.Errorf("Vanessa file smoke %s: %w", call.name, err)
		}
		if result == nil || result.IsError {
			return "", nil, fmt.Errorf("Vanessa file smoke %s returned a tool error: %#v", call.name, result)
		}
	}
	accessDeniedPath := os.Getenv("ITL_VANESSA_ACCESS_DENIED_PROBE_PATH")
	var cleanupAccessDeniedProbe func() error
	if accessDeniedPath == "" {
		var err error
		accessDeniedPath, cleanupAccessDeniedProbe, err = createAccessDeniedProbe(featureDirectory)
		if err != nil {
			return "", nil, fmt.Errorf("create Vanessa PATH_ACCESS_DENIED probe: %w", err)
		}
		defer func() {
			if cleanupAccessDeniedProbe != nil {
				_ = cleanupAccessDeniedProbe()
			}
		}()
	}
	errorCodes := make([]string, 0, 3)
	for _, probe := range []struct {
		name      string
		arguments map[string]any
		code      string
	}{
		{name: "open_feature_file", arguments: map[string]any{"filePath": featurePath + "|invalid"}, code: "PATH_INVALID"},
		{name: "load_features", arguments: map[string]any{"path": filepath.Join(featureDirectory, "Отсутствует feature.feature")}, code: "PATH_NOT_FOUND"},
		{name: "check_syntax", arguments: map[string]any{"filePath": accessDeniedPath}, code: "PATH_ACCESS_DENIED"},
	} {
		result, err := callInnerTool(ctx, session, probe.name, probe.arguments)
		if err != nil {
			return "", nil, fmt.Errorf("Vanessa structured error smoke %s: %w", probe.name, err)
		}
		if result == nil || !result.IsError {
			return "", nil, fmt.Errorf("Vanessa structured error smoke %s did not return %s: %#v", probe.name, probe.code, result)
		}
		actual := probeToolResultCode(result)
		if actual != probe.code {
			return "", nil, fmt.Errorf("Vanessa structured error smoke %s returned %q, expected %q: %#v", probe.name, actual, probe.code, result.StructuredContent)
		}
		errorCodes = append(errorCodes, actual)
	}
	if cleanupAccessDeniedProbe != nil {
		if err := cleanupAccessDeniedProbe(); err != nil {
			return "", nil, fmt.Errorf("cleanup Vanessa PATH_ACCESS_DENIED probe: %w", err)
		}
		cleanupAccessDeniedProbe = nil
	}
	var osWindows *mcp.CallToolResult
	for _, call := range []struct {
		name      string
		arguments any
	}{
		{name: "get_environment_data", arguments: map[string]any{}},
		{name: "connect_test_client", arguments: map[string]any{"profileName": "itl-ondemand"}},
		{name: "get_window_list_testclient", arguments: map[string]any{}},
		{name: "get_window_list_os", arguments: map[string]any{}},
	} {
		result, err := callInnerTool(ctx, session, call.name, call.arguments)
		if err != nil {
			return "", nil, fmt.Errorf("Vanessa smoke %s: %w", call.name, err)
		}
		if result == nil || result.IsError {
			return "", nil, fmt.Errorf("Vanessa smoke %s returned a tool error: %#v", call.name, result)
		}
		if call.name == "get_window_list_os" {
			osWindows = result
		}
	}
	title := firstOSWindowTitle(osWindows)
	if title == "" {
		var err error
		title, err = waitForTestClientWindowTitle(ctx, testClientPort, time.Minute)
		if err != nil {
			return "", nil, err
		}
	}
	result, err := callInnerTool(ctx, session, "get_window_screenshot_os", map[string]any{"window_title": title, "color_mode": "grayscale"})
	if err != nil {
		return "", nil, fmt.Errorf("Vanessa smoke get_window_screenshot_os: %w", err)
	}
	if result == nil || result.IsError || len(result.Content) == 0 {
		return "", nil, fmt.Errorf("Vanessa smoke screenshot returned no content: %#v", result)
	}
	return "passed", errorCodes, nil
}

func containsString(values []string, value string) bool {
	for _, item := range values {
		if item == value {
			return true
		}
	}
	return false
}

func containsCyrillic(value string) bool {
	for _, symbol := range value {
		if symbol >= '\u0400' && symbol <= '\u04ff' {
			return true
		}
	}
	return false
}

func probeToolResultCode(result *mcp.CallToolResult) string {
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

func firstOSWindowTitle(result *mcp.CallToolResult) string {
	if result == nil {
		return ""
	}
	for _, content := range result.Content {
		text, ok := content.(*mcp.TextContent)
		if !ok {
			continue
		}
		for _, line := range strings.Split(text.Text, "\n") {
			trimmed := strings.TrimSpace(line)
			if strings.HasPrefix(trimmed, "-") && strings.TrimSpace(strings.TrimPrefix(trimmed, "-")) != "" {
				return strings.TrimSpace(strings.TrimPrefix(trimmed, "-"))
			}
		}
	}
	return ""
}

func waitForTestClientWindowTitle(ctx context.Context, port int, timeout time.Duration) (string, error) {
	if port <= 0 {
		return "", fmt.Errorf("managed TestClient port is missing")
	}
	deadline := time.Now().Add(timeout)
	script := `& { param([int]$Port) $pattern='(?i)-TPort\s+'+[regex]::Escape([string]$Port)+'(?:\s|$)'; foreach($native in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { [string]$_.CommandLine -match '(?i)/TESTCLIENT' -and [string]$_.CommandLine -match $pattern })) { $title=[string](Get-Process -Id $native.ProcessId -ErrorAction SilentlyContinue).MainWindowTitle; if($title){$title; break} } }`
	for {
		command := exec.CommandContext(ctx, "powershell.exe", "-NoProfile", "-Command", script, strconv.Itoa(port))
		raw, err := command.Output()
		if err == nil && strings.TrimSpace(string(raw)) != "" {
			return strings.TrimSpace(string(raw)), nil
		}
		if !time.Now().Before(deadline) {
			return "", fmt.Errorf("TestClient on port %d did not expose a window title", port)
		}
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-time.After(500 * time.Millisecond):
		}
	}
}
