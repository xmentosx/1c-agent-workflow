//go:build windows

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/jsonrpc"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// A separate facade process reproduces the real ownership boundary: a new
// chat cannot access the old runtime's in-memory retained signed context.
func TestConnectionControlChild(t *testing.T) {
	root := os.Getenv("ITL_CONNECTION_CONTROL_CHILD")
	if root == "" {
		return
	}
	family := os.Getenv("ITL_CONNECTION_CONTROL_FAMILY")
	rt, session, broker := newOwnerRecoveryFixture(t, family, func(name string) (*mcp.CallToolResult, error) {
		if name == recoveryMutationName(family) {
			file, err := os.OpenFile(filepath.Join(root, "mutation"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
			if err != nil {
				return nil, err
			}
			_, err = file.WriteString("one application\n")
			_ = file.Close()
			if err != nil {
				return nil, err
			}
			return nil, &jsonrpc.Error{Code: -32603, Message: "response lost after application"}
		}
		return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: "read"}}}, nil
	})
	rt.projectRoot, broker.planner.plan.ProjectRoot = root, root
	writeRuntimeMarker(t, rt, rt.instanceID)
	broker.stopFailures = 1
	result := recoveryGatewayCall(t, session, recoveryMutationName(family))
	if !result.IsError || rt.executionOwner == nil || !rt.cleanupUnconfirmed {
		t.Fatal("original unknown mutation did not retain its owner")
	}
	legacy := os.Getenv("ITL_CONNECTION_CONTROL_LEGACY") == "1"
	stop := func() {}
	if !legacy {
		var err error
		stop, err = rt.startConnectionControl(context.Background())
		if err != nil {
			t.Fatal(err)
		}
	}
	defer stop()
	if !legacy {
		rt.databaseGate <- struct{}{}
	}
	if err := writeProfileJSON(filepath.Join(root, "ready.json"), broker.planner.plan); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(35 * time.Second)
	busy := !legacy
	for time.Now().Before(deadline) {
		if _, err := os.Stat(filepath.Join(root, "release")); busy && err == nil {
			<-rt.databaseGate
			busy = false
			_ = os.WriteFile(filepath.Join(root, "idle"), nil, 0600)
		}
		rt.mu.Lock()
		pending := rt.cleanupUnconfirmed
		rt.mu.Unlock()
		if !pending {
			if err := os.WriteFile(filepath.Join(root, "cleaned"), []byte("original owner released"), 0600); err != nil {
				t.Fatal(err)
			}
		}
		if _, err := os.Stat(filepath.Join(root, "exit")); err == nil {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("parent did not finish the cross-process continuation")
}

func TestNewChatRecoversRetainedPeerAndContinuesOriginalRead(t *testing.T) {
	for _, family := range []string{"roctup", "vanessa-ui"} {
		t.Run(family, func(t *testing.T) {
			root := filepath.Join(t.TempDir(), "Проект с пробелом")
			if err := os.MkdirAll(root, 0700); err != nil {
				t.Fatal(err)
			}
			exe, _ := os.Executable()
			child := exec.Command(exe, "-test.run=^TestConnectionControlChild$", "-test.timeout=45s")
			child.Env = append(os.Environ(), "ITL_CONNECTION_CONTROL_CHILD="+root, "ITL_CONNECTION_CONTROL_FAMILY="+family)
			var output strings.Builder
			child.Stdout, child.Stderr = &output, &output
			if err := child.Start(); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() {
				_ = os.WriteFile(filepath.Join(root, "exit"), nil, 0600)
				_ = child.Process.Kill()
				_ = child.Wait()
			})
			var plan facadeExecutionPlan
			deadline := time.Now().Add(15 * time.Second)
			for {
				raw, err := os.ReadFile(filepath.Join(root, "ready.json"))
				if err == nil {
					if err := json.Unmarshal(raw, &plan); err != nil {
						t.Fatal(err)
					}
					break
				}
				if time.Now().After(deadline) {
					t.Fatalf("old facade did not retain its owner: %s", output.String())
				}
				time.Sleep(25 * time.Millisecond)
			}
			reads := 0
			owners, _ := filepath.Glob(filepath.Join(connectionControlRoot(root, family), "*", "owner.json"))
			if len(owners) != 1 {
				t.Fatal("old connection descriptor missing")
			}
			var state connectionControlState
			raw, _ := os.ReadFile(owners[0])
			if err := json.Unmarshal(raw, &state); err != nil {
				t.Fatal(err)
			}
			// A held call gate is not cleanup debt available to another chat.
			if cleaned, err := recoverPeerConnection(context.Background(), state, root, family, []string{"irrelevant"}); cleaned || err != nil {
				t.Fatalf("busy peer was interrupted: %v %v", cleaned, err)
			}
			_ = os.WriteFile(filepath.Join(root, "release"), nil, 0600)
			for {
				if _, err := os.Stat(filepath.Join(root, "idle")); err == nil {
					break
				}
				if time.Now().After(deadline) {
					t.Fatal("call gate did not finish")
				}
				time.Sleep(20 * time.Millisecond)
			}
			if cleaned, err := recoverPeerConnection(context.Background(), state, root, family, []string{"foreign-resource"}); cleaned || err != nil {
				t.Fatalf("foreign resource cleaned: %v %v", cleaned, err)
			}
			if _, err := os.Stat(filepath.Join(root, "cleaned")); err == nil {
				t.Fatal("unrelated request released the old guard")
			}
			rt, session, broker := newOwnerRecoveryFixture(t, family, func(string) (*mcp.CallToolResult, error) {
				reads++
				return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: "continued original task"}}}, nil
			})
			rt.projectRoot = root
			broker.planner.plan = &plan
			writeRuntimeMarker(t, rt, rt.instanceID)
			result := recoveryGatewayCall(t, session, recoveryReadName(family))
			if result.IsError || resultText(result) != "continued original task" || reads != 1 {
				t.Fatalf("new chat failed to continue: %v", result)
			}
			applied, err := os.ReadFile(filepath.Join(root, "mutation"))
			if err != nil || strings.Count(string(applied), "one application") != 1 {
				t.Fatal("original modification was lost or replayed")
			}
			deadline = time.Now().Add(2 * time.Second)
			for {
				if _, err := os.Stat(filepath.Join(root, "cleaned")); err == nil {
					break
				}
				if time.Now().After(deadline) {
					t.Fatal("old owner cleanup was not confirmed")
				}
				time.Sleep(20 * time.Millisecond)
			}
			// The original facade stays usable; no Desktop or facade restart is
			// required, and its mutation was not sent again during recovery.
			_ = os.WriteFile(filepath.Join(root, "exit"), nil, 0600)
			if err := child.Wait(); err != nil {
				t.Fatalf("original facade did not shut down cleanly: %v %s", err, output.String())
			}
		})
	}
}

