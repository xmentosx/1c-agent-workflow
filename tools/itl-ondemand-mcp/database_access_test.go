package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func databaseAccessFixture(t *testing.T) (string, string, databaseAccessRequest) {
	t.Helper()
	python, err := exec.LookPath("python")
	if err != nil {
		t.Fatal("Python 3.11+ is required for database admission qualification:", err)
	}
	runtimeRoot, err := filepath.Abs("../../.agents/skills/itl-remote-runner/scripts")
	if err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(t.TempDir(), "Общая очередь баз")
	return python, runtimeRoot, databaseAccessRequest{SchemaVersion: 1, Coordinator: filepath.Join(root, "координатор"),
		Bases: []databaseConnection{{Kind: "file", Path: filepath.Join(root, "целевая база")}},
		Owner: map[string]any{"project": root, "operation": "facade-test"}, Timeout: 0}
}

func acquireDatabaseFixture(t *testing.T, python, runtimeRoot string, request databaseAccessRequest) *databasePipeOwner {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	owner, err := acquireDatabasePipeOwner(ctx, python, runtimeRoot, request, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = owner.Close() })
	return owner
}

func releaseDatabaseFixture(t *testing.T, owner *databasePipeOwner, cleanupErrors []string) string {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	status, err := owner.Release(ctx, cleanupErrors)
	if err != nil {
		t.Fatal(err)
	}
	return status
}

