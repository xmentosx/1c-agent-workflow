package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

var profileIdentityPattern = regexp.MustCompile(`^[a-f0-9]{32}$`)
var profileCallerPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`)

type profileOwnerConfig struct {
	ProjectRoot string `json:"projectRoot"`
	CatalogPath string `json:"catalogPath"`
	HelperPath  string `json:"helperPath"`
	InstanceID  string `json:"instanceId"`
	Generation  string `json:"generation"`
	CallerID    string `json:"callerId"`
}

type profileProcessIdentity struct {
	PID        int    `json:"pid"`
	Started    string `json:"started"`
	Executable string `json:"executable"`
}

// This is public control/diagnostic state. No database proof or credentials
// belong in this descriptor, requests, responses or the owner's log.
type profileOwnerState struct {
	SchemaVersion    int                    `json:"schemaVersion"`
	ProjectRoot      string                 `json:"projectRoot"`
	InstanceID       string                 `json:"instanceId"`
	Generation       string                 `json:"generation"`
	CallerID         string                 `json:"callerId"`
	Process          profileProcessIdentity `json:"process"`
	Status           string                 `json:"status"`
	RequestID        string                 `json:"requestId,omitempty"`
	UpdatedAt        string                 `json:"updatedAt"`
	CleanupConfirmed bool                   `json:"cleanupConfirmed"`
	Result           *vanessaProfileResult  `json:"result,omitempty"`
	Error            string                 `json:"error,omitempty"`
}

type profileOwnerRequest struct {
	SchemaVersion   int                    `json:"schemaVersion"`
	ProjectRoot     string                 `json:"projectRoot"`
	InstanceID      string                 `json:"instanceId"`
	Generation      string                 `json:"generation"`
	CallerID        string                 `json:"callerId"`
	RequestID       string                 `json:"requestId"`
	Operation       string                 `json:"operation"`
	FeaturePath     string                 `json:"featurePath,omitempty"`
	CancelRequestID string                 `json:"cancelRequestId,omitempty"`
	ClientProcess   profileProcessIdentity `json:"clientProcess"`
}

type profileOwnerResponse struct {
	SchemaVersion    int                   `json:"schemaVersion"`
	Generation       string                `json:"generation"`
	RequestID        string                `json:"requestId"`
	Status           string                `json:"status"`
	CleanupConfirmed bool                  `json:"cleanupConfirmed"`
	Result           *vanessaProfileResult `json:"result,omitempty"`
	Error            string                `json:"error,omitempty"`
}

type profileOwnerCallbacks struct {
	Open         func(context.Context, string) (*vanessaProfileResult, error)
	Stop         func(context.Context) error
	NativeExited func() bool
}

func profileOwnerRoot(projectRoot string) string {
	return filepath.Join(projectRoot, ".agent-1c", "mcp", "vanessa-profile-owner")
}

func profileControlPath(root, generation, category, requestID string) string {
	return filepath.Join(root, generation, category, requestID+".json")
}

func retryProfileControlIO(operation func() error) error {
	deadline := time.Now().Add(2 * time.Second)
	for {
		err := operation()
		if !profileControlSharingViolation(err) || !time.Now().Before(deadline) {
			return err
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func writeProfileJSON(path string, value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	id, err := randomID()
	if err != nil {
		return err
	}
	temporary := path + ".tmp-" + id
	if err := os.WriteFile(temporary, data, 0600); err != nil {
		return err
	}
	if err := retryProfileControlIO(func() error { return os.Rename(temporary, path) }); err != nil {
		_ = os.Remove(temporary)
		return err
	}
	return nil
}

func readProfileJSON(path string, value any) error {
	var file *os.File
	err := retryProfileControlIO(func() error {
		var err error
		file, err = os.Open(path)
		return err
	})
	if err != nil {
		return err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return err
	}
	if info.Size() > 1024*1024 {
		return fmt.Errorf("ITL_PROFILE_OWNER_CONTROL_TOO_LARGE")
	}
	return json.NewDecoder(file).Decode(value)
}

func readProfileOwnerState(projectRoot string) (*profileOwnerState, error) {
	var state profileOwnerState
	if err := readProfileJSON(filepath.Join(profileOwnerRoot(projectRoot), "owner.json"), &state); err != nil {
		return nil, fmt.Errorf("read profile owner state: %w", err)
	}
	if state.SchemaVersion != 1 || !profileIdentityPattern.MatchString(state.InstanceID) || !profileIdentityPattern.MatchString(state.Generation) ||
		!strings.EqualFold(filepath.Clean(state.ProjectRoot), filepath.Clean(projectRoot)) || state.Process.PID <= 0 || state.Process.Started == "" || state.Process.Executable == "" {
		return nil, fmt.Errorf("ITL_PROFILE_OWNER_STATE_INVALID")
	}
	return &state, nil
}

func profileOwnerIsAlive(state *profileOwnerState) (bool, error) {
	actual, err := readProfileProcessIdentity(state.Process.PID)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("inspect profile owner process: %w", err)
	}
	return actual.Started == state.Process.Started && strings.EqualFold(actual.Executable, state.Process.Executable), nil
}

func validateProfileRequest(request *profileOwnerRequest, state *profileOwnerState, id string) error {
	if !profileCallerPattern.MatchString(request.CallerID) || request.CallerID != state.CallerID {
		return fmt.Errorf("ITL_PROFILE_OWNER_CALLER_MISMATCH")
	}
	if request.SchemaVersion != 1 || request.Generation != state.Generation || request.InstanceID != state.InstanceID || request.RequestID != id ||
		!strings.EqualFold(filepath.Clean(request.ProjectRoot), filepath.Clean(state.ProjectRoot)) || request.ClientProcess.PID <= 0 || request.ClientProcess.Started == "" || request.ClientProcess.Executable == "" {
		return fmt.Errorf("ITL_PROFILE_OWNER_REQUEST_SCOPE_INVALID")
	}
	if request.Operation != "open" && request.Operation != "stop" && request.Operation != "cancel" {
		return fmt.Errorf("ITL_PROFILE_OWNER_OPERATION_INVALID")
	}
	if request.Operation == "cancel" && !profileIdentityPattern.MatchString(request.CancelRequestID) {
		return fmt.Errorf("ITL_PROFILE_OWNER_CANCEL_ID_INVALID")
	}
	if request.Operation == "open" {
		if !filepath.IsAbs(request.FeaturePath) || filepath.Ext(request.FeaturePath) != ".feature" {
			return fmt.Errorf("ITL_PROFILE_OWNER_FEATURE_INVALID")
		}
		info, err := os.Stat(request.FeaturePath)
		if err != nil || info.IsDir() {
			return fmt.Errorf("ITL_PROFILE_OWNER_FEATURE_INVALID")
		}
	}
	return nil
}

type profileOwnerCompletion struct {
	result *vanessaProfileResult
	err    error
}

func profileOwnerErrorCode(err error) string {
	if err == nil {
		return ""
	}
	code := regexp.MustCompile(`\b(?:ITL|INFOBASE_ACCESS)_[A-Z0-9_]+\b`).FindString(err.Error())
	if code == "" {
		return "ITL_PROFILE_OWNER_OPERATION_FAILED"
	}
	return code
}

// One actor owns the runtime and its private pipe for the complete manual
// lifetime. Stop can cancel an active open, but never runs cleanup concurrently
// with it. Requests are idempotent by generation/id, not replayed after a crash.
func serveProfileOwner(ctx context.Context, config profileOwnerConfig, callbacks profileOwnerCallbacks) error {
	if !filepath.IsAbs(config.ProjectRoot) || !profileIdentityPattern.MatchString(config.InstanceID) || !profileIdentityPattern.MatchString(config.Generation) || !profileCallerPattern.MatchString(config.CallerID) {
		return fmt.Errorf("ITL_PROFILE_OWNER_CONFIG_INVALID")
	}
	root := profileOwnerRoot(config.ProjectRoot)
	lock, err := acquireProfileOwnerLock(filepath.Join(root, "owner.lock"))
	if err != nil {
		return err
	}
	defer lock.Close()
	previous, err := readProfileOwnerState(config.ProjectRoot)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if previous != nil {
		alive, err := profileOwnerIsAlive(previous)
		if err != nil {
			return err
		}
		if alive || !previous.CleanupConfirmed {
			return fmt.Errorf("ITL_PROFILE_OWNER_RECOVERY_REQUIRED")
		}
	}
	identity, err := readProfileProcessIdentity(os.Getpid())
	if err != nil {
		return err
	}
	state := &profileOwnerState{SchemaVersion: 1, ProjectRoot: config.ProjectRoot, InstanceID: config.InstanceID, Generation: config.Generation, CallerID: config.CallerID, Process: identity, Status: "ready", CleanupConfirmed: true}
	statePath := filepath.Join(root, "owner.json")
	writeState := func() error {
		state.UpdatedAt = time.Now().UTC().Format(time.RFC3339Nano)
		return writeProfileJSON(statePath, state)
	}
	if err := writeState(); err != nil {
		return err
	}
	requestsPath := filepath.Join(root, config.Generation, "requests")
	if err := os.MkdirAll(requestsPath, 0700); err != nil {
		return err
	}
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	readySince := time.Now()
	var active *profileOwnerRequest
	var cancelActive context.CancelFunc
	var completion chan profileOwnerCompletion
	pendingStops := []profileOwnerRequest{}
	seen := map[string]bool{}
	stopRequested := false
	response := func(request profileOwnerRequest, status string, result *vanessaProfileResult, err error) error {
		value := profileOwnerResponse{SchemaVersion: 1, Generation: state.Generation, RequestID: request.RequestID, Status: status, CleanupConfirmed: state.CleanupConfirmed, Result: result}
		if err != nil {
			value.Error = profileOwnerErrorCode(err)
		}
		return writeProfileJSON(profileControlPath(root, state.Generation, "responses", request.RequestID), value)
	}
	beginStop := func() {
		state.Status = "stopping"
		completion = make(chan profileOwnerCompletion, 1)
		go func(done chan profileOwnerCompletion) {
			cleanup, cancel := context.WithTimeout(context.Background(), time.Minute)
			defer cancel()
			done <- profileOwnerCompletion{err: callbacks.Stop(cleanup)}
		}(completion)
	}
	for {
		select {
		case <-ctx.Done():
			if cancelActive != nil {
				cancelActive()
			}
			// The process/pipe owns crash recovery. An unobserved operation may
			// not turn into a clean state just because the control loop ended.
			state.Status = "needs-attention"
			state.CleanupConfirmed = false
			_ = writeState()
			return ctx.Err()
		case done := <-completion:
			completion = nil
			if active != nil {
				cancelActive()
				cancelActive = nil
				finished := *active
				active = nil
				if done.err != nil {
					state.Error = profileOwnerErrorCode(done.err)
					if err := response(finished, "failed", nil, done.err); err != nil {
						return err
					}
					stopRequested = true
				} else {
					state.Result = done.result
					state.Status = "running"
					if err := writeState(); err != nil {
						return err
					}
					if err := response(finished, "running", done.result, nil); err != nil {
						return err
					}
				}
				if stopRequested {
					beginStop()
				}
			} else {
				state.CleanupConfirmed = done.err == nil
				if done.err == nil {
					state.Status = "stopped"
					state.Error = ""
				} else {
					state.Status = "needs-attention"
					state.Error = profileOwnerErrorCode(done.err)
				}
				if err := writeState(); err != nil {
					return err
				}
				for _, request := range pendingStops {
					if err := response(request, state.Status, nil, done.err); err != nil {
						return err
					}
				}
				pendingStops = nil
				stopRequested = false
				if done.err == nil {
					return nil
				}
			}
			if err := writeState(); err != nil {
				return err
			}
		case <-ticker.C:
			if active != nil {
				alive, inspectionErr := profileOwnerIsAlive(&profileOwnerState{Process: active.ClientProcess})
				if inspectionErr == nil && !alive {
					cancelActive()
					stopRequested = true
				}
			}
			files, err := os.ReadDir(requestsPath)
			if err != nil {
				return err
			}
			for _, file := range files {
				id := strings.TrimSuffix(file.Name(), ".json")
				if file.IsDir() || file.Name() != id+".json" || !profileIdentityPattern.MatchString(id) || seen[id] {
					continue
				}
				seen[id] = true
				var request profileOwnerRequest
				err := readProfileJSON(filepath.Join(requestsPath, file.Name()), &request)
				if err == nil {
					err = validateProfileRequest(&request, state, id)
				}
				if err != nil {
					request.RequestID = id
					if err := response(request, "rejected", nil, fmt.Errorf("ITL_PROFILE_OWNER_REQUEST_INVALID")); err != nil {
						return err
					}
					continue
				}
				if request.Operation == "cancel" && request.CancelRequestID != state.RequestID {
					if err := response(request, "cancelled-no-active-operation", nil, nil); err != nil {
						return err
					}
					continue
				}
				if request.Operation == "stop" || request.Operation == "cancel" {
					pendingStops = append(pendingStops, request)
					stopRequested = true
					if cancelActive != nil {
						cancelActive()
					}
					continue
				}
				if active != nil || completion != nil || stopRequested || state.Status == "needs-attention" {
					if err := response(request, "rejected", nil, fmt.Errorf("ITL_PROFILE_OWNER_BUSY_OR_UNCONFIRMED")); err != nil {
						return err
					}
					continue
				}
				alive, inspectionErr := profileOwnerIsAlive(&profileOwnerState{Process: request.ClientProcess})
				if inspectionErr != nil || !alive {
					if err := response(request, "rejected", nil, fmt.Errorf("ITL_PROFILE_OWNER_CLIENT_EXITED_OR_UNVERIFIED")); err != nil {
						return err
					}
					continue
				}
				state.Status = "preparing"
				state.CleanupConfirmed = false
				state.RequestID = request.RequestID
				if err := writeState(); err != nil {
					return err
				}
				active = &request
				operationCtx, cancel := context.WithCancel(ctx)
				cancelActive = cancel
				completion = make(chan profileOwnerCompletion, 1)
				go func(feature string, done chan profileOwnerCompletion) {
					result, err := callbacks.Open(operationCtx, feature)
					done <- profileOwnerCompletion{result: result, err: err}
				}(request.FeaturePath, completion)
			}
			if active == nil && completion == nil {
				if state.Status == "running" && callbacks.NativeExited != nil && callbacks.NativeExited() {
					stopRequested = true
				}
				if state.Status == "ready" && time.Since(readySince) > 30*time.Second {
					stopRequested = true
				}
				if stopRequested {
					beginStop()
					if err := writeState(); err != nil {
						return err
					}
				}
			}
		}
	}
}
