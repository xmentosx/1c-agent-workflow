package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// This is a per-facade mailbox, not database admission authority. Only the
// original runtime can use its retained signed execution to perform cleanup.
type connectionControlState struct {
	SchemaVersion int                    `json:"schemaVersion"`
	ProjectRoot   string                 `json:"projectRoot"`
	Family        string                 `json:"family"`
	InstanceID    string                 `json:"instanceId"`
	Generation    string                 `json:"generation"`
	Process       profileProcessIdentity `json:"process"`
}

type connectionControlRequest struct {
	Generation string   `json:"generation"`
	RequestID  string   `json:"requestId"`
	Resources  []string `json:"resources"`
}

type connectionControlResponse struct {
	Generation       string `json:"generation"`
	RequestID        string `json:"requestId"`
	CleanupConfirmed bool   `json:"cleanupConfirmed"`
	Busy             bool   `json:"busy,omitempty"`
	Error            string `json:"error,omitempty"`
}

func connectionControlRoot(projectRoot, family string) string {
	return filepath.Join(projectRoot, ".agent-1c", "mcp", "ondemand", family, "connections")
}

func (r *runtime) startConnectionControl(ctx context.Context) (func(), error) {
	identity, err := readProfileProcessIdentity(os.Getpid())
	if err != nil {
		return nil, err
	}
	generation, err := randomID()
	if err != nil {
		return nil, err
	}
	dir := filepath.Join(connectionControlRoot(r.projectRoot, r.family), generation)
	state := connectionControlState{1, r.projectRoot, r.family, r.instanceID, generation, identity}
	if err := writeProfileJSON(filepath.Join(dir, "owner.json"), state); err != nil {
		return nil, err
	}
	controlCtx, cancel := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() {
		defer close(done)
		ticker := time.NewTicker(200 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-controlCtx.Done():
				return
			case <-ticker.C:
			}
			entries, _ := filepath.Glob(filepath.Join(dir, "requests", "request-*.json"))
			for _, path := range entries {
				if controlCtx.Err() != nil {
					return
				}
				var request connectionControlRequest
				raw, err := os.ReadFile(path)
				if err != nil || json.Unmarshal(raw, &request) != nil || request.Generation != generation ||
					!executionIDPattern.MatchString(request.RequestID) || filepath.Base(path) != "request-"+request.RequestID+".json" {
					continue
				}
				responsePath := filepath.Join(dir, "responses", "response-"+request.RequestID+".json")
				if _, err := os.Stat(responsePath); err == nil {
					continue
				}
				response := connectionControlResponse{Generation: generation, RequestID: request.RequestID}
				// Never cancel a running call merely because another chat needs
				// the same base. The existing gate fences this check and stop.
				r.databaseGateOnce.Do(func() { r.databaseGate = make(chan struct{}, 1) })
				select {
				case r.databaseGate <- struct{}{}:
					unlock := func() { <-r.databaseGate }
					r.mu.Lock()
					pending := r.cleanupUnconfirmed && r.executionOwner != nil && sameResourceSet(r.executionOwner.Proof.Resources, request.Resources)
					r.mu.Unlock()
					if pending {
						cleanup, stop := context.WithTimeout(controlCtx, time.Minute)
						err = r.stopWithLocalGate(cleanup, nil, unlock)
						stop()
						response.CleanupConfirmed = err == nil
						if err != nil {
							response.Error = resultEvidenceMessage(nil, err)
						}
					} else {
						unlock()
						response.Busy = true
					}
				default:
					response.Busy = true
				}
				_ = writeProfileJSON(responsePath, response)
				_ = os.Remove(path)
			}
		}
	}()
	return func() { cancel(); <-done; _ = os.RemoveAll(dir) }, nil
}

func recoverPeerConnection(ctx context.Context, state connectionControlState, root, family string, resources []string) (bool, error) {
	if state.SchemaVersion != 1 || !executionIDPattern.MatchString(state.Generation) ||
		!executionIDPattern.MatchString(state.InstanceID) || !strings.EqualFold(filepath.Clean(state.ProjectRoot), filepath.Clean(root)) ||
		state.Family != family || state.Process.PID == os.Getpid() {
		return false, nil
	}
	actual, err := readProfileProcessIdentity(state.Process.PID)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if actual != state.Process {
		return false, nil
	}
	id, err := randomID()
	if err != nil {
		return false, err
	}
	dir := filepath.Join(connectionControlRoot(root, family), state.Generation)
	requestPath := filepath.Join(dir, "requests", "request-"+id+".json")
	if err := writeProfileJSON(requestPath, connectionControlRequest{state.Generation, id, resources}); err != nil {
		return false, err
	}
	defer os.Remove(requestPath)
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	for {
		responsePath := filepath.Join(dir, "responses", "response-"+id+".json")
		if raw, err := os.ReadFile(responsePath); err == nil {
			var response connectionControlResponse
			if json.Unmarshal(raw, &response) != nil || response.Generation != state.Generation || response.RequestID != id {
				return false, fmt.Errorf("ITL_ONDEMAND_CONNECTION_RESPONSE_INVALID")
			}
			_ = os.Remove(responsePath)
			if response.Error != "" {
				return false, errors.New(response.Error)
			}
			return response.CleanupConfirmed, nil
		}
		select {
		case <-ctx.Done():
			return false, ctx.Err()
		case <-ticker.C:
		}
	}
}

func (r *runtime) recoverPeerConnections(ctx context.Context, resources []string) error {
	paths, err := filepath.Glob(filepath.Join(connectionControlRoot(r.projectRoot, r.family), "*", "owner.json"))
	if err != nil {
		return err
	}
	for _, path := range paths {
		var state connectionControlState
		raw, err := os.ReadFile(path)
		if err != nil || json.Unmarshal(raw, &state) != nil || filepath.Base(filepath.Dir(path)) != state.Generation {
			continue
		}
		// A silent/broken mailbox must not consume the entire original call.
		peerCtx, cancel := context.WithTimeout(ctx, time.Minute)
		_, err = recoverPeerConnection(peerCtx, state, r.projectRoot, r.family, resources)
		cancel()
		if err != nil {
			r.logger.Warn("peer connection cleanup", "error", err)
		}
	}
	return nil
}

func sameResourceSet(a, b []string) bool {
	if len(a) == 0 || len(a) != len(b) {
		return false
	}
	seen := map[string]bool{}
	for _, value := range a {
		seen[value] = true
	}
	for _, value := range b {
		if !seen[value] {
			return false
		}
		delete(seen, value)
	}
	return len(seen) == 0
}
