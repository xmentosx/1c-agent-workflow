package main

import (
	"context"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const (
	roctupCloseSessionTool   = "close_1c_session"
	roctupRestartSessionTool = "restart_1c_session"
)

// ROCTUP's own close/restart would end or replace the backend process behind
// the facade's registration, which then names a dead PID (and a restart a new
// one) until a lifecycle drain meets it. The facade owns that process, so it
// performs these tools itself through the owned stop and the normal start.
func isFacadeSessionLifecycleTool(family, toolName string) bool {
	return family == "roctup" && (toolName == roctupCloseSessionTool || toolName == roctupRestartSessionTool)
}

func (r *runtime) callSessionLifecycleLocked(ctx context.Context, toolName string, arguments any, progressTokenProvided bool) *mcp.CallToolResult {
	instanceID, backend := r.instanceID, r.backend
	r.writeEvidenceLocked(toolName, arguments, "started", "ITL_ONDEMAND_CALL_STARTED", "facade-owned 1C session lifecycle", instanceID, backend, progressTokenProvided, 0)
	fail := func(code string, err error) *mcp.CallToolResult {
		result := toolError(code, err.Error(), map[string]any{
			"tool": toolName, "callOutcome": "unknown", "automaticRetryPerformed": false,
			"action": ownerRecoveryTool, "continuation": connectionRecoveryContinuation,
		})
		r.writeEvidenceLocked(toolName, arguments, "failed", code, resultEvidenceMessage(result, nil), instanceID, backend, progressTokenProvided, 0)
		r.completeCallLocked()
		return result
	}
	if err := r.stopDatabaseBackendLocked(ctx, true); err != nil {
		// cleanupUnconfirmed makes the end of this execution drop the backend
		// and release the guard; the next call starts a fresh backend.
		return fail("ITL_ONDEMAND_STOP_FAILED", err)
	}
	text := "The ITL facade closed this 1C session. The next tool call starts a new session automatically; no launcher command is needed."
	if toolName == roctupRestartSessionTool {
		if err := r.ensureLocked(ctx); err != nil {
			return fail("ITL_ONDEMAND_START_FAILED", err)
		}
		text = "The ITL facade restarted this 1C session as a new backend instance; it is ready for the next tool call."
	}
	result := &mcp.CallToolResult{
		Content:           []mcp.Content{&mcp.TextContent{Text: text}},
		StructuredContent: map[string]any{"success": true, "facadeHandled": true, "tool": toolName},
	}
	r.writeEvidenceLocked(toolName, arguments, "passed", "ITL_OK", "", r.instanceID, r.backend, progressTokenProvided, 0)
	r.completeCallLocked()
	return result
}
