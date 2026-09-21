//go:build windows

package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestProfileOwnerFinalResponseSurvivesExitDuringInspection(t *testing.T) {
	for _, persist := range []bool{true, false} {
		t.Run(fmt.Sprintf("response-persisted-%t", persist), func(t *testing.T) {
			state := &profileOwnerState{ProjectRoot: t.TempDir(), Generation: strings.Repeat("b", 32), CallerID: "test-caller"}
			request := profileOwnerRequest{RequestID: strings.Repeat("c", 32)}
			checks := 0
			response, err := awaitProfileOwnerResponseWithLiveness(context.Background(), state, request, func(*profileOwnerState) (bool, error) {
				checks++
				if persist {
					value := profileOwnerResponse{SchemaVersion: 1, Generation: state.Generation, RequestID: request.RequestID, Status: "stopped", CleanupConfirmed: true}
					if err := writeProfileJSON(profileControlPath(profileOwnerRoot(state.ProjectRoot), state.Generation, "responses", request.RequestID), value); err != nil {
						t.Fatal(err)
					}
				}
				return false, nil
			})
			if checks != 1 {
				t.Fatalf("exit must trigger one final read, got %d process inspections", checks)
			}
			if persist {
				if err != nil || response == nil || response.Status != "stopped" || !response.CleanupConfirmed {
					t.Fatalf("persisted stop lost during exit: response=%+v error=%v", response, err)
				}
			} else if err == nil || !strings.Contains(err.Error(), "ITL_PROFILE_OWNER_EXITED_UNCONFIRMED") {
				t.Fatalf("missing final response must retain uncertainty: %+v %v", response, err)
			}
		})
	}
}

func waitProfileState(t *testing.T, root string, predicate func(*profileOwnerState) bool) *profileOwnerState {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		state, err := readProfileOwnerState(root)
		if err == nil && predicate(state) {
			return state
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("owner did not reach the expected control state")
	return nil
}

func TestProfileCallerIdentityResolution(t *testing.T) {
	t.Setenv("CODEX_THREAD_ID", "chat-a")
	first, err := resolveProfileCaller("", true)
	if err != nil || first != "codex:chat-a" {
		t.Fatal(first, err)
	}
	second, err := resolveProfileCaller("", false)
	if err != nil || second != first {
		t.Fatal(second, err)
	}
}

func TestProfileOwnerRejectsForeignStopAndCompletesOwnedStop(t *testing.T) {
	root := t.TempDir()
	feature := filepath.Join(root, "Сценарий с пробелом.feature")
	if err := os.WriteFile(feature, []byte("# fixture"), 0o600); err != nil {
		t.Fatal(err)
	}
	config := profileOwnerConfig{ProjectRoot: root, InstanceID: strings.Repeat("a", 32),
		Generation: strings.Repeat("b", 32), CallerID: "owner"}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var stops atomic.Int32
	done := make(chan error, 1)
	go func() {
		done <- serveProfileOwner(ctx, config, profileOwnerCallbacks{
			Open: func(context.Context, string) (*vanessaProfileResult, error) {
				return &vanessaProfileResult{SchemaVersion: 1, Status: "running", InstanceID: config.InstanceID,
					ManagerPID: os.Getpid(), TestClientPID: os.Getpid(), FeaturePath: feature}, nil
			},
			Stop: func(context.Context) error { stops.Add(1); return nil },
		})
	}()
	state := waitProfileState(t, root, func(value *profileOwnerState) bool { return value.Status == "ready" })
	requestCtx, requestCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer requestCancel()
	if _, err := requestProfileOwner(requestCtx, state, "stop", "", "foreign"); err == nil || !strings.Contains(err.Error(), "CALLER_MISMATCH") {
		t.Fatal("foreign caller stopped the profile", err)
	}
	response, err := requestProfileOwner(requestCtx, state, "stop", "", "owner")
	if err != nil || response.Status != "stopped" || !response.CleanupConfirmed {
		t.Fatal(response, err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if stops.Load() != 1 {
		t.Fatalf("stop calls=%d", stops.Load())
	}
}
