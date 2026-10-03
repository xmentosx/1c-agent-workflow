package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

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
	ClientMcpSafeMode                     *bool  `json:"clientMcpSafeMode,omitempty"`
	VAExtensionSafeMode                   *bool  `json:"vaExtensionSafeMode,omitempty"`
}

type probeSession struct {
	session *mcp.ClientSession
	count   int
	state   *runtimeState
	stderr  *probeStderr
}

type probeStderr struct {
	mu   sync.Mutex
	data bytes.Buffer
}

func (s *probeStderr) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.data.Write(p)
}

func (s *probeStderr) offset() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.data.Len()
}

func (s *probeStderr) since(offset int) []byte {
	s.mu.Lock()
	defer s.mu.Unlock()
	return bytes.Clone(s.data.Bytes()[offset:])
}

func executionGuardWait(log []byte) (time.Duration, error) {
	var maximum time.Duration
	for _, line := range bytes.Split(log, []byte{'\n'}) {
		if !bytes.Contains(line, []byte(`"msg":"waiting for database execution"`)) {
			continue
		}
		var event struct {
			Message     string  `json:"msg"`
			WaitSeconds float64 `json:"waitSeconds"`
		}
		if err := json.Unmarshal(line, &event); err != nil {
			return 0, fmt.Errorf("invalid execution guard wait evidence: %w", err)
		}
		if event.Message != "waiting for database execution" || math.IsNaN(event.WaitSeconds) ||
			math.IsInf(event.WaitSeconds, 0) || event.WaitSeconds < 0 {
			return 0, fmt.Errorf("invalid execution guard wait evidence")
		}
		wait := time.Duration(event.WaitSeconds * float64(time.Second))
		if wait > maximum {
			maximum = wait
		}
	}
	return maximum, nil
}

func effectiveExitWait(wall, guard time.Duration) (time.Duration, error) {
	if guard < 0 || guard > wall {
		return 0, fmt.Errorf("execution guard wait %s exceeds facade close time %s", guard, wall)
	}
	return wall - guard, nil
}

func (s *probeSession) closeMeasured() (time.Duration, time.Duration, time.Duration, error) {
	offset := s.stderr.offset()
	started := time.Now()
	closeErr := s.session.Close()
	wall := time.Since(started)
	guard, evidenceErr := executionGuardWait(s.stderr.since(offset))
	if evidenceErr != nil {
		return 0, guard, wall, evidenceErr
	}
	exitWait, measureErr := effectiveExitWait(wall, guard)
	if measureErr != nil {
		return 0, guard, wall, measureErr
	}
	if closeErr != nil {
		return 0, guard, wall, closeErr
	}
	return exitWait, guard, wall, nil
}

const (
	gatewayCallTool        = "call_tool"
	gatewayPublicToolCount = 2
)

const (
	facadeCleanupTimeout     = 90 * time.Second
	facadeTerminateDuration  = 2 * time.Minute
	defaultProbeTimeout      = 10 * time.Minute
	vanessaSmokeProbeTimeout = 30 * time.Minute
)