func TestDatabaseAccessNativeExclusionAndRelease(t *testing.T) {
	python, runtimeRoot, request := databaseAccessFixture(t)
	first := acquireDatabaseFixture(t, python, runtimeRoot, request)
	if strings.Contains(string(first.Public), first.Proof.Token) {
		t.Fatal("private token escaped in public owner")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	second, err := acquireDatabasePipeOwner(ctx, python, runtimeRoot, request, func(event databaseAccessEvent) {
		encoded, _ := json.Marshal(event)
		if strings.Contains(string(encoded), first.Proof.Token) {
			t.Fatal("private token escaped in waiting progress")
		}
	})
	if second != nil || err == nil || !strings.Contains(err.Error(), "WAIT_TIMEOUT") {
		t.Fatalf("second operation was not excluded: owner=%t error=%v", second != nil, err)
	}
	if got := releaseDatabaseFixture(t, first, nil); got != "released" {
		t.Fatal(got)
	}
	last := acquireDatabaseFixture(t, python, runtimeRoot, request)
	releaseDatabaseFixture(t, last, nil)
}

func TestDatabaseAccessReadOnlyFacadeCoexistsWithOneTestRun(t *testing.T) {
	python, runtimeRoot, request := databaseAccessFixture(t)
	request.AccessMode = "shared-read"
	reader := acquireDatabaseFixture(t, python, runtimeRoot, request)
	testRequest := request
	testRequest.AccessMode = "test-run"
	tests := acquireDatabaseFixture(t, python, runtimeRoot, testRequest)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	other, err := acquireDatabasePipeOwner(ctx, python, runtimeRoot, testRequest, nil)
	if other != nil || err == nil || !strings.Contains(err.Error(), "WAIT_TIMEOUT") {
		t.Fatalf("a second test run entered the same database: owner=%t error=%v", other != nil, err)
	}
	releaseDatabaseFixture(t, tests, nil)
	releaseDatabaseFixture(t, reader, nil)
}

func TestDatabaseAccessOwnerTransitionsTheSameTicket(t *testing.T) {
	python, runtimeRoot, request := databaseAccessFixture(t)
	request.AccessMode = "test-run"
	owner := acquireDatabaseFixture(t, python, runtimeRoot, request)
	ticket := owner.Proof.Ticket
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := owner.Transition(ctx, "exclusive", 1, nil); err != nil {
		t.Fatal(err)
	}
	if owner.AccessMode != "exclusive" || owner.Proof.Ticket != ticket {
		t.Fatal("mode transition replaced the admitted ticket")
	}
	readerRequest := request
	readerRequest.AccessMode = "shared-read"
	readerRequest.Timeout = 0
	reader, err := acquireDatabasePipeOwner(ctx, python, runtimeRoot, readerRequest, nil)
	if reader != nil || err == nil || !strings.Contains(err.Error(), "WAIT_TIMEOUT") {
		t.Fatalf("reader entered an exclusive preparation phase: owner=%t error=%v", reader != nil, err)
	}
	if err := owner.Transition(ctx, "test-run", 1, nil); err != nil {
		t.Fatal(err)
	}
	reader = acquireDatabaseFixture(t, python, runtimeRoot, readerRequest)
	releaseDatabaseFixture(t, reader, nil)
	releaseDatabaseFixture(t, owner, nil)
}

func TestDatabaseHostIgnoresForeignPythonHomeAndKeepsPayloadImmutable(t *testing.T) {
	python, _, _ := databaseAccessFixture(t)
	root := filepath.Join(t.TempDir(), "Python библиотека с пробелом")
	if err := os.MkdirAll(root, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "owned_fixture.py"), []byte("value = 42\n"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PYTHONHOME", filepath.Join(root, "missing foreign installation"))
	t.Setenv("PYTHONDONTWRITEBYTECODE", "0")
	t.Setenv("PYTHONNOUSERSITE", "0")
	command := exec.Command(python, "-X", "utf8", "-c", "import owned_fixture,sys; assert owned_fixture.value == 42; assert sys.flags.no_user_site == 1")
	command.Env = databaseHostEnvironment(root)
	hideDatabaseHost(command)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("managed environment failed: %v: %s", err, output)
	}
	if _, err := os.Stat(filepath.Join(root, "__pycache__")); !os.IsNotExist(err) {
		t.Fatalf("runtime library was modified: %v", err)
	}
}

func TestDatabaseAccessInheritanceDoesNotReleaseParent(t *testing.T) {
	python, runtimeRoot, request := databaseAccessFixture(t)
	parent := acquireDatabaseFixture(t, python, runtimeRoot, request)
	childRequest := request
	childRequest.Inherited = parent.Proof
	child := acquireDatabaseFixture(t, python, runtimeRoot, childRequest)
	if child.Proof.Ticket != parent.Proof.Ticket {
		t.Fatal("nested operation acquired a different reservation")
	}
	releaseDatabaseFixture(t, child, nil)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	other, err := acquireDatabasePipeOwner(ctx, python, runtimeRoot, request, nil)
	if other != nil || err == nil || !strings.Contains(err.Error(), "WAIT_TIMEOUT") {
		t.Fatal("child release freed the parent's database")
	}
	releaseDatabaseFixture(t, parent, nil)
}

func TestDatabaseAccessCancelledWaitLeavesNoAdmittedWork(t *testing.T) {
	python, runtimeRoot, request := databaseAccessFixture(t)
	parent := acquireDatabaseFixture(t, python, runtimeRoot, request)
	request.Timeout = 10
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	owner, err := acquireDatabasePipeOwner(ctx, python, runtimeRoot, request, func(databaseAccessEvent) { cancel() })
	if owner != nil || !errors.Is(err, context.Canceled) {
		t.Fatalf("wait was not cancelled: %v", err)
	}
	releaseDatabaseFixture(t, parent, nil)
	request.Timeout = 0
	after := acquireDatabaseFixture(t, python, runtimeRoot, request)
	releaseDatabaseFixture(t, after, nil)
}

func TestDatabaseAccessInheritedUncertaintyPreventsParentRelease(t *testing.T) {
	for _, disconnect := range []bool{false, true} {
		t.Run(map[bool]string{false: "cleanup-failed", true: "disconnect"}[disconnect], func(t *testing.T) {
			python, runtimeRoot, request := databaseAccessFixture(t)
			parent := acquireDatabaseFixture(t, python, runtimeRoot, request)
			childRequest := request
			childRequest.Inherited = parent.Proof
			child := acquireDatabaseFixture(t, python, runtimeRoot, childRequest)
			if disconnect {
				if err := child.Close(); err != nil {
					t.Fatal(err)
				}
			} else if got := releaseDatabaseFixture(t, child, []string{"native cleanup unproven"}); got != "needs-attention" {
				t.Fatalf("child reported clean completion: %s", got)
			}
			if got := releaseDatabaseFixture(t, parent, nil); got != "needs-attention" {
				t.Fatalf("parent hid inherited uncertainty: %s", got)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			other, err := acquireDatabasePipeOwner(ctx, python, runtimeRoot, request, nil)
			if other != nil || err == nil || !strings.Contains(err.Error(), "RECOVERY_REQUIRED") {
				t.Fatalf("another task acquired an uncertain database: %v", err)
			}
		})
	}
}

func TestDatabaseAccessDisconnectAndFailedCleanupRequireRecovery(t *testing.T) {
	for _, failedCleanup := range []bool{false, true} {
		t.Run(map[bool]string{false: "disconnect", true: "cleanup-failed"}[failedCleanup], func(t *testing.T) {
			python, runtimeRoot, request := databaseAccessFixture(t)
			owner := acquireDatabaseFixture(t, python, runtimeRoot, request)
			if failedCleanup {
				if got := releaseDatabaseFixture(t, owner, []string{"Серверная работа не завершена"}); got != "needs-attention" {
					t.Fatal(got)
				}
			} else if err := owner.Close(); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			other, err := acquireDatabasePipeOwner(ctx, python, runtimeRoot, request, nil)
			if other != nil || err == nil || !strings.Contains(err.Error(), "RECOVERY_REQUIRED") {
				t.Fatalf("unproven cleanup freed the database: %v", err)
			}
		})
	}
}

func TestDatabaseAccessCancelledBeforeLaunchCreatesNoTicket(t *testing.T) {
	python, runtimeRoot, request := databaseAccessFixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	owner, err := acquireDatabasePipeOwner(ctx, python, runtimeRoot, request, nil)
	if owner != nil || !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if _, err := os.Stat(request.Coordinator); !os.IsNotExist(err) {
		t.Fatal("cancelled request created coordinator state")
	}
}

func TestDatabaseAccessRejectedTokenNeverAppearsInNativeError(t *testing.T) {
	python, runtimeRoot, request := databaseAccessFixture(t)
	parent := acquireDatabaseFixture(t, python, runtimeRoot, request)
	wrong := *parent.Proof
	wrong.Token = "private-token-must-not-be-printed"
	request.Inherited = &wrong
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	owner, err := acquireDatabasePipeOwner(ctx, python, runtimeRoot, request, nil)
	if owner != nil || err == nil || !strings.Contains(err.Error(), "INHERITANCE_INVALID") || strings.Contains(err.Error(), wrong.Token) {
		t.Fatal("invalid inheritance did not produce a private, bounded rejection")
	}
	releaseDatabaseFixture(t, parent, nil)
}

func TestDatabaseAccessRevalidatesInheritedParentBeforeAnotherCall(t *testing.T) {
	python, runtimeRoot, request := databaseAccessFixture(t)
	parent := acquireDatabaseFixture(t, python, runtimeRoot, request)
	request.Inherited = parent.Proof
	child := acquireDatabaseFixture(t, python, runtimeRoot, request)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := child.Validate(ctx); err != nil {
		t.Fatal(err)
	}
	releaseDatabaseFixture(t, parent, nil)
	if err := child.Validate(ctx); err == nil || !strings.Contains(err.Error(), "INHERITANCE_INVALID") {
		t.Fatal("an ended outer operation was allowed to authorize a new nested call")
	}
}

func TestDatabaseAccessValidationWaitsForAllocatorWithoutAbandoningOwner(t *testing.T) {
	python, runtimeRoot, request := databaseAccessFixture(t)
	owner := acquireDatabaseFixture(t, python, runtimeRoot, request)
	code := "import sys\nfrom pathlib import Path\nfrom itl_remote.common import FileLock\nwith FileLock(Path(sys.argv[1]) / 'allocator.lock'):\n print('locked',flush=True)\n sys.stdin.readline()\n"
	blocker := exec.Command(python, "-X", "utf8", "-u", "-c", code, request.Coordinator)
	blocker.Env = databaseHostEnvironment(runtimeRoot)
	input, err := blocker.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	output, err := blocker.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := blocker.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = input.Close(); _ = blocker.Wait() }()
	if line, err := bufio.NewReader(output).ReadString('\n'); err != nil || strings.TrimSpace(line) != "locked" {
		t.Fatalf("allocator fixture did not acquire its lock: %q %v", line, err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	finished := make(chan error, 1)
	go func() { finished <- owner.Validate(ctx) }()
	select {
	case err := <-finished:
		t.Fatalf("temporary allocator contention abandoned a live owner: %v", err)
	case <-time.After(100 * time.Millisecond):
	}
	_ = input.Close()
	if err := <-finished; err != nil {
		t.Fatal(err)
	}
	releaseDatabaseFixture(t, owner, nil)
}
