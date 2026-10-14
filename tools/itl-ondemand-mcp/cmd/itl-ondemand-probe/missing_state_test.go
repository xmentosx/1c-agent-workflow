package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func writeRecoveryRecord(t *testing.T, root string, state runtimeState) string {
	t.Helper()
	raw, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, state.InstanceID+".json")
	if err := os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
	return path
}

func recoveryRecords() (runtimeState, runtimeState) {
	return runtimeState{InstanceID: strings.Repeat("a", 32), PID: 101, Port: 40101, TestClientPID: 102,
			TestClientPort: 40102, TestClientProfile: "itl-ondemand"},
		runtimeState{InstanceID: strings.Repeat("b", 32), PID: 103, Port: 40101, TestClientPID: 104,
			TestClientPort: 40102, TestClientProfile: "itl-ondemand"}
}

func TestRecoveryProbeInjectsOnlyBoundRecordAndUsesOriginalCallOnce(t *testing.T) {
	root := filepath.Join(t.TempDir(), "стенд с пробелом")
	if err := os.Mkdir(root, 0700); err != nil {
		t.Fatal(err)
	}
	old, next := recoveryRecords()
	path := writeRecoveryRecord(t, root, old)
	raw, _ := os.ReadFile(path)
	raw = append(raw[:len(raw)-1], []byte(`,"portLeaseToken":"private-native-token"}`)...)
	if err := os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
	var calls []string
	proof, err := verifyMissingStateRecovery(context.Background(), root, old,
		func(name string, args any) (*mcp.CallToolResult, error) {
			if _, err := os.Stat(path); !os.IsNotExist(err) {
				t.Fatal("original record was not removed")
			}
			calls = append(calls, name)
			if name == "manage_test_client" {
				if !reflect.DeepEqual(args, map[string]any{"action": "connect", "profileName": "itl-ondemand"}) {
					t.Fatalf("changed original connect: %v", args)
				}
				writeRecoveryRecord(t, root, next)
			}
			return &mcp.CallToolResult{}, nil
		}, func(_ context.Context, ids []int) error {
			if !reflect.DeepEqual(ids, []int{old.PID, old.TestClientPID}) {
				t.Fatal(ids)
			}
			return nil
		})
	if err != nil {
		t.Fatal(err)
	}
	if !proof.Passed || !proof.SameConnection || !proof.OriginalProcessesGone || len(proof.OriginalRecordSHA256) != 64 ||
		!reflect.DeepEqual(calls, []string{"manage_test_client", "get_window_list_testclient"}) {
		t.Fatalf("invalid proof: %+v calls=%v", proof, calls)
	}
	encoded, _ := json.Marshal(proof)
	if strings.Contains(string(encoded), "private-native-token") || strings.Contains(string(encoded), "portLeaseToken") {
		t.Fatal("native lease token leaked")
	}
}

func TestRecoveryProbeRejectsUnsafeInjectionBeforeAnyCall(t *testing.T) {
	for _, condition := range []string{"path-traversal", "different-pid", "different-instance", "no-testclient", "additional-instance", "malformed"} {
		t.Run(condition, func(t *testing.T) {
			root := t.TempDir()
			old, next := recoveryRecords()
			bound := old
			path := writeRecoveryRecord(t, root, old)
			switch condition {
			case "path-traversal":
				bound.InstanceID = "../" + old.InstanceID
			case "different-pid":
				bound.PID++
			case "different-instance":
				old.InstanceID = next.InstanceID
				raw, _ := json.Marshal(old)
				if err := os.WriteFile(path, raw, 0600); err != nil {
					t.Fatal(err)
				}
			case "no-testclient":
				old.TestClientPID = 0
				writeRecoveryRecord(t, root, old)
			case "additional-instance":
				writeRecoveryRecord(t, root, next)
			case "malformed":
				if err := os.WriteFile(path, []byte("{"), 0600); err != nil {
					t.Fatal(err)
				}
			}
			before, _ := os.ReadFile(path)
			_, err := verifyMissingStateRecovery(context.Background(), root, bound, func(string, any) (*mcp.CallToolResult, error) {
				t.Fatal("unsafe injection called backend")
				return nil, nil
			}, func(context.Context, []int) error { t.Fatal("unexpected witness"); return nil })
			if err == nil {
				t.Fatal("unsafe injection accepted")
			}
			after, readErr := os.ReadFile(path)
			if readErr != nil || string(before) != string(after) {
				t.Fatal("refused record was changed")
			}
		})
	}
}

func TestRecoveryProbeNeverRetriesUnknownConnectOrAcceptsUnprovenReplacement(t *testing.T) {
	for _, condition := range []string{"unknown-connect", "nil-result", "tool-error", "same-instance", "reused-pid", "old-record-recreated", "original-still-alive"} {
		t.Run(condition, func(t *testing.T) {
			root := t.TempDir()
			old, next := recoveryRecords()
			path := writeRecoveryRecord(t, root, old)
			calls := 0
			_, err := verifyMissingStateRecovery(context.Background(), root, old, func(name string, _ any) (*mcp.CallToolResult, error) {
				calls++
				if name == "manage_test_client" {
					switch condition {
					case "unknown-connect":
						return nil, errors.New("unknown native outcome")
					case "nil-result":
						return nil, nil
					case "tool-error":
						return &mcp.CallToolResult{IsError: true}, nil
					case "same-instance":
						next.InstanceID = old.InstanceID
					case "reused-pid":
						next.TestClientPID = old.PID
					}
					if condition == "old-record-recreated" {
						raw, _ := json.Marshal(next)
						if err := os.WriteFile(path, raw, 0600); err != nil {
							t.Fatal(err)
						}
					} else {
						writeRecoveryRecord(t, root, next)
					}
				}
				return &mcp.CallToolResult{}, nil
			}, func(context.Context, []int) error {
				if condition == "original-still-alive" {
					return errors.New("original PID still alive")
				}
				return nil
			})
			if err == nil {
				t.Fatal("unproven recovery accepted")
			}
			if (condition == "unknown-connect" || condition == "nil-result" || condition == "tool-error") && calls != 1 {
				t.Fatalf("connect was repeated: %d", calls)
			}
		})
	}
}

func TestRecoveryExitWitnessObservesRealWindowsProcessWithoutStoppingIt(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("Windows native witness")
	}
	if err := proveRecoveryProcessesExited(context.Background(), []int{os.Getpid(), os.Getpid()}); err == nil {
		t.Fatal("live process was accepted as absent")
	}
	if _, err := os.FindProcess(os.Getpid()); err != nil {
		t.Fatal("witness changed current process")
	}
	pids := []int{}
	for i := 0; i < 2; i++ {
		cmd := exec.Command("cmd.exe", "/c", "exit", "0")
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		pids = append(pids, cmd.Process.Pid)
		if err := cmd.Wait(); err != nil {
			t.Fatal(err)
		}
	}
	if err := proveRecoveryProcessesExited(context.Background(), pids); err != nil {
		t.Fatal(err)
	}
}
