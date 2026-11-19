package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func TestVanessaScenarioReportKeepsItsFailedStep(t *testing.T) {
	// PM5 2026-11-17: a cell check failed with a product error that contains a
	// facade marker; the scenario report must reach the agent unchanged.
	report := "## Результат выполнения сценариев: были ошибки\n\nИмя сценария: Ячейки плана\nРезультат прохождения сценария: Failed\n" +
		"Текст ошибки: Значение не является значением объектного типа (ИсходныеДанные)"
	if marker := vanessaSemanticFailureMarker("run_scenario", report); marker != "" {
		t.Fatalf("scenario report was classified as a tool failure: %q", marker)
	}
	if marker := vanessaSemanticFailureMarker("get_test_results", report); marker != "" {
		t.Fatalf("test results report was classified as a tool failure: %q", marker)
	}
	editor := "Ошибка доступа к редактору: Значение не является значением объектного типа"
	for _, name := range []string{"open_feature_file", "run_scenario"} {
		if marker := vanessaSemanticFailureMarker(name, editor); marker == "" {
			t.Fatalf("%s editor failure without a scenario report lost its marker", name)
		}
	}
}

func TestVanessaToolNeedsLiveUIState(t *testing.T) {
	cases := []struct {
		name      string
		arguments map[string]any
		want      bool
	}{
		{"execute_form_actions", map[string]any{}, true},
		{"get_form_element_data", map[string]any{}, true},
		{"run_scenario", map[string]any{}, false},
		{"run_scenario", map[string]any{"mode": "all"}, false},
		{"run_scenario", map[string]any{"mode": "reloadAndRun"}, false},
		{"run_scenario", map[string]any{"mode": "reloadAndRunFromLine"}, true},
		{"run_scenario", map[string]any{"mode": "selected"}, true},
		{"run_scenario", map[string]any{"mode": "fromCurrentStep"}, true},
		{"get_window_list_os", map[string]any{}, false},
		{"close_test_client", map[string]any{}, false},
	}
	for _, c := range cases {
		if got := vanessaToolNeedsLiveUIState(c.name, c.arguments); got != c.want {
			t.Fatalf("%s %v: got %v want %v", c.name, c.arguments, got, c.want)
		}
	}
}

func TestFacadeSupersededNoteNamesThePinnedVersion(t *testing.T) {
	root := filepath.Join(t.TempDir(), "проект с пробелом")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "compatibility.json")
	rt := &runtime{family: "vanessa-ui", compatibilityPath: path}
	if note := rt.facadeSupersededNote(); note != "" {
		t.Fatalf("missing manifest produced a note: %q", note)
	}
	if err := os.WriteFile(path, []byte(`{"facadeVersion":"`+version+`"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if note := rt.facadeSupersededNote(); note != "" {
		t.Fatalf("current facade produced a note: %q", note)
	}
	if err := os.WriteFile(path, []byte(`{"facadeVersion":"9.9.9"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	note := rt.facadeSupersededNote()
	if !strings.HasPrefix(note, "ITL_ONDEMAND_FACADE_SUPERSEDED:") || !strings.Contains(note, "version "+version) || !strings.Contains(note, "pins 9.9.9") {
		t.Fatalf("unexpected superseded note: %q", note)
	}
	result := &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: "ok"}}}
	rt.appendFacadeNotes("get_window_list_os", result)
	if resultText(result) != "ok\n"+note {
		t.Fatalf("note was not appended to the handled call: %q", resultText(result))
	}
}

func TestExecuteFeatureStepSuccessIsMarkedAsUnproven(t *testing.T) {
	rt := &runtime{family: "vanessa-ui"}
	result := &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: "Шаг в строке фича файла успешно выполнен"}}}
	rt.appendFacadeNotes("execute_feature_step", result)
	if !strings.Contains(resultText(result), "not that it succeeded") {
		t.Fatalf("execute_feature_step success was not marked: %q", resultText(result))
	}
	failed := toolError("ITL_VANESSA_TOOL_RESULT_FAILED", "failed", nil)
	before := resultText(failed)
	rt.appendFacadeNotes("execute_feature_step", failed)
	if resultText(failed) != before {
		t.Fatalf("a failed step received the success note: %q", resultText(failed))
	}
}

func TestRuntimeVanessaReplacedTestClientRefusesStateDependentCallOnce(t *testing.T) {
	// PM5 2026-11-16/17: after the TestClient was replaced between calls, form
	// input reported success on a fresh client whose forms were gone.
	connectCalls := 0
	calls := map[string]int{}
	tools := append(vanessaIntegrationTools(), &mcp.Tool{Name: "execute_form_actions", InputSchema: map[string]any{"type": "object"}})
	backend := newVanessaBackendObservedWithTools(t, tools, "VanessaExt: Истина", []string{"TestClient подключен"}, "Окно: Главное", &connectCalls, calls)
	broker := &fakeBroker{info: &backendInfo{URL: backend.URL, TestClientProfile: "itl-ondemand", TestClientPort: 48151}}
	_, session := newFacadeSessionForFamily(t, "vanessa-ui", tools, broker, time.Minute, nil)
	call := func(name string, arguments map[string]any) *mcp.CallToolResult {
		t.Helper()
		result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: name, Arguments: arguments})
		if err != nil {
			t.Fatal(err)
		}
		return result
	}
	replaceClient := func(previous, next int) {
		broker.mu.Lock()
		broker.info.TestClientPID = next
		broker.info.PreviousTestClientPID = previous
		broker.info.PreviousTestClientState = testClientExited
		broker.mu.Unlock()
	}

	if result := call("execute_form_actions", map[string]any{}); result.IsError {
		t.Fatalf("first form call failed: %s", resultText(result))
	}
	replaceClient(808, 909)
	refused := call("execute_form_actions", map[string]any{})
	assertToolErrorCode(t, refused, "ITL_VANESSA_TESTCLIENT_REPLACED")
	if !strings.Contains(resultText(refused), "PID 808 exited") || !strings.Contains(resultText(refused), "run_scenario") {
		t.Fatalf("refusal lacks its continuation: %s", resultText(refused))
	}
	if calls["execute_form_actions"] != 1 {
		t.Fatalf("refused call reached the backend: %#v", calls)
	}
	// The continuation: the same facade serves the next call on the new client.
	if result := call("execute_form_actions", map[string]any{}); result.IsError || calls["execute_form_actions"] != 2 {
		t.Fatalf("call after the notice did not run: %s %#v", resultText(result), calls)
	}

	// A self-contained scenario runs on a replacement and states it.
	replaceClient(909, 1010)
	scenario := call("run_scenario", map[string]any{"mode": "reloadAndRun"})
	if scenario.IsError || calls["run_scenario"] != 1 || !strings.Contains(resultText(scenario), "ITL_VANESSA_TESTCLIENT_REPLACED: the TestClient was replaced before this call (PID 909 exited") {
		t.Fatalf("self-contained scenario was not run with a notice: %s %#v", resultText(scenario), calls)
	}
	if result := call("execute_form_actions", map[string]any{}); result.IsError {
		t.Fatalf("notice was reported twice: %s", resultText(result))
	}

	// A client the agent closed itself is expected to be new.
	if result := call("close_test_client", map[string]any{}); result.IsError {
		t.Fatalf("close_test_client failed: %s", resultText(result))
	}
	replaceClient(1010, 1111)
	if result := call("execute_form_actions", map[string]any{}); result.IsError {
		t.Fatalf("agent-closed client was reported as replaced: %s", resultText(result))
	}
}
