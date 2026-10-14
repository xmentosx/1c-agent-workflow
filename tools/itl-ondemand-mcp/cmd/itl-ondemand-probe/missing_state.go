package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type missingStateRecoveryEvidence struct {
	Passed                bool         `json:"passed"`
	Original              runtimeState `json:"original"`
	OriginalRecordSHA256  string       `json:"originalRecordSha256"`
	Replacement           runtimeState `json:"replacement"`
	SameConnection        bool         `json:"sameConnection"`
	OriginalProcessesGone bool         `json:"originalProcessesGone"`
	Calls                 []string     `json:"calls"`
}

func verifySessionMissingStateRecovery(ctx context.Context, root string, bound runtimeState,
	call func(string, any) (*mcp.CallToolResult, error), exited func(context.Context, []int) error,
) (*missingStateRecoveryEvidence, error) {
	// Smoke can legitimately outlive an idle generation. Bind the same
	// session's current native processes immediately before injection, without
	// accepting changed instance/artifact identity or relaxing the injection's
	// exact PID/port check below.
	if _, err := currentSessionRecoveryRuntime(root, bound); err != nil {
		return nil, err
	}
	result, err := call("get_vanessa_automation_state", map[string]any{})
	if err != nil {
		return nil, fmt.Errorf("bind original session runtime: %w", err)
	}
	if result == nil || result.IsError {
		return nil, fmt.Errorf("bind original session runtime returned no successful result")
	}
	current, err := currentSessionRecoveryRuntime(root, bound)
	if err != nil {
		return nil, err
	}
	return verifyMissingStateRecovery(ctx, root, current, call, exited)
}

func currentSessionRecoveryRuntime(root string, bound runtimeState) (runtimeState, error) {
	id, err := hex.DecodeString(bound.InstanceID)
	if err != nil || len(id) != 16 || len(bound.InstanceID) != 32 {
		return runtimeState{}, fmt.Errorf("invalid bound runtime instance ID")
	}
	states, err := readStates(root)
	if err != nil || len(states) != 1 {
		return runtimeState{}, fmt.Errorf("phase binding requires exactly the original session runtime record")
	}
	current := states[0]
	expected := bound
	expected.PID, expected.Port = current.PID, current.Port
	expected.TestClientPID, expected.TestClientPort = current.TestClientPID, current.TestClientPort
	if !reflect.DeepEqual(current, expected) || current.PID <= 0 || current.Port <= 0 ||
		current.TestClientPID <= 0 || current.TestClientPort <= 0 || current.PID == current.TestClientPID ||
		current.TestClientProfile != "itl-ondemand" {
		return runtimeState{}, fmt.Errorf("phase runtime does not match the original session/artifact identity")
	}
	return current, nil
}

// Only the existing session's bound record may be removed. Its full bytes stay
// private: native ownership/lease tokens must not be copied into probe evidence.
func verifyMissingStateRecovery(ctx context.Context, root string, bound runtimeState,
	call func(string, any) (*mcp.CallToolResult, error), exited func(context.Context, []int) error,
) (*missingStateRecoveryEvidence, error) {
	id, err := hex.DecodeString(bound.InstanceID)
	if err != nil || len(id) != 16 || len(bound.InstanceID) != 32 {
		return nil, fmt.Errorf("invalid bound runtime instance ID")
	}
	path := filepath.Join(root, bound.InstanceID+".json")
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read bound runtime record: %w", err)
	}
	var original runtimeState
	if err := json.Unmarshal(raw, &original); err != nil {
		return nil, fmt.Errorf("decode bound runtime record: %w", err)
	}
	if original.InstanceID != bound.InstanceID || original.PID != bound.PID || original.Port != bound.Port ||
		original.PID <= 0 || original.Port <= 0 || original.TestClientPID <= 0 ||
		original.TestClientPID == original.PID || original.TestClientPort <= 0 || original.TestClientProfile != "itl-ondemand" {
		return nil, fmt.Errorf("runtime record no longer matches this probe's bound manager and managed TestClient")
	}
	states, err := readStates(root)
	if err != nil || len(states) != 1 || states[0].InstanceID != original.InstanceID {
		return nil, fmt.Errorf("fault injection requires exactly this probe's one runtime record")
	}
	if err := os.Remove(path); err != nil {
		return nil, fmt.Errorf("remove bound runtime record: %w", err)
	}
	// No reconnect, broker call, process stop or state reconstruction is allowed
	// here: the original connect must traverse the normal facade/guard owner.
	calls := []struct {
		name string
		args any
	}{
		{"manage_test_client", map[string]any{"action": "connect", "profileName": "itl-ondemand"}},
		{"get_window_list_testclient", map[string]any{}},
	}
	for _, step := range calls {
		result, err := call(step.name, step.args)
		if err != nil {
			return nil, fmt.Errorf("original connection %s failed: %w", step.name, err)
		}
		if result == nil {
			return nil, fmt.Errorf("original connection %s returned no result", step.name)
		}
		if result.IsError {
			return nil, fmt.Errorf("original connection %s returned a tool error: %v", step.name, result.StructuredContent)
		}
	}
	states, err = waitForStateCount(root, 1, 30*time.Second)
	if err != nil {
		return nil, err
	}
	next := states[0]
	if next.InstanceID == original.InstanceID || next.InstanceID == "" || next.PID <= 0 || next.TestClientPID <= 0 ||
		next.TestClientProfile != "itl-ondemand" || next.Port <= 0 || next.TestClientPort <= 0 ||
		next.PID == next.TestClientPID || next.PID == original.PID || next.PID == original.TestClientPID ||
		next.TestClientPID == original.PID || next.TestClientPID == original.TestClientPID {
		return nil, fmt.Errorf("connect did not produce a distinct manager/managed TestClient instance")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		return nil, fmt.Errorf("original runtime record was recreated or its absence is unproven")
	}
	if err := exited(ctx, []int{original.PID, original.TestClientPID}); err != nil {
		return nil, fmt.Errorf("original process exit unproven: %w", err)
	}
	return &missingStateRecoveryEvidence{
		Passed: true, Original: original, OriginalRecordSHA256: fmt.Sprintf("%x", sha256.Sum256(raw)), Replacement: next,
		SameConnection: true, OriginalProcessesGone: true, Calls: []string{calls[0].name, calls[1].name},
	}, nil
}

func proveRecoveryProcessesExited(ctx context.Context, pids []int) error {
	// Read-only witness. PID reuse is conservatively a failure; the probe never
	// terminates a process or reimplements the owner's native recovery.
	if len(pids) != 2 {
		return fmt.Errorf("manager and TestClient PIDs are required")
	}
	args := []string{"-NoProfile", "-NonInteractive", "-Command",
		`& { param([int]$ManagerPID,[int]$ClientPID) $ErrorActionPreference='Stop'; foreach($id in @($ManagerPID,$ClientPID)) { try { $null=Get-Process -Id $id -ErrorAction Stop; throw "Original PID still present: $id" } catch { if($_.FullyQualifiedErrorId -notlike 'NoProcessFoundForGivenId,*') { throw } } } }`}
	for _, pid := range pids {
		if pid <= 0 {
			return fmt.Errorf("invalid original PID")
		}
		args = append(args, strconv.Itoa(pid))
	}
	checkCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	output, err := exec.CommandContext(checkCtx, "powershell.exe", args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("PID exit witness failed: %w: %s", err, output)
	}
	return nil
}