func probeTimeout(vanessaSmoke bool) time.Duration {
	if vanessaSmoke {
		return vanessaSmokeProbeTimeout
	}
	return defaultProbeTimeout
}

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
	sequencePath := flag.String("sequence-json", "", "JSON file of ordered inner calls [{name,arguments}], using one facade session")
	instances := flag.Int("instances", 1, "number of simultaneous facade clients")
	output := flag.String("output", "", "evidence JSON path")
	idleTimeout := flag.Duration("idle-timeout", 10*time.Minute, "facade backend idle timeout")
	verifyIdle := flag.Bool("verify-idle", false, "keep stdio open and prove idle cleanup")
	vanessaSmoke := flag.Bool("vanessa-ui-smoke", false, "connect the managed TestClient and call UI/OS screenshot tools")
	vanessaFeature := flag.String("vanessa-feature", "", "release feature file for Vanessa open/check authoring smoke")
	vanessaSecondaryFeature := flag.String("vanessa-secondary-feature", "", "second release feature file for Vanessa cold reloadAndRun smoke")
	flag.Parse()
	if *exe == "" || *projectRoot == "" || *catalog == "" || *helper == "" || (*tool == "" && *sequencePath == "") {
		return fmt.Errorf("--exe, --project-root, --catalog, --helper, and --tool or --sequence-json are required")
	}
	if *family != "roctup" && *family != "vanessa-ui" {
		return fmt.Errorf("invalid --family %q", *family)
	}
	if *instances < 1 || *instances > 2 {
		return fmt.Errorf("--instances must be 1 or 2")
	}
	var sequence []probeCall
	if *sequencePath != "" {
		if *tool != "" || *argumentsJSON != "{}" || *instances != 1 || *vanessaSmoke || *verifyIdle {
			return fmt.Errorf("--sequence-json uses one session and cannot combine with --tool, --arguments-json, multiple instances, --vanessa-ui-smoke, or --verify-idle")
		}
		var err error
		sequence, err = readProbeSequence(*sequencePath, *catalog)
		if err != nil {
			return err
		}
	}
	var arguments any
	if err := json.Unmarshal([]byte(*argumentsJSON), &arguments); err != nil {
		return fmt.Errorf("decode --arguments-json: %w", err)
	}
	expectedCount, err := catalogToolCount(*catalog)
	if err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(context.Background(), probeTimeout(*vanessaSmoke))
	defer cancel()
	if sequence != nil {
		return runSequenceProbe(ctx, *exe, *family, *projectRoot, *catalog, *helper, *idleTimeout, *output, sequence, expectedCount)
	}
	connected := make([]*probeSession, 0, *instances)
	connectedTestClients := 0
	maxConcurrentSessions := 0
	ownedProcessExitWait := time.Duration(0)
	maximumGuardWait := time.Duration(0)
	maximumFacadeCloseWait := time.Duration(0)
	observeConcurrency := func() {
		current := len(connected) + connectedTestClients
		if current > maxConcurrentSessions {
			maxConcurrentSessions = current
		}
	}
	closeObserved := func(item *probeSession) error {
		exitWait, guardWait, wallWait, err := item.closeMeasured()
		if err != nil {
			return err
		}
		if exitWait > ownedProcessExitWait {
			ownedProcessExitWait = exitWait
		}
		if guardWait > maximumGuardWait {
			maximumGuardWait = guardWait
		}
		if wallWait > maximumFacadeCloseWait {
			maximumFacadeCloseWait = wallWait
		}
		return nil
	}
	vanessaFileAuthoringOutcome := ""
	var vanessaFileAuthoringCalls []string
	vanessaScenarioEvidencePassed := false
	serializedFacadeHandoffPassed := false
	secondSurvived := false
	initial := make([]runtimeState, 0, *instances)
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
		observeConcurrency()
		if item.count != gatewayPublicToolCount {
			return fmt.Errorf("facade gateway tools/list count=%d, expected=%d; internal catalog count=%d", item.count, gatewayPublicToolCount, expectedCount)
		}
		var result *mcp.CallToolResult
		if index > 0 {
			previous := connected[len(connected)-2]
			releasePrevious := func() error {
				return closeObserved(previous)
			}
			var releasedPrevious bool
			result, releasedPrevious, err = callWithFacadeHandoff(ctx, item.session, releasePrevious, *tool, arguments, 2*time.Second)
			if releasedPrevious {
				connected = connected[1:]
				serializedFacadeHandoffPassed = true
				secondSurvived = true
			}
		} else {
			result, err = callInnerTool(ctx, item.session, *tool, arguments)
		}
		if err != nil {
			return fmt.Errorf("call %s: %w", *tool, err)
		}
		if result.IsError {
			return fmt.Errorf("call %s returned a tool error: %#v", *tool, result.StructuredContent)
		}
		runtimeRoot := filepath.Join(*projectRoot, ".agent-1c", "mcp", "ondemand", *family)
		states, err := waitForStateCount(runtimeRoot, len(connected), 30*time.Second)
		if err != nil {
			return err
		}
		known := map[string]bool{}
		for _, state := range initial {
			known[state.InstanceID] = true
		}
		for stateIndex := range states {
			if !known[states[stateIndex].InstanceID] {
				item.state = &states[stateIndex]
				break
			}
		}
		if item.state == nil {
			return fmt.Errorf("could not bind facade session to its runtime state")
		}
		initial = append(initial, *item.state)
		if *vanessaSmoke {
			if *family != "vanessa-ui" {
				return fmt.Errorf("--vanessa-ui-smoke requires --family vanessa-ui")
			}
			outcome, calls, err := runVanessaSmoke(ctx, item.session, item.state.TestClientPort, *vanessaFeature, *vanessaSecondaryFeature, func(delta int) {
				connectedTestClients += delta
				observeConcurrency()
			})
			if err != nil {
				return err
			}
			if err := validateVanessaScenarioEvidence(*projectRoot, item.state.InstanceID, *vanessaFeature, *vanessaSecondaryFeature); err != nil {
				return err
			}
			vanessaScenarioEvidencePassed = true
			if vanessaFileAuthoringOutcome == "" {
				vanessaFileAuthoringOutcome = outcome
			}
			for _, call := range calls {
				if !containsString(vanessaFileAuthoringCalls, call) {
					vanessaFileAuthoringCalls = append(vanessaFileAuthoringCalls, call)
				}
			}
		}
	}

	runtimeRoot := filepath.Join(*projectRoot, ".agent-1c", "mcp", "ondemand", *family)
	if err := validateInstanceHistory(*family, initial, serializedFacadeHandoffPassed); err != nil {
		return err
	}

	if *instances == 2 && !secondSurvived {
		if err := closeObserved(connected[0]); err != nil {
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
		if err := closeObserved(item); err != nil {
			return fmt.Errorf("close facade: %w", err)
		}
	}
	connected = nil
	if _, err := waitForStateCount(runtimeRoot, 0, 30*time.Second); err != nil {
		return fmt.Errorf("EOF cleanup: %w", err)
	}

	evidence := map[string]any{
		"schemaVersion": 2, "family": *family, "publicToolCount": gatewayPublicToolCount, "catalogToolCount": expectedCount,
		"tool": *tool, "instances": initial, "secondSurvivedFirstClose": secondSurvived,
		"serializedFacadeHandoffPassed": serializedFacadeHandoffPassed,
		"cleanupPassed":                 true, "idleCleanupPassed": idleCleanupPassed, "vanessaUiSmokePassed": *vanessaSmoke,
		"maxConcurrentSessions": maxConcurrentSessions, "ownedProcessExitWaitMs": ownedProcessExitWait.Milliseconds(),
		"executionGuardWaitMs": maximumGuardWait.Milliseconds(), "facadeCloseWaitMs": maximumFacadeCloseWait.Milliseconds(),
		"capturedAt": time.Now().UTC().Format(time.RFC3339Nano),
	}
	if *vanessaSmoke {
		evidence["vanessaFileAuthoringOutcome"] = vanessaFileAuthoringOutcome
		evidence["vanessaFileAuthoringCalls"] = vanessaFileAuthoringCalls
		evidence["vanessaFeature"] = *vanessaFeature
		evidence["vanessaSecondaryFeature"] = *vanessaSecondaryFeature
		evidence["vanessaScenarioEvidencePassed"] = vanessaScenarioEvidencePassed
	}
	return writeProbeEvidence(*output, evidence)
}

