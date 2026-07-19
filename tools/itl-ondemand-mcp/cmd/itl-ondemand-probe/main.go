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
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type runtimeState struct {
	InstanceID string `json:"instanceId"`
	PID        int    `json:"pid"`
	Port       int    `json:"port"`
}

type probeSession struct {
	session *mcp.ClientSession
	count   int
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
	instances := flag.Int("instances", 1, "number of simultaneous facade clients")
	output := flag.String("output", "", "evidence JSON path")
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
	defer func() {
		for _, item := range connected {
			_ = item.session.Close()
		}
	}()
	for index := 0; index < *instances; index++ {
		item, err := connect(ctx, *exe, *family, *projectRoot, *catalog, *helper)
		if err != nil {
			return err
		}
		connected = append(connected, item)
		if item.count != expectedCount {
			return fmt.Errorf("facade tools/list count=%d, catalog count=%d", item.count, expectedCount)
		}
		result, err := item.session.CallTool(ctx, &mcp.CallToolParams{Name: *tool, Arguments: arguments})
		if err != nil {
			return fmt.Errorf("call %s: %w", *tool, err)
		}
		if result.IsError {
			return fmt.Errorf("call %s returned a tool error: %#v", *tool, result.StructuredContent)
		}
	}

	runtimeRoot := filepath.Join(*projectRoot, ".agent-1c", "mcp", "ondemand", *family)
	states, err := waitForStateCount(runtimeRoot, *instances, 30*time.Second)
	if err != nil {
		return err
	}
	if err := distinctInstances(states); err != nil {
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
		result, err := connected[0].session.CallTool(ctx, &mcp.CallToolParams{Name: *tool, Arguments: arguments})
		if err != nil || result.IsError {
			return fmt.Errorf("second facade stopped with the first: err=%v result=%#v", err, result)
		}
		secondSurvived = true
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
		"schemaVersion": 1, "family": *family, "toolCount": expectedCount,
		"tool": *tool, "instances": initial, "secondSurvivedFirstClose": secondSurvived,
		"cleanupPassed": true, "capturedAt": time.Now().UTC().Format(time.RFC3339Nano),
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

func connect(ctx context.Context, exe, family, projectRoot, catalog, helper string) (*probeSession, error) {
	command := exec.Command(exe, "serve", "--family", family, "--project-root", projectRoot, "--catalog", catalog, "--helper", helper, "--idle-timeout", "10m")
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

func distinctInstances(states []runtimeState) error {
	pids := map[int]bool{}
	ports := map[int]bool{}
	for _, state := range states {
		if state.PID <= 0 || state.Port <= 0 || pids[state.PID] || ports[state.Port] {
			return fmt.Errorf("runtime instances do not have distinct positive PID/port values: %#v", states)
		}
		pids[state.PID] = true
		ports[state.Port] = true
	}
	return nil
}
