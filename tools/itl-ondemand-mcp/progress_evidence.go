package main

import (
	"encoding/json"
	"os"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func progressEvidenceID(route *progressRoute) string {
	if route == nil {
		return ""
	}
	return route.id
}

// MCP notification handlers may finish after CallTool returns. Record successful
// forwarding as its own event instead of claiming the final response's snapshot
// is a complete count. Do not persist arbitrary progress text or caller tokens.
func (r *runtime) writeProgressEvidence(route *progressRoute, count uint64) {
	if r.suppressEvidence {
		return
	}
	entry := map[string]any{"schemaVersion": 1, "progressEvidenceId": route.id,
		"tool": route.tool, "outcome": "progress-forwarded", "forwardedCount": count,
		"recordedAt": time.Now().UTC().Format(time.RFC3339Nano)}
	raw, _ := json.Marshal(entry)
	r.progressWriteMu.Lock()
	defer r.progressWriteMu.Unlock()
	file, err := os.OpenFile(route.path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err == nil {
		_, err = file.Write(append(raw, '\n'))
		_ = file.Close()
	}
	if err != nil {
		r.logger.Error("write progress evidence", "error", err)
	}
}

// Retain late-notification routes for their backend session's lifetime. Distinct
// internal tokens isolate consecutive calls that reuse the same caller token.
func (r *runtime) clearProgress(session *mcp.ClientSession) {
	r.progressMu.Lock()
	defer r.progressMu.Unlock()
	for key, route := range r.progress {
		if route.backend == session {
			delete(r.progress, key)
		}
	}
}
