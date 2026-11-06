package main

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type progressSnapshot struct {
	Progress   float64
	Total      float64
	Message    string
	ReceivedAt time.Time
}

func (route *progressRoute) recordProgress(params *mcp.ProgressNotificationParams) {
	if route == nil || params == nil {
		return
	}
	route.lastMu.Lock()
	defer route.lastMu.Unlock()
	route.received++
	route.last = &progressSnapshot{Progress: params.Progress, Total: params.Total, Message: params.Message, ReceivedAt: time.Now().UTC()}
}

func (route *progressRoute) lastProgress() (*progressSnapshot, uint64) {
	if route == nil {
		return nil, 0
	}
	route.lastMu.Lock()
	defer route.lastMu.Unlock()
	if route.last == nil {
		return nil, route.received
	}
	snapshot := *route.last
	return &snapshot, route.received
}

func phaseDeadlineExceeded(ctx context.Context, err error) bool {
	return errors.Is(err, context.DeadlineExceeded) || (ctx != nil && errors.Is(ctx.Err(), context.DeadlineExceeded))
}

// The request phase expired while the backend still owned the call. The facade
// has already stopped that backend, so its own result store is gone; only the
// last progress received here can say how far the call got.
func phaseDeadlineFailure(toolName string, err error, route *progressRoute, mutating bool) *mcp.CallToolResult {
	last, received := route.lastProgress()
	details := map[string]any{
		"callOutcome": "unknown", "reason": "phase-deadline-exceeded", "tool": toolName,
		"partialEffectsPossible": mutating, "automaticRetryPerformed": false,
		"backendStopped": true, "backendResultsRetained": false,
		"progressTokenProvided": route != nil, "progressNotificationsReceived": received,
	}
	message := err.Error() + "; call outcome unknown: the request phase deadline expired before the backend answered"
	switch {
	case last != nil:
		progress := map[string]any{"progress": last.Progress, "message": last.Message, "receivedAt": last.ReceivedAt.Format(time.RFC3339Nano)}
		if last.Total > 0 {
			progress["total"] = last.Total
		}
		details["lastProgress"] = progress
		message += "; last progress: " + describeProgress(last)
	case route == nil:
		message += "; no progress was requested (call without progressToken)"
	default:
		message += "; no progress notification was received"
	}
	if mutating {
		details["action"] = "probe-state-read-only-before-retry"
		message += "; the operation may be fully, partially or not applied" +
			"; the facade stopped the owned backend, so get_test_results cannot report this call" +
			"; probe the affected state read-only before any retry and repeat only what is missing"
	} else {
		details["action"] = "retry-tool-call"
		message += "; the facade stopped the owned backend; the tool is read-only, so a retry is safe"
	}
	return toolError("ITL_ONDEMAND_BACKEND_CALL_FAILED", message, details)
}

func describeProgress(last *progressSnapshot) string {
	text := "step " + formatProgressNumber(last.Progress)
	if last.Total > 0 {
		text += "/" + formatProgressNumber(last.Total)
	}
	if message := strings.TrimSpace(last.Message); message != "" {
		text += " (" + message + ")"
	}
	return text + " at " + last.ReceivedAt.Format(time.RFC3339)
}

func formatProgressNumber(value float64) string {
	if value == float64(int64(value)) {
		return fmt.Sprintf("%d", int64(value))
	}
	return fmt.Sprintf("%g", value)
}

// Vanessa raises a disconnected TestClient as an ACTION_FAILED protocol error.
// Only the explicit TestClient wording qualifies; generic transport text such
// as "no connection" stays a backend call failure.
func protocolErrorReportsTestClientDisconnected(err error) bool {
	if err == nil {
		return false
	}
	normalized := strings.ToLower(err.Error())
	for _, marker := range []string{
		"клиент тестирования не подключ",
		"testclient не подключ",
		"test client is not connected",
		"testclient is not connected",
	} {
		if strings.Contains(normalized, marker) {
			return true
		}
	}
	return false
}

func testClientDisconnectedFailure(toolName string, err error) *mcp.CallToolResult {
	return toolError("ITL_VANESSA_TESTCLIENT_NOT_CONNECTED",
		"Vanessa reported that the TestClient is not connected; call "+ownerRecoveryTool+
			" with arguments {} before the next UI call; the failed call was not replayed",
		map[string]any{
			"tool": toolName, "cause": err.Error(), "action": ownerRecoveryTool, "recoveryTool": ownerRecoveryTool,
			"automaticRetryPerformed": false, "continuation": connectionRecoveryContinuation,
		})
}