func writeProbeEvidence(output string, evidence any) error {
	raw, err := json.MarshalIndent(evidence, "", "  ")
	if err != nil {
		return err
	}
	if output != "" {
		if err := os.MkdirAll(filepath.Dir(output), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(output, append(raw, '\n'), 0o600); err != nil {
			return err
		}
	}
	fmt.Println(string(raw))
	return nil
}

type probeCall struct {
	Name      string         `json:"name"`
	Arguments map[string]any `json:"arguments"`
}

type probeCallEvidence struct {
	Name      string              `json:"name"`
	Arguments map[string]any      `json:"arguments"`
	Result    *mcp.CallToolResult `json:"result,omitempty"`
	Error     string              `json:"error,omitempty"`
}

func readProbeSequence(path, catalogPath string) ([]probeCall, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	raw = bytes.TrimPrefix(raw, []byte{0xef, 0xbb, 0xbf})
	if !utf8.Valid(raw) {
		return nil, fmt.Errorf("sequence JSON is not valid UTF-8")
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	decoder.UseNumber()
	var calls []probeCall
	if err := decoder.Decode(&calls); err != nil {
		return nil, fmt.Errorf("decode sequence JSON: %w", err)
	}
	if decoder.Decode(new(any)) != io.EOF {
		return nil, fmt.Errorf("sequence JSON must contain one array")
	}
	if len(calls) == 0 {
		return nil, fmt.Errorf("sequence JSON must contain at least one call")
	}
	catalogRaw, err := os.ReadFile(catalogPath)
	if err != nil {
		return nil, err
	}
	var catalog struct {
		Tools []struct {
			Name string `json:"name"`
		} `json:"tools"`
	}
	if err := json.Unmarshal(catalogRaw, &catalog); err != nil {
		return nil, err
	}
	known := make(map[string]bool, len(catalog.Tools))
	for _, tool := range catalog.Tools {
		known[tool.Name] = true
	}
	for index := range calls {
		if calls[index].Name == "" || !known[calls[index].Name] {
			return nil, fmt.Errorf("sequence call %d names an unknown catalog tool %q", index+1, calls[index].Name)
		}
		if calls[index].Arguments == nil {
			calls[index].Arguments = map[string]any{}
		}
	}
	return calls, nil
}

func executeProbeSequence(ctx context.Context, session *mcp.ClientSession, calls []probeCall, closeOwned func() error) (records []probeCallEvidence, err error) {
	defer func() {
		if closeErr := closeOwned(); closeErr != nil {
			if err == nil {
				err = fmt.Errorf("close owned facade: %w", closeErr)
			} else {
				err = fmt.Errorf("%w; close owned facade: %v", err, closeErr)
			}
		}
	}()
	for _, call := range calls {
		if err := ctx.Err(); err != nil {
			return records, err
		}
		result, callErr := callInnerTool(ctx, session, call.Name, call.Arguments)
		record := probeCallEvidence{Name: call.Name, Arguments: call.Arguments, Result: result}
		if callErr == nil && (result == nil || result.IsError) {
			callErr = fmt.Errorf("tool returned an error result")
		}
		if callErr != nil {
			record.Error = callErr.Error()
		}
		records = append(records, record)
		if callErr != nil {
			return records, fmt.Errorf("sequence call %d %s: %w", len(records), call.Name, callErr)
		}
	}
	return records, nil
}

func runSequenceProbe(ctx context.Context, exe, family, projectRoot, catalog, helper string, idleTimeout time.Duration, output string, calls []probeCall, expectedCount int) error {
	item, err := connect(ctx, exe, family, projectRoot, catalog, helper, idleTimeout)
	if err != nil {
		return err
	}
	var exitWait, guardWait, wallWait time.Duration
	cleanupPassed := false
	closeOwned := func() error {
		var closeErr error
		exitWait, guardWait, wallWait, closeErr = item.closeMeasured()
		if closeErr == nil {
			_, closeErr = waitForStateCount(filepath.Join(projectRoot, ".agent-1c", "mcp", "ondemand", family), 0, 30*time.Second)
		}
		cleanupPassed = closeErr == nil
		return closeErr
	}
	var records []probeCallEvidence
	if item.count != gatewayPublicToolCount {
		err = fmt.Errorf("facade gateway tools/list count=%d, expected=%d", item.count, gatewayPublicToolCount)
		if closeErr := closeOwned(); closeErr != nil {
			err = fmt.Errorf("%w; close owned facade: %v", err, closeErr)
		}
	} else {
		records, err = executeProbeSequence(ctx, item.session, calls, closeOwned)
	}
	evidence := map[string]any{
		"schemaVersion": 2, "family": family, "publicToolCount": item.count, "catalogToolCount": expectedCount,
		"sequenceCalls": records, "requestedCallCount": len(calls), "sequenceCompleted": err == nil,
		"cleanupPassed": cleanupPassed, "ownedProcessExitWaitMs": exitWait.Milliseconds(),
		"executionGuardWaitMs": guardWait.Milliseconds(), "facadeCloseWaitMs": wallWait.Milliseconds(),
		"capturedAt": time.Now().UTC().Format(time.RFC3339Nano),
	}
	if err != nil {
		evidence["error"] = err.Error()
	}
	if writeErr := writeProbeEvidence(output, evidence); writeErr != nil {
		return fmt.Errorf("sequence outcome %v; write evidence: %w", err, writeErr)
	}
	return err
}

func callWithFacadeHandoff(ctx context.Context, session *mcp.ClientSession, releasePrevious func() error, name string, arguments any, wait time.Duration) (*mcp.CallToolResult, bool, error) {
	type outcome struct {
		result *mcp.CallToolResult
		err    error
	}
	completed := make(chan outcome, 1)
	go func() {
		result, err := callInnerTool(ctx, session, name, arguments)
		completed <- outcome{result: result, err: err}
	}()
	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case value := <-completed:
		return value.result, false, value.err
	case <-timer.C:
		if err := releasePrevious(); err != nil {
			return nil, false, fmt.Errorf("close first facade for queued handoff: %w", err)
		}
		select {
		case value := <-completed:
			return value.result, true, value.err
		case <-ctx.Done():
			return nil, true, ctx.Err()
		}
	case <-ctx.Done():
		return nil, false, ctx.Err()
	}
}

func callInnerTool(ctx context.Context, session *mcp.ClientSession, name string, arguments any) (*mcp.CallToolResult, error) {
	encoded, err := json.Marshal(arguments)
	if err != nil {
		return nil, fmt.Errorf("encode inner tool arguments: %w", err)
	}
	gatewayArguments := map[string]any{"name": name}
	if string(encoded) == "{}" || string(encoded) == "null" {
		gatewayArguments["arguments"] = map[string]any{}
	} else {
		gatewayArguments["argumentsJson"] = string(encoded)
	}
	return session.CallTool(ctx, &mcp.CallToolParams{
		Name:      gatewayCallTool,
		Arguments: gatewayArguments,
	})
}

func connect(ctx context.Context, exe, family, projectRoot, catalog, helper string, idleTimeout time.Duration) (*probeSession, error) {
	command := facadeCommand(exe, family, projectRoot, catalog, helper, idleTimeout)
	stderr := &probeStderr{}
	command.Stderr = io.MultiWriter(os.Stderr, stderr)
	client := mcp.NewClient(&mcp.Implementation{Name: "itl-ondemand-live-probe", Version: "0.1.0"}, nil)
	session, err := client.Connect(ctx, &mcp.CommandTransport{Command: command, TerminateDuration: facadeTerminateDuration}, nil)
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
	return &probeSession{session: session, count: count, stderr: stderr}, nil
}

func facadeCommand(exe, family, projectRoot, catalog, helper string, idleTimeout time.Duration) *exec.Cmd {
	return exec.Command(exe, "serve", "--family", family, "--project-root", projectRoot, "--catalog", catalog, "--helper", helper, "--idle-timeout", idleTimeout.String(), "--cleanup-timeout", facadeCleanupTimeout.String())
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
	return waitForStateCountWithReader(root, count, timeout, readStates)
}

func waitForStateCountWithReader(root string, count int, timeout time.Duration, reader func(string) ([]runtimeState, error)) ([]runtimeState, error) {
	deadline := time.Now().Add(timeout)
	var lastReadErr error
	for {
		states, err := reader(root)
		if err == nil && len(states) == count {
			return states, nil
		}
		lastReadErr = err
		if !time.Now().Before(deadline) {
			if lastReadErr != nil {
				return nil, fmt.Errorf("runtime state read failed before expected count %d: %w", count, lastReadErr)
			}
			return nil, fmt.Errorf("runtime instance count=%d, expected=%d", len(states), count)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func validateInstanceHistory(family string, states []runtimeState, releasedResourceReuse bool) error {
	instanceIDs := map[string]bool{}
	runtimePIDs := map[int]bool{}
	runtimePorts := map[int]bool{}
	for _, state := range states {
		if state.InstanceID == "" || instanceIDs[state.InstanceID] || state.PID <= 0 || runtimePIDs[state.PID] {
			return fmt.Errorf("runtime history does not have distinct instance IDs and positive PIDs: %#v", states)
		}
		if state.Port <= 0 || (!releasedResourceReuse && runtimePorts[state.Port]) {
			return fmt.Errorf("concurrent runtime instances do not have distinct positive ports: %#v", states)
		}
		instanceIDs[state.InstanceID] = true
		runtimePIDs[state.PID] = true
		runtimePorts[state.Port] = true
	}
	if family != "vanessa-ui" {
		return nil
	}
	testClientPIDs := map[int]bool{}
	testClientPorts := map[int]bool{}
	for _, state := range states {
		if state.TestClientProfile != "itl-ondemand" || state.TestClientPort <= 0 || (!releasedResourceReuse && testClientPorts[state.TestClientPort]) {
			return fmt.Errorf("Vanessa runtime history does not have valid managed TestClient profile/ports: %#v", states)
		}
		if state.TestClientPID > 0 && (runtimePIDs[state.TestClientPID] || testClientPIDs[state.TestClientPID]) {
			return fmt.Errorf("Vanessa runtime history reuses a positive TestClient PID: %#v", states)
		}
		if state.TestClientPID > 0 {
			testClientPIDs[state.TestClientPID] = true
		}
		testClientPorts[state.TestClientPort] = true
	}
	return nil
}

func runVanessaSmoke(ctx context.Context, session *mcp.ClientSession, testClientPort int, featurePath, secondaryFeaturePath string, observeTestClient func(int)) (string, []string, error) {
	if featurePath == "" || secondaryFeaturePath == "" {
		return "", nil, fmt.Errorf("Vanessa authoring smoke requires --vanessa-feature and --vanessa-secondary-feature")
	}
	for _, path := range []string{featurePath, secondaryFeaturePath} {
		if !filepath.IsAbs(path) || !strings.Contains(path, " ") || !containsCyrillic(path) {
			return "", nil, fmt.Errorf("Vanessa authoring smoke requires absolute Windows paths containing spaces and Cyrillic text: %q", path)
		}
	}
	authoringCalls := make([]string, 0, 16)
	for _, call := range []struct {
		name      string
		arguments map[string]any
		proof     string
	}{
		{name: "run_scenario", arguments: map[string]any{"filePath": featurePath, "mode": "reloadAndRun"}, proof: "run_scenario:cold"},
		{name: "get_vanessa_automation_state", arguments: map[string]any{}, proof: "get_vanessa_automation_state:cold"},
		{name: "get_test_results", arguments: map[string]any{}, proof: "get_test_results:cold"},
		{name: "run_scenario", arguments: map[string]any{"filePath": featurePath, "mode": "reloadAndRun"}, proof: "run_scenario:hot"},
		{name: "get_vanessa_automation_state", arguments: map[string]any{}, proof: "get_vanessa_automation_state:hot"},
		{name: "get_test_results", arguments: map[string]any{}, proof: "get_test_results:hot"},
		{name: "run_scenario", arguments: map[string]any{"filePath": secondaryFeaturePath, "mode": "reloadAndRunFromLine", "lineNumber": 5}, proof: "run_scenario:from-line-cold"},
		{name: "get_vanessa_automation_state", arguments: map[string]any{}, proof: "get_vanessa_automation_state:from-line-cold"},
		{name: "get_test_results", arguments: map[string]any{}, proof: "get_test_results:from-line-cold"},
		{name: "open_feature_file", arguments: map[string]any{"filePath": secondaryFeaturePath}, proof: "open_feature_file:secondary"},
		{name: "check_syntax", arguments: map[string]any{"filePath": secondaryFeaturePath}, proof: "check_syntax:secondary"},
		{name: "load_features", arguments: map[string]any{"path": secondaryFeaturePath}, proof: "load_features:secondary"},
		{name: "select_scenario", arguments: map[string]any{"name": "MCP cold B"}, proof: "select_scenario:secondary"},
		{name: "run_scenario", arguments: map[string]any{"mode": "selected"}, proof: "run_scenario:selected"},
		{name: "get_vanessa_automation_state", arguments: map[string]any{}, proof: "get_vanessa_automation_state:selected"},
		{name: "get_test_results", arguments: map[string]any{}, proof: "get_test_results:selected"},
	} {
		result, err := callInnerTool(ctx, session, call.name, call.arguments)
		if err != nil {
			return "", nil, fmt.Errorf("Vanessa file smoke %s: %w", call.name, err)
		}
		if result == nil || result.IsError {
			return "", nil, fmt.Errorf("Vanessa file smoke %s returned a tool error: %#v", call.name, result)
		}
		authoringCalls = append(authoringCalls, call.proof)
	}
	var osWindows *mcp.CallToolResult
	for _, call := range []struct {
		name      string
		arguments any
	}{
		{name: "get_environment_data", arguments: map[string]any{}},
		{name: "manage_test_client", arguments: map[string]any{"action": "connect", "profileName": "itl-ondemand"}},
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
		if call.name == "manage_test_client" && observeTestClient != nil {
			observeTestClient(1)
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
	result, err = callInnerTool(ctx, session, "close_test_client", map[string]any{})
	if err != nil {
		return "", nil, fmt.Errorf("Vanessa smoke close_test_client: %w", err)
	}
	if result == nil || result.IsError {
		return "", nil, fmt.Errorf("Vanessa smoke close_test_client returned a tool error: %#v", result)
	}
	if observeTestClient != nil {
		observeTestClient(-1)
	}
	return "passed", authoringCalls, nil
}

type vanessaScenarioEvidence struct {
	Tool          string `json:"tool"`
	Outcome       string `json:"outcome"`
	ResultCode    string `json:"resultCode"`
	FeaturePath   string `json:"featurePath"`
	FeatureSHA256 string `json:"featureSha256"`
	ScenarioLine  int    `json:"scenarioLine"`
}

func validateVanessaScenarioEvidence(projectRoot, instanceID, featurePath, secondaryFeaturePath string) error {
	evidencePath := filepath.Join(projectRoot, ".agent-1c", "mcp", "ondemand", "vanessa-ui", instanceID+".evidence.jsonl")
	raw, err := os.ReadFile(evidencePath)
	if err != nil {
		return fmt.Errorf("read Vanessa scenario evidence: %w", err)
	}
	var actual []vanessaScenarioEvidence
	for _, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		var entry vanessaScenarioEvidence
		if strings.TrimSpace(line) == "" || json.Unmarshal([]byte(line), &entry) != nil {
			continue
		}
		if (entry.Tool == "run_scenario" || entry.Tool == "get_test_results") && entry.Outcome == "passed" {
			actual = append(actual, entry)
		}
	}
	expectedPaths := []string{featurePath, featurePath, featurePath, featurePath, secondaryFeaturePath, secondaryFeaturePath, secondaryFeaturePath, secondaryFeaturePath}
	expectedTools := []string{"run_scenario", "get_test_results", "run_scenario", "get_test_results", "run_scenario", "get_test_results", "run_scenario", "get_test_results"}
	expectedLines := []int{0, 0, 0, 0, 5, 5, 5, 5}
	if len(actual) < len(expectedTools) {
		return fmt.Errorf("Vanessa scenario evidence entries=%d, expected at least %d", len(actual), len(expectedTools))
	}
	actual = actual[len(actual)-len(expectedTools):]
	for index, entry := range actual {
		relative, err := filepath.Rel(projectRoot, expectedPaths[index])
		if err != nil || strings.HasPrefix(relative, "..") {
			return fmt.Errorf("Vanessa scenario feature is outside the release project: %q", expectedPaths[index])
		}
		featureRaw, err := os.ReadFile(expectedPaths[index])
		if err != nil {
			return fmt.Errorf("read Vanessa scenario feature: %w", err)
		}
		hash := sha256.Sum256(featureRaw)
		expectedSHA := fmt.Sprintf("%x", hash[:])
		if entry.Tool != expectedTools[index] || entry.Outcome != "passed" || entry.ResultCode != "ITL_OK" || entry.FeaturePath != filepath.ToSlash(relative) || entry.FeatureSHA256 != expectedSHA || entry.ScenarioLine != expectedLines[index] {
			return fmt.Errorf("Vanessa scenario evidence %d does not prove the expected passed feature path/SHA: %#v", index, entry)
		}
	}
	return nil
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
