package main

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func TestFirstOSWindowTitleUsesVanessaListResult(t *testing.T) {
	result := &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: "Для снятия скриншотов найдено 1 окон:\n  -dev_test / 1С:Предприятие"}}}
	if got := firstOSWindowTitle(result); got != "dev_test / 1С:Предприятие" {
		t.Fatalf("title=%q", got)
	}
}

func newProbeGatewaySession(t *testing.T, handler func(string, map[string]any) *mcp.CallToolResult) *mcp.ClientSession {
	t.Helper()
	server := mcp.NewServer(&mcp.Implementation{Name: "fake-gateway", Version: "1"}, nil)
	server.AddTool(&mcp.Tool{
		Name: gatewayCallTool,
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"name":      map[string]any{"type": "string"},
				"arguments": map[string]any{"type": "object"},
			},
			"required": []string{"name"},
		},
	}, func(_ context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		var call struct {
			Name      string         `json:"name"`
			Arguments map[string]any `json:"arguments"`
		}
		if err := json.Unmarshal(req.Params.Arguments, &call); err != nil {
			t.Fatalf("decode gateway call: %v", err)
		}
		return handler(call.Name, call.Arguments), nil
	})
	client := mcp.NewClient(&mcp.Implementation{Name: "probe-test", Version: "1"}, nil)
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
	})
	return clientSession
}

func successfulProbeResult(name string) *mcp.CallToolResult {
	text := name
	if name == "get_window_list_os" {
		text = "Для снятия скриншотов найдено 1 окон:\n  -PM5 / 1С:Предприятие"
	}
	return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: text}}}
}

func TestRunVanessaSmokeCoversFileDirectoryWindowsPathsAndStructuredErrorsBeforeUI(t *testing.T) {
	t.Setenv("ITL_VANESSA_ACCESS_DENIED_PROBE_PATH", `D:\Git\PM5 КОРП - work 1-perf1\tests\features\locked.feature`)
	type recordedCall struct {
		name      string
		arguments map[string]any
	}
	var calls []recordedCall
	session := newProbeGatewaySession(t, func(name string, arguments map[string]any) *mcp.CallToolResult {
		calls = append(calls, recordedCall{name: name, arguments: arguments})
		if name == "open_feature_file" && strings.Contains(arguments["filePath"].(string), "|invalid") {
			return &mcp.CallToolResult{IsError: true, StructuredContent: map[string]any{"code": "PATH_INVALID"}}
		}
		if name == "load_features" && strings.Contains(arguments["path"].(string), "Отсутствует") {
			return &mcp.CallToolResult{IsError: true, StructuredContent: map[string]any{"code": "PATH_NOT_FOUND"}}
		}
		if name == "check_syntax" && arguments["filePath"] != `D:\Git\PM5 КОРП - work 1-perf1\tests\features\Проверка пути.feature` {
			return &mcp.CallToolResult{IsError: true, StructuredContent: map[string]any{"code": "PATH_ACCESS_DENIED"}}
		}
		return successfulProbeResult(name)
	})

	featurePath := `D:\Git\PM5 КОРП - work 1-perf1\tests\features\Проверка пути.feature`
	outcome, codes, err := runVanessaSmoke(context.Background(), session, 48151, featurePath)
	if err != nil {
		t.Fatal(err)
	}
	if outcome != "passed" || strings.Join(codes, ",") != "PATH_INVALID,PATH_NOT_FOUND,PATH_ACCESS_DENIED" {
		t.Fatalf("outcome=%q codes=%#v", outcome, codes)
	}
	if len(calls) < 8 {
		t.Fatalf("calls=%#v", calls)
	}
	want := []struct {
		name string
		key  string
	}{
		{name: "open_feature_file", key: "filePath"},
		{name: "check_syntax", key: "filePath"},
		{name: "load_features", key: "path"},
		{name: "load_features", key: "path"},
	}
	for index, expected := range want {
		call := calls[index]
		if call.name != expected.name || len(call.arguments) != 1 {
			t.Fatalf("call %d changed file smoke order or arguments: %#v", index, call)
		}
		if index != 3 && call.arguments[expected.key] != featurePath {
			t.Fatalf("call %d changed feature path: %#v", index, call)
		}
		if index == 3 && call.arguments[expected.key] != `D:\Git\PM5 КОРП - work 1-perf1\tests\features` {
			t.Fatalf("directory load path=%#v", call.arguments)
		}
	}
	for index := 0; index < 7; index++ {
		if strings.HasPrefix(calls[index].name, "get_") || calls[index].name == "connect_test_client" {
			t.Fatalf("legacy/UI call ran before file probes completed: %#v", calls[index])
		}
	}
}

func TestRunVanessaSmokeRejectsFileAuthoringBackendFailure(t *testing.T) {
	session := newProbeGatewaySession(t, func(name string, _ map[string]any) *mcp.CallToolResult {
		if name == "open_feature_file" {
			return &mcp.CallToolResult{
				IsError:           true,
				StructuredContent: map[string]any{"code": "ITL_ONDEMAND_BACKEND_CALL_FAILED"},
			}
		}
		return successfulProbeResult(name)
	})

	outcome, codes, err := runVanessaSmoke(context.Background(), session, 48151, `D:\Git\PM5 КОРП\tests\features\Проверка пути.feature`)
	if err == nil || !strings.Contains(err.Error(), "open_feature_file returned a tool error") {
		t.Fatalf("unexpected error: %v", err)
	}
	if outcome != "" || codes != nil {
		t.Fatalf("outcome=%q codes=%#v", outcome, codes)
	}
}