type observedConnectionRepairBroker struct {
	*ownerRecoveryFixture
	repairs int
}

func (b *observedConnectionRepairBroker) RepairObsoleteConnections(context.Context, *facadeExecutionPlan, []string) error {
	b.repairs++
	return nil
}

func TestUncontendedCallsDoNotInvokeConnectionRepair(t *testing.T) {
	rt, session, broker := newOwnerRecoveryFixture(t, "roctup", func(string) (*mcp.CallToolResult, error) {
		return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: "original read"}}}, nil
	})
	observed := &observedConnectionRepairBroker{ownerRecoveryFixture: broker}
	rt.broker = observed
	for i := 0; i < 2; i++ {
		result := recoveryGatewayCall(t, session, recoveryReadName("roctup"))
		if result.IsError || resultText(result) != "original read" {
			t.Fatal(result)
		}
	}
	if observed.repairs != 0 {
		t.Fatalf("uncontended reads invoked %d external repairs", observed.repairs)
	}
}

func TestConnectionControlRejectsWrongProjectIdentityAndResourceSet(t *testing.T) {
	root := t.TempDir()
	identity, err := readProfileProcessIdentity(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	state := connectionControlState{1, root, "roctup", strings.Repeat("1", 32), strings.Repeat("2", 32), identity}
	for _, change := range []func(*connectionControlState){
		func(s *connectionControlState) { s.ProjectRoot = filepath.Join(root, "foreign") },
		func(s *connectionControlState) { s.Family = "vanessa-ui" },
		func(s *connectionControlState) { s.Generation = "../escape" },
	} {
		copy := state
		change(&copy)
		ok, err := recoverPeerConnection(context.Background(), copy, root, "roctup", []string{"base-a"})
		if ok || err != nil {
			t.Fatalf("invalid peer was accepted: %v %v", ok, err)
		}
	}
	for _, pair := range []struct {
		a, b []string
		want bool
	}{
		{[]string{"a", "b"}, []string{"b", "a"}, true},
		{[]string{"a", "b"}, []string{"a", "a"}, false},
		{[]string{"a"}, []string{"a", "b"}, false},
		{nil, nil, false},
	} {
		if sameResourceSet(pair.a, pair.b) != pair.want {
			t.Fatal(fmt.Sprint(pair))
		}
	}
}
