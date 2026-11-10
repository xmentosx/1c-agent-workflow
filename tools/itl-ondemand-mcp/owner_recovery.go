package main

import (
	"context"
	"encoding/json"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const ownerRecoveryTool = "itl_recover_connection"

const connectionRecoveryContinuation = "Recover the connection, inspect the operation's observable result, then continue: reuse a completed result; retry when not applied or safe to repeat. Ask the user only for a remaining concrete consequential choice that cannot be resolved from evidence. Unknown outcome alone is not an approval barrier."

func ownerRecoveryDefinition() *mcp.Tool {
	return &mcp.Tool{
		Name:        ownerRecoveryTool,
		Description: "Recover or restart this facade's owned backend connection after connection or cleanup failure. Confirms exact owned cleanup, then initializes a usable backend. Never replays a previous tool call or stops a foreign owner.",
		InputSchema: map[string]any{"type": "object", "properties": map[string]any{}, "additionalProperties": false},
		Annotations: &mcp.ToolAnnotations{IdempotentHint: true, DestructiveHint: gatewayBool(false), OpenWorldHint: gatewayBool(false)},
	}
}

func (r *runtime) recoverConnection(ctx context.Context, meta mcp.Meta, arguments any) *mcp.CallToolResult {
	input, ok := arguments.(map[string]any)
	if !ok || len(input) != 0 {
		return toolError("ITL_ONDEMAND_ARGUMENTS_INVALID", ownerRecoveryTool+" accepts only an empty object", nil)
	}
	// callNamed already owns the bounded request phase, including any shorter
	// caller deadline. Cleanup/admission/cold readiness consume that one budget;
	// recovery must neither truncate it to one minute nor restart it.
	// An unconfirmed stop no longer blocks recovery: that execution already
	// dropped the old backend and released the infobase, so a new backend is
	// started below and the leftover is reported, never retained.
	stopErr := r.stopWithMeta(ctx, meta)
	if stopErr != nil {
		r.mu.Lock()
		r.writeLifecycleEvidenceLocked(ownerRecoveryTool, "stop", "ITL_ONDEMAND_RECOVERY_ACTION_REQUIRED", stopErr)
		r.mu.Unlock()
	}
	ctx, finish, err := r.beginDatabaseCall(ctx, meta)
	if err != nil {
		return recoveryAction(ownerRecoveryTool, r.instanceID, r.instanceID, false, "not-started", err)
	}
	r.mu.Lock()
	r.generation++
	r.mismatch = nil
	err = r.ensureLocked(ctx)
	id := r.instanceID
	if err == nil {
		r.completeCallLocked()
	} else {
		r.writeLifecycleEvidenceLocked(ownerRecoveryTool, "start", "ITL_ONDEMAND_RECOVERY_ACTION_REQUIRED", err)
	}
	r.mu.Unlock()
	terminal, message := "succeeded", ""
	if err != nil {
		terminal, message = "failed", err.Error()
	}
	finishErr := finish(terminal, message)
	if err == nil {
		err = finishErr
	}
	if err != nil {
		return recoveryAction(ownerRecoveryTool, id, id, false, "not-started", err)
	}
	payload := map[string]any{"code": "ITL_OK", "family": r.family, "instanceId": id,
		"backendRecovered": true, "cleanupConfirmed": stopErr == nil, "previousCallReplayed": false}
	if stopErr != nil {
		payload["previousBackendCleanup"] = "unconfirmed; run " + branchHolderRepairAction + " if leftover 1C processes of this worktree still block the base"
	}
	encoded, _ := json.Marshal(payload)
	return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: string(encoded)}}, StructuredContent: payload}
}
