package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// reportsVanessaScenarioResult recognizes Vanessa's own scenario report
// (MCPVA ЗавершитьВыполненияСценария): the run reached the scenarios and the
// report states their outcome, including the text of a failed step.
func reportsVanessaScenarioResult(text string) bool {
	return strings.Contains(text, "## Результат выполнения сценариев:") ||
		strings.Contains(text, "Результат прохождения сценария:")
}

// vanessaToolNeedsLiveUIState reports whether a call acts on forms that an
// earlier call opened. run_scenario in modes all and reloadAndRun (all is the
// default) loads its feature and runs it from its own context.
func vanessaToolNeedsLiveUIState(name string, arguments any) bool {
	if classifyVanessaTool(name, arguments) != vanessaToolRuntime {
		return false
	}
	if name != "run_scenario" {
		return true
	}
	args, _ := arguments.(map[string]any)
	mode, _ := args["mode"].(string)
	return mode != "" && mode != "all" && mode != "reloadAndRun"
}

// attachTestClientReplacementNoticeLocked tells a self-contained call that it
// ran on a replacement TestClient; the pending notice is reported once.
func (r *runtime) attachTestClientReplacementNoticeLocked(result *mcp.CallToolResult) {
	if r.family != "vanessa-ui" || r.testClientReplacedPID <= 0 || result == nil {
		return
	}
	previous := r.testClientReplacedPID
	r.testClientReplacedPID = 0
	appendResultNote(result, fmt.Sprintf("ITL_VANESSA_TESTCLIENT_REPLACED: the TestClient was replaced before this call (PID %d exited; this call ran on PID %d), so forms opened by earlier calls were not available to it.", previous, r.testClientPID))
}

// appendFacadeNotes adds facade-level facts the agent needs next to the result
// it reads. They never change the outcome of the call.
func (r *runtime) appendFacadeNotes(toolName string, result *mcp.CallToolResult) {
	if result == nil {
		return
	}
	// PM5 2026-11-10: execute_feature_step reported a step with ВызватьИсключение
	// as executed. The backend answers before the step outcome is known.
	if r.family == "vanessa-ui" && toolName == "execute_feature_step" && !result.IsError {
		appendResultNote(result, "ITL note: execute_feature_step reports that Vanessa accepted the step, not that it succeeded; prove the behaviour with run_scenario or form data.")
	}
	if note := r.facadeSupersededNote(); note != "" {
		appendResultNote(result, note)
	}
}

// facadeSupersededNote compares this running process with the facade version
// the project now pins. An update replaces the configured executable, but the
// MCP client keeps the process it started until it reconnects.
func (r *runtime) facadeSupersededNote() string {
	if r.compatibilityPath == "" {
		return ""
	}
	raw, err := os.ReadFile(r.compatibilityPath)
	if err != nil {
		return ""
	}
	var manifest struct {
		FacadeVersion string `json:"facadeVersion"`
	}
	if json.Unmarshal(raw, &manifest) != nil || manifest.FacadeVersion == "" || manifest.FacadeVersion == version {
		return ""
	}
	return fmt.Sprintf("ITL_ONDEMAND_FACADE_SUPERSEDED: this %s facade process runs version %s, while the project now pins %s. This call was handled by the running process; reconnect this MCP server in the client (or start a new chat) to load the pinned facade.", r.family, version, manifest.FacadeVersion)
}

func appendResultNote(result *mcp.CallToolResult, text string) {
	result.Content = append(result.Content, &mcp.TextContent{Text: text})
}
