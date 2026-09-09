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
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/sys/windows"
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

type profileOwnerFixture struct {
	config  profileOwnerConfig
	state   *profileOwnerState
	feature string
	rt      *runtime
	broker  *databaseFixtureBroker
	done    chan error
	cancel  context.CancelFunc
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

func startProfileOwnerFixture(t *testing.T, request databaseAccessRequest, python, runtimeRoot string, open func(context.Context, *runtime, string) (*vanessaProfileResult, error)) *profileOwnerFixture {
	t.Helper()
	rt, broker := newDatabaseRuntimeFixture(t, request, python, runtimeRoot, nil)
	rt.idle = 0
	config := profileOwnerConfig{ProjectRoot: rt.projectRoot, InstanceID: rt.instanceID, Generation: strings.Repeat("b", 32), CallerID: "test-caller"}
	feature := filepath.Join(config.ProjectRoot, "Сценарий с пробелом.feature")
	if err := os.MkdirAll(config.ProjectRoot, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(feature, []byte("# fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	f := &profileOwnerFixture{config: config, feature: feature, rt: rt, broker: broker, done: make(chan error, 1), cancel: cancel}
	go func() {
		f.done <- serveProfileOwner(ctx, config, profileOwnerCallbacks{Open: func(ctx context.Context, feature string) (*vanessaProfileResult, error) {
			if open != nil {
				return open(ctx, rt, feature)
			}
			result, err := databaseRuntimeCall(ctx, rt, nil)
			if err != nil {
				return nil, err
			}
			if result.IsError {
				return nil, fmt.Errorf("%s", resultText(result))
			}
			return &vanessaProfileResult{SchemaVersion: 1, Status: "running", InstanceID: rt.instanceID, ManagerPID: 4242, TestClientPID: 4343, FeaturePath: feature}, nil
		}, Stop: rt.stopOwnedRuntime})
	}()
	f.state = waitProfileState(t, rt.projectRoot, func(state *profileOwnerState) bool { return state.Status == "ready" })
	t.Cleanup(func() {
		ctx, cancelStop := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancelStop()
		state, err := readProfileOwnerState(rt.projectRoot)
		if err == nil && state.Status != "stopped" {
			_, _ = requestProfileOwner(ctx, state, "stop", "", "test-caller")
		}
		cancel()
	})
	return f
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
	explicit, err := resolveProfileCaller("manual-session", false)
	if err != nil || explicit != "manual-session" {
		t.Fatal(explicit, err)
	}
	t.Setenv("CODEX_THREAD_ID", "")
	first, err = resolveProfileCaller("", true)
	if err != nil {
		t.Fatal(err)
	}
	second, err = resolveProfileCaller("", true)
	if err != nil || first == second {
		t.Fatal("unidentified callers shared an implicit owner", err)
	}
	if _, err := resolveProfileCaller("", false); err == nil {
		t.Fatal("stop adopted an unidentified owner")
	}
}

func TestProfileOwnerDifferentCallerCannotReuseOrStopThePair(t *testing.T) {
	python, runtimeRoot, request := databaseAccessFixture(t)
	f := startProfileOwnerFixture(t, request, python, runtimeRoot, nil)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	opened, err := submitProfileOwnerRequest(f.state, "open", f.feature, "test-caller")
	if err != nil {
		t.Fatal(err)
	}
	if response, err := awaitProfileOwnerResponse(ctx, f.state, opened); err != nil || response.Status != "running" {
		t.Fatal(response, err)
	}
	for _, operation := range []string{"open", "stop"} {
		if _, err := requestProfileOwner(ctx, f.state, operation, f.feature, "another-chat"); err == nil || !strings.Contains(err.Error(), "CALLER_MISMATCH") {
			t.Fatal("foreign caller reached owner", operation, err)
		}
	}
	// Bypass the client-side check: the actor must independently reject the
	// foreign caller even with the exact public generation and active request ID.
	client, err := readProfileProcessIdentity(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	foreign := profileOwnerRequest{SchemaVersion: 1, ProjectRoot: f.config.ProjectRoot, InstanceID: f.config.InstanceID, Generation: f.config.Generation, CallerID: "another-chat", RequestID: strings.Repeat("e", 32), Operation: "cancel", CancelRequestID: opened.RequestID, ClientProcess: client}
	if err := writeProfileJSON(profileControlPath(profileOwnerRoot(f.config.ProjectRoot), f.config.Generation, "requests", foreign.RequestID), foreign); err != nil {
		t.Fatal(err)
	}
	if response, err := awaitProfileOwnerResponse(ctx, f.state, foreign); err != nil || response.Status != "rejected" {
		t.Fatal(response, err)
	}
	other := f.config
	other.CallerID = "another-chat"
	waitCtx, cancelWait := context.WithTimeout(ctx, 150*time.Millisecond)
	defer cancelWait()
	launches := 0
	if _, err := ensureProfileOwner(waitCtx, other, func(profileOwnerConfig) (profileProcessIdentity, error) {
		launches++
		return profileProcessIdentity{}, fmt.Errorf("unexpected launch")
	}); err == nil || !strings.Contains(err.Error(), "WAIT_CANCELLED") {
		t.Fatal("second chat did not wait", err)
	}
	if launches != 0 {
		t.Fatal("waiting caller launched a replacement")
	}
	if response, err := requestProfileOwner(ctx, f.state, "open", f.feature, "test-caller"); err != nil || response.Status != "running" {
		t.Fatal("owner lost its pair after foreign cancellation", response, err)
	}
	if ensures, _ := f.broker.counts(); ensures != 1 {
		t.Fatal("foreign caller reset native pair")
	}
	if owner, err := acquireDatabasePipeOwner(ctx, python, runtimeRoot, request, nil); err == nil {
		if owner != nil {
			_ = owner.Close()
		}
		t.Fatal("foreign wait released owner reservation")
	}
}

func TestProfileOwnerRetainsReservationAndDoesNotReplayARequest(t *testing.T) {
	python, runtimeRoot, request := databaseAccessFixture(t)
	var opens atomic.Int32
	f := startProfileOwnerFixture(t, request, python, runtimeRoot, func(ctx context.Context, rt *runtime, feature string) (*vanessaProfileResult, error) {
		opens.Add(1)
		result, err := databaseRuntimeCall(ctx, rt, nil)
		if err != nil {
			return nil, err
		}
		if result.IsError {
			return nil, fmt.Errorf("%s", resultText(result))
		}
		return &vanessaProfileResult{SchemaVersion: 1, Status: "running", InstanceID: rt.instanceID, FeaturePath: feature}, nil
	})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	open, err := submitProfileOwnerRequest(f.state, "open", f.feature, "test-caller")
	if err != nil {
		t.Fatal(err)
	}
	response, err := awaitProfileOwnerResponse(ctx, f.state, open)
	if err != nil || response.Status != "running" {
		t.Fatal(response, err)
	}
	if err := writeProfileJSON(profileControlPath(profileOwnerRoot(f.config.ProjectRoot), f.state.Generation, "requests", open.RequestID), open); err != nil {
		t.Fatal(err)
	}
	// A second distinct request establishes that the actor has advanced past
	// the duplicate file, without depending on a sleep as proof of no replay.
	response, err = requestProfileOwner(ctx, f.state, "open", f.feature, "test-caller")
	if err != nil || response.Status != "running" {
		t.Fatal(response, err)
	}
	if ensures, _ := f.broker.counts(); ensures != 1 {
		t.Fatal("profile did not retain its native pair")
	}
	if opens.Load() != 2 {
		t.Fatal("duplicate request replayed opening a feature")
	}
	other, err := acquireDatabasePipeOwner(ctx, python, runtimeRoot, request, nil)
	if other != nil {
		_ = other.Close()
	}
	if err == nil || !strings.Contains(err.Error(), "WAIT_TIMEOUT") {
		t.Fatal("manual profile released the database while still open", err)
	}
	response, err = requestProfileOwner(ctx, f.state, "stop", "", "test-caller")
	if err != nil || response.Status != "stopped" || !response.CleanupConfirmed {
		t.Fatal(response, err)
	}
	if err := <-f.done; err != nil {
		t.Fatal(err)
	}
	owner := acquireDatabaseFixture(t, python, runtimeRoot, request)
	releaseDatabaseFixture(t, owner, nil)
}

func TestProfileOwnerCancellationCannotStopAnotherRequest(t *testing.T) {
	python, runtimeRoot, request := databaseAccessFixture(t)
	entered, release := make(chan struct{}), make(chan struct{})
	var executions atomic.Int32
	f := startProfileOwnerFixture(t, request, python, runtimeRoot, func(ctx context.Context, rt *runtime, feature string) (*vanessaProfileResult, error) {
		executions.Add(1)
		close(entered)
		select {
		case <-release:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
		return &vanessaProfileResult{SchemaVersion: 1, Status: "running", InstanceID: rt.instanceID, FeaturePath: feature}, nil
	})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	open, err := submitProfileOwnerRequest(f.state, "open", f.feature, "test-caller")
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-entered:
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	id, _ := randomID()
	client, _ := readProfileProcessIdentity(os.Getpid())
	wrong := profileOwnerRequest{SchemaVersion: 1, ProjectRoot: f.config.ProjectRoot, InstanceID: f.config.InstanceID, Generation: f.config.Generation, CallerID: "test-caller", RequestID: id, Operation: "cancel", CancelRequestID: strings.Repeat("f", 32), ClientProcess: client}
	if err := writeProfileJSON(profileControlPath(profileOwnerRoot(f.config.ProjectRoot), f.config.Generation, "requests", id), wrong); err != nil {
		t.Fatal(err)
	}
	response, err := awaitProfileOwnerResponse(ctx, f.state, wrong)
	if err != nil || response.Status != "cancelled-no-active-operation" {
		t.Fatal(response, err)
	}
	if _, stops := f.broker.counts(); stops != 0 {
		t.Fatal("another request's cancellation stopped the profile")
	}
	close(release)
	response, err = awaitProfileOwnerResponse(ctx, f.state, open)
	if err != nil || response.Status != "running" || executions.Load() != 1 {
		t.Fatal(response, err)
	}
	_, err = requestProfileOwner(ctx, f.state, "stop", "", "test-caller")
	if err != nil {
		t.Fatal(err)
	}
	if err := <-f.done; err != nil {
		t.Fatal(err)
	}
}

func TestProfileOwnerFailedCleanupRemainsOwnedAndCanRetryStop(t *testing.T) {
	python, runtimeRoot, request := databaseAccessFixture(t)
	f := startProfileOwnerFixture(t, request, python, runtimeRoot, nil)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	response, err := requestProfileOwner(ctx, f.state, "open", f.feature, "test-caller")
	if err != nil || response.Status != "running" {
		t.Fatal(response, err)
	}
	f.broker.mu.Lock()
	f.broker.stopFailures = 3
	f.broker.mu.Unlock()
	response, err = requestProfileOwner(ctx, f.state, "stop", "", "test-caller")
	if err != nil || response.Status != "needs-attention" || response.CleanupConfirmed {
		t.Fatal(response, err)
	}
	other, err := acquireDatabasePipeOwner(ctx, python, runtimeRoot, request, nil)
	if other != nil {
		_ = other.Close()
	}
	if err == nil || !strings.Contains(err.Error(), "WAIT_TIMEOUT") {
		t.Fatal("failed cleanup released ownership", err)
	}
	response, err = requestProfileOwner(ctx, f.state, "stop", "", "test-caller")
	if err != nil || response.Status != "stopped" || !response.CleanupConfirmed {
		t.Fatal(response, err)
	}
	if err := <-f.done; err != nil {
		t.Fatal(err)
	}
}

type profileProcessFixtureConfig struct {
	Owner       profileOwnerConfig    `json:"owner"`
	Request     databaseAccessRequest `json:"request"`
	Python      string                `json:"python"`
	RuntimeRoot string                `json:"runtimeRoot"`
	Feature     string                `json:"feature"`
}

func TestProfileOwnerProcessChild(t *testing.T) {
	path := os.Getenv("ITL_PROFILE_OWNER_FIXTURE_CONFIG")
	if path == "" {
		t.Skip("subprocess fixture entrypoint")
	}
	var config profileProcessFixtureConfig
	if err := readProfileJSON(path, &config); err != nil {
		t.Fatal(err)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if os.Args[len(os.Args)-1] == "client-check" {
		state, err := readProfileOwnerState(config.Owner.ProjectRoot)
		if err != nil {
			t.Fatal(err)
		}
		alive, err := profileOwnerIsAlive(state)
		if err != nil || !alive {
			t.Fatal("owner did not survive the completed launcher command", err)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		other, err := acquireDatabasePipeOwner(ctx, config.Python, config.RuntimeRoot, config.Request, nil)
		if other != nil {
			_ = other.Close()
		}
		if err == nil || !strings.Contains(err.Error(), "WAIT_TIMEOUT") {
			t.Fatal("open profile did not retain the real coordinator reservation", err)
		}
		response, err := requestProfileOwner(ctx, state, "stop", "", config.Owner.CallerID)
		if err != nil || response.Status != "stopped" || !response.CleanupConfirmed {
			t.Fatal(response, err)
		}
		for {
			alive, err := profileOwnerIsAlive(state)
			if err != nil {
				t.Fatal(err)
			}
			if !alive {
				break
			}
			select {
			case <-ctx.Done():
				t.Fatal("owner did not exit after normal stop")
			case <-time.After(20 * time.Millisecond):
			}
		}
		last := acquireDatabaseFixture(t, config.Python, config.RuntimeRoot, config.Request)
		releaseDatabaseFixture(t, last, nil)
		if err := writeProfileJSON(filepath.Join(config.Owner.ProjectRoot, "qualification.json"), map[string]any{
			"schemaVersion": 1, "scope": "native-process-fixture", "native1C": false, "ownerAliveAfterLauncherCommand": true,
			"excludedWhileOpen": true, "normalStopConfirmed": true, "ownerExited": true, "databaseAvailableAfterStop": true,
			"ownerPID": state.Process.PID, "ownerGeneration": state.Generation,
		}); err != nil {
			t.Fatal(err)
		}
		return
	}
	if os.Args[len(os.Args)-1] == "launcher" {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		state, err := ensureProfileOwner(ctx, config.Owner, func(owner profileOwnerConfig) (profileProcessIdentity, error) {
			return launchProfileOwner(executable, []string{"-test.run=^TestProfileOwnerProcessChild$", "owner"}, owner.ProjectRoot)
		})
		if err != nil {
			t.Fatal(err)
		}
		response, err := requestProfileOwner(ctx, state, "open", config.Feature, config.Owner.CallerID)
		if err != nil || response.Status != "running" {
			t.Fatal(response, err)
		}
		if err := writeProfileJSON(filepath.Join(config.Owner.ProjectRoot, "launcher-result.json"), state); err != nil {
			t.Fatal(err)
		}
		return
	}
	childTemp := filepath.Join(config.Owner.ProjectRoot, "child-temporary")
	if err := os.MkdirAll(childTemp, 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TMP", childTemp)
	t.Setenv("TEMP", childTemp)
	rt, broker := newDatabaseRuntimeFixture(t, config.Request, config.Python, config.RuntimeRoot, nil)
	rt.projectRoot = config.Owner.ProjectRoot
	rt.idle = 0
	broker.plan.ProjectRoot = rt.projectRoot
	broker.statePath = filepath.Join(rt.projectRoot, ".agent-1c", "mcp", "ondemand", rt.family, rt.instanceID+".json")
	err = serveProfileOwner(context.Background(), config.Owner, profileOwnerCallbacks{
		Open: func(ctx context.Context, feature string) (*vanessaProfileResult, error) {
			result, err := databaseRuntimeCall(ctx, rt, nil)
			if err != nil {
				return nil, err
			}
			if result.IsError {
				return nil, fmt.Errorf("%s", resultText(result))
			}
			return &vanessaProfileResult{SchemaVersion: 1, Status: "running", InstanceID: rt.instanceID, ManagerPID: 4242, TestClientPID: 4343, FeaturePath: feature}, nil
		}, Stop: rt.stopOwnedRuntime,
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestProfileOwnerSimultaneousChatLaunchesWaitForNormalStop(t *testing.T) {
	python, runtimeRoot, request := databaseAccessFixture(t)
	root := filepath.Join(t.TempDir(), "Одновременные чаты одной ветки")
	if err := os.MkdirAll(root, 0700); err != nil {
		t.Fatal(err)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	t.Cleanup(func() {
		cancel()
		if state, err := readProfileOwnerState(root); err == nil && (state.CallerID == "chat-0" || state.CallerID == "chat-1") {
			cleanup, done := context.WithTimeout(context.Background(), 5*time.Second)
			defer done()
			_, _ = requestProfileOwner(cleanup, state, "stop", "", state.CallerID)
		}
	})
	type launchResult struct {
		index  int
		err    error
		output []byte
	}
	results := make(chan launchResult, 2)
	features := []string{filepath.Join(root, "Первый сценарий.feature"), filepath.Join(root, "Второй сценарий.feature")}
	for i := 0; i < 2; i++ {
		if err := os.WriteFile(features[i], []byte("# fixture"), 0600); err != nil {
			t.Fatal(err)
		}
		config := profileProcessFixtureConfig{Owner: profileOwnerConfig{ProjectRoot: root, InstanceID: strings.Repeat("a", 32), Generation: strings.Repeat(string(rune('b'+i)), 32), CallerID: fmt.Sprintf("chat-%d", i)}, Request: request, Python: python, RuntimeRoot: runtimeRoot, Feature: features[i]}
		path := filepath.Join(root, fmt.Sprintf("fixture-%d.json", i))
		if err := writeProfileJSON(path, config); err != nil {
			t.Fatal(err)
		}
		command := exec.CommandContext(ctx, executable, "-test.run=^TestProfileOwnerProcessChild$", "launcher")
		hideDatabaseHost(command)
		command.Env = append(os.Environ(), "ITL_PROFILE_OWNER_FIXTURE_CONFIG="+path)
		go func(index int) { output, err := command.CombinedOutput(); results <- launchResult{index, err, output} }(i)
	}
	for completed := 0; completed < 2; completed++ {
		var result launchResult
		select {
		case result = <-results:
		case <-ctx.Done():
			t.Fatal("waiting chat did not progress", ctx.Err())
		}
		if result.err != nil {
			t.Fatalf("chat %d launcher: %v %s", result.index, result.err, result.output)
		}
		state := waitProfileState(t, root, func(s *profileOwnerState) bool {
			return s.Status == "running" && s.CallerID == fmt.Sprintf("chat-%d", result.index)
		})
		if state.Result == nil || state.Result.FeaturePath != features[result.index] {
			t.Fatal("another chat changed the owner's feature")
		}
		if completed == 0 {
			select {
			case premature := <-results:
				t.Fatalf("second chat completed before release: %v %s", premature.err, premature.output)
			default:
			}
		}
		response, err := requestProfileOwner(ctx, state, "stop", "", state.CallerID)
		if err != nil || response.Status != "stopped" || !response.CleanupConfirmed {
			t.Fatal(response, err)
		}
	}
}

func TestProfileOwnerNativeProcessOutlivesLauncherAndReleasesOnlyOnStop(t *testing.T) {
	python, runtimeRoot, request := databaseAccessFixture(t)
	root := filepath.Join(t.TempDir(), "Ручной профиль с пробелом")
	if err := os.MkdirAll(root, 0700); err != nil {
		t.Fatal(err)
	}
	feature := filepath.Join(root, "Сценарий профиля.feature")
	if err := os.WriteFile(feature, []byte("# fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	config := profileProcessFixtureConfig{Owner: profileOwnerConfig{ProjectRoot: root, InstanceID: strings.Repeat("a", 32), Generation: strings.Repeat("b", 32), CallerID: "test-caller"}, Request: request, Python: python, RuntimeRoot: runtimeRoot, Feature: feature}
	path := filepath.Join(root, "fixture.json")
	if err := writeProfileJSON(path, config); err != nil {
		t.Fatal(err)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	command := exec.Command(executable, "-test.run=^TestProfileOwnerProcessChild$", "launcher")
	hideDatabaseHost(command)
	command.Env = append(os.Environ(), "ITL_PROFILE_OWNER_FIXTURE_CONFIG="+path)
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("launcher: %v %s", err, output)
	}
	state, err := readProfileOwnerState(root)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_, _ = requestProfileOwner(ctx, state, "stop", "", "test-caller")
	})
	if command.ProcessState == nil || !command.ProcessState.Exited() {
		t.Fatal("launcher did not actually exit")
	}
	if state.Process.PID == command.Process.Pid {
		t.Fatal("reservation remained attached to the short-lived launcher")
	}
	if alive, err := profileOwnerIsAlive(state); err != nil || !alive {
		t.Fatal("persistent owner exited with launcher", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	other, err := acquireDatabasePipeOwner(ctx, python, runtimeRoot, request, nil)
	if other != nil {
		_ = other.Close()
	}
	if err == nil || !strings.Contains(err.Error(), "WAIT_TIMEOUT") {
		t.Fatal("launcher exit freed a still-open profile", err)
	}
	secondCaller := config.Owner
	secondCaller.CallerID = "second-chat"
	secondCaller.Generation = strings.Repeat("c", 32)
	secondDone := make(chan error, 1)
	go func() {
		_, err := ensureProfileOwner(ctx, secondCaller, func(profileOwnerConfig) (profileProcessIdentity, error) {
			alive, err := profileOwnerIsAlive(state)
			if err != nil || alive {
				return profileProcessIdentity{}, fmt.Errorf("started-before-owner-exit: %v", err)
			}
			return profileProcessIdentity{}, fmt.Errorf("second-caller-admitted-after-stop")
		})
		secondDone <- err
	}()
	response, err := requestProfileOwner(ctx, state, "stop", "", "test-caller")
	if err != nil || response.Status != "stopped" || !response.CleanupConfirmed {
		t.Fatal(response, err)
	}
	for {
		alive, err := profileOwnerIsAlive(state)
		if err != nil {
			t.Fatal(err)
		}
		if !alive {
			break
		}
		select {
		case <-ctx.Done():
			t.Fatal("owner did not exit after confirmed cleanup")
		case <-time.After(20 * time.Millisecond):
		}
	}
	if err := <-secondDone; err == nil || err.Error() != "second-caller-admitted-after-stop" {
		t.Fatal("second chat did not advance after confirmed owner exit", err)
	}
	owner := acquireDatabaseFixture(t, python, runtimeRoot, request)
	releaseDatabaseFixture(t, owner, nil)
	data, err := os.ReadFile(filepath.Join(profileOwnerRoot(root), "owner.json"))
	if err != nil {
		t.Fatal(err)
	}
	var public map[string]any
	if json.Unmarshal(data, &public) != nil {
		t.Fatal("invalid public owner state")
	}
	if _, found := public["proof"]; found {
		t.Fatal("private proof persisted in owner state")
	}
}

func TestProfileOwnerCrashRetainsDebtAndNeverRestartsNativeWork(t *testing.T) {
	python, runtimeRoot, request := databaseAccessFixture(t)
	root := filepath.Join(t.TempDir(), "Профиль после сбоя")
	if err := os.MkdirAll(root, 0700); err != nil {
		t.Fatal(err)
	}
	feature := filepath.Join(root, "Исходный сценарий.feature")
	if err := os.WriteFile(feature, []byte("# fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	config := profileProcessFixtureConfig{Owner: profileOwnerConfig{ProjectRoot: root, InstanceID: strings.Repeat("a", 32), Generation: strings.Repeat("b", 32), CallerID: "test-caller"}, Request: request, Python: python, RuntimeRoot: runtimeRoot, Feature: feature}
	path := filepath.Join(root, "fixture.json")
	if err := writeProfileJSON(path, config); err != nil {
		t.Fatal(err)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	command := exec.Command(executable, "-test.run=^TestProfileOwnerProcessChild$", "launcher")
	hideDatabaseHost(command)
	command.Env = append(os.Environ(), "ITL_PROFILE_OWNER_FIXTURE_CONFIG="+path)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("launcher: %v %s", err, output)
	}
	state, err := readProfileOwnerState(root)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_, _ = requestProfileOwner(ctx, state, "stop", "", "test-caller")
	})
	// Crash only the exact test owner, verifying creation time on the same
	// native handle used for termination. Never terminate by a recycled PID.
	handle, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION|windows.PROCESS_TERMINATE|windows.SYNCHRONIZE, false, uint32(state.Process.PID))
	if err != nil {
		t.Fatal(err)
	}
	defer windows.CloseHandle(handle)
	var created, exited, kernel, user windows.Filetime
	if err := windows.GetProcessTimes(handle, &created, &exited, &kernel, &user); err != nil {
		t.Fatal(err)
	}
	if fmt.Sprintf("%08x%08x", created.HighDateTime, created.LowDateTime) != state.Process.Started {
		t.Fatal("test owner identity changed")
	}
	if err := windows.TerminateProcess(handle, 1); err != nil {
		t.Fatal(err)
	}
	if status, err := windows.WaitForSingleObject(handle, 5000); err != nil || status != windows.WAIT_OBJECT_0 {
		t.Fatal("test owner exit unconfirmed", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for {
		other, err := acquireDatabasePipeOwner(ctx, python, runtimeRoot, request, nil)
		if other != nil {
			_ = other.Close()
			t.Fatal("crash released native reservation")
		}
		if err != nil && strings.Contains(err.Error(), "RECOVERY_REQUIRED") {
			break
		}
		if err == nil || !strings.Contains(err.Error(), "WAIT_TIMEOUT") {
			t.Fatal("unexpected crash state", err)
		}
		select {
		case <-ctx.Done():
			t.Fatal("native host did not record unconfirmed cleanup")
		case <-time.After(20 * time.Millisecond):
		}
	}
	launches := 0
	_, err = ensureProfileOwner(ctx, config.Owner, func(profileOwnerConfig) (profileProcessIdentity, error) {
		launches++
		return profileProcessIdentity{}, nil
	})
	if err == nil || !strings.Contains(err.Error(), "EXITED_UNCONFIRMED") || launches != 0 {
		t.Fatal("crashed profile was automatically restarted", err)
	}
}
