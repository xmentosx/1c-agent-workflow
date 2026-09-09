package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

func profileOwnerArguments(config profileOwnerConfig) []string {
	return []string{"vanessa-profile-owner", "--project-root", config.ProjectRoot, "--catalog", config.CatalogPath, "--helper", config.HelperPath,
		"--instance-id", config.InstanceID, "--owner-generation", config.Generation, "--caller-id", config.CallerID}
}

func launchProfileOwner(executable string, args []string, projectRoot string) (profileProcessIdentity, error) {
	root := profileOwnerRoot(projectRoot)
	if err := os.MkdirAll(root, 0700); err != nil {
		return profileProcessIdentity{}, err
	}
	log, err := os.OpenFile(filepath.Join(root, "owner.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		return profileProcessIdentity{}, err
	}
	defer log.Close()
	command := exec.Command(executable, args...)
	hideDatabaseHost(command)
	command.Stdout, command.Stderr = log, log
	// A manual owner must own its reservation itself. It may not accidentally
	// adopt a short-lived invoking process's environment or private broker proof.
	command.Env, err = databaseBrokerEnvironment(context.Background())
	if err != nil {
		return profileProcessIdentity{}, err
	}
	if err := command.Start(); err != nil {
		return profileProcessIdentity{}, err
	}
	identity, identityErr := readProfileProcessIdentity(command.Process.Pid)
	_ = command.Process.Release()
	if identityErr != nil {
		return identity, fmt.Errorf("inspect launched profile owner: %w", identityErr)
	}
	return identity, identityErr
}

func ensureProfileOwner(ctx context.Context, config profileOwnerConfig, launch func(profileOwnerConfig) (profileProcessIdentity, error)) (*profileOwnerState, error) {
	if !profileCallerPattern.MatchString(config.CallerID) {
		return nil, fmt.Errorf("ITL_PROFILE_OWNER_CALLER_REQUIRED")
	}
	var launched *profileProcessIdentity
	var launchError error
	var launchErrorDeadline time.Time
	ticker := time.NewTicker(50 * time.Millisecond)
	defer ticker.Stop()
	for {
		state, err := readProfileOwnerState(config.ProjectRoot)
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return nil, err
		}
		if state != nil {
			alive, err := profileOwnerIsAlive(state)
			if err != nil {
				return nil, err
			}
			if alive && state.Status != "stopped" {
				if state.Status == "needs-attention" {
					return nil, fmt.Errorf("ITL_PROFILE_OWNER_RECOVERY_REQUIRED")
				}
				if state.CallerID != config.CallerID {
					// Another verified live owner explains a launch that lost
					// the startup race before its child identity was observable.
					launchError = nil
					if launched != nil {
						actual, inspectErr := readProfileProcessIdentity(launched.PID)
						if errors.Is(inspectErr, os.ErrNotExist) || (inspectErr == nil && actual.Started != launched.Started) {
							// A simultaneous launch can lose the lifetime lock.
							// No open has been sent by this client yet; after the
							// winning owner stops, this caller may launch once more.
							launched = nil
						} else if inspectErr != nil {
							return nil, inspectErr
						}
					}
					// Branch-local state identifies the busy owner; it does not
					// grant another chat permission to reuse that owner's pair.
					select {
					case <-ctx.Done():
						return nil, fmt.Errorf("ITL_PROFILE_OWNER_WAIT_CANCELLED: %w", ctx.Err())
					case <-ticker.C:
						continue
					}
				}
				if state.InstanceID != config.InstanceID {
					return nil, fmt.Errorf("ITL_PROFILE_OWNER_INSTANCE_CONFLICT")
				}
				return state, nil
			}
			if !alive && !state.CleanupConfirmed {
				return nil, fmt.Errorf("ITL_PROFILE_OWNER_EXITED_UNCONFIRMED")
			}
			if alive {
				select {
				case <-ctx.Done():
					return nil, ctx.Err()
				case <-ticker.C:
					continue
				}
			}
		}
		if launchError != nil {
			if !time.Now().Before(launchErrorDeadline) {
				return nil, launchError
			}
		} else if launched == nil {
			identity, err := launch(config)
			if err != nil {
				launchError = err
				launchErrorDeadline = time.Now().Add(2 * time.Second)
			} else {
				launched = &identity
			}
		} else {
			identity, err := readProfileProcessIdentity(launched.PID)
			if errors.Is(err, os.ErrNotExist) {
				return nil, fmt.Errorf("ITL_PROFILE_OWNER_START_EXITED")
			}
			if err != nil {
				return nil, err
			}
			if identity.Started != launched.Started {
				return nil, fmt.Errorf("ITL_PROFILE_OWNER_START_IDENTITY_CHANGED")
			}
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-ticker.C:
		}
	}
}

func submitProfileOwnerRequest(state *profileOwnerState, operation, featurePath, callerID string) (profileOwnerRequest, error) {
	id, err := randomID()
	if err != nil {
		return profileOwnerRequest{}, err
	}
	request := profileOwnerRequest{SchemaVersion: 1, ProjectRoot: state.ProjectRoot, InstanceID: state.InstanceID, Generation: state.Generation, CallerID: callerID, RequestID: id, Operation: operation, FeaturePath: featurePath}
	request.ClientProcess, err = readProfileProcessIdentity(os.Getpid())
	if err != nil {
		return request, err
	}
	if err := validateProfileRequest(&request, state, id); err != nil {
		return request, err
	}
	err = writeProfileJSON(profileControlPath(profileOwnerRoot(state.ProjectRoot), state.Generation, "requests", id), request)
	return request, err
}

func awaitProfileOwnerResponse(ctx context.Context, state *profileOwnerState, request profileOwnerRequest) (*profileOwnerResponse, error) {
	return awaitProfileOwnerResponseWithLiveness(ctx, state, request, profileOwnerIsAlive)
}

func awaitProfileOwnerResponseWithLiveness(ctx context.Context, state *profileOwnerState, request profileOwnerRequest, isAlive func(*profileOwnerState) (bool, error)) (*profileOwnerResponse, error) {
	ticker := time.NewTicker(50 * time.Millisecond)
	defer ticker.Stop()
	ownerExited := false
	for {
		var response profileOwnerResponse
		err := readProfileJSON(profileControlPath(profileOwnerRoot(state.ProjectRoot), state.Generation, "responses", request.RequestID), &response)
		if err == nil {
			if response.SchemaVersion != 1 || response.Generation != state.Generation || response.RequestID != request.RequestID {
				return nil, fmt.Errorf("ITL_PROFILE_OWNER_RESPONSE_INVALID")
			}
			return &response, nil
		}
		if !errors.Is(err, os.ErrNotExist) {
			return nil, err
		}
		if ownerExited {
			return nil, fmt.Errorf("ITL_PROFILE_OWNER_EXITED_UNCONFIRMED")
		}
		alive, err := isAlive(state)
		if err != nil {
			return nil, err
		}
		if !alive {
			// Normal stop persists its response before exiting. It can finish
			// between our file read and process inspection; read once more
			// after confirmed exit before treating the response as missing.
			ownerExited = true
			continue
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-ticker.C:
		}
	}
}

func requestProfileOwner(ctx context.Context, state *profileOwnerState, operation, featurePath, callerID string) (*profileOwnerResponse, error) {
	if !profileCallerPattern.MatchString(callerID) || callerID != state.CallerID {
		return nil, fmt.Errorf("ITL_PROFILE_OWNER_CALLER_MISMATCH")
	}
	if operation == "stop" && state.Status == "stopped" && state.CleanupConfirmed {
		return &profileOwnerResponse{SchemaVersion: 1, Generation: state.Generation, Status: "stopped", CleanupConfirmed: true}, nil
	}
	alive, err := profileOwnerIsAlive(state)
	if err != nil {
		return nil, err
	}
	if !alive {
		if operation == "stop" && state.Status == "stopped" && state.CleanupConfirmed {
			return &profileOwnerResponse{SchemaVersion: 1, Generation: state.Generation, Status: "stopped", CleanupConfirmed: true}, nil
		}
		return nil, fmt.Errorf("ITL_PROFILE_OWNER_EXITED_UNCONFIRMED")
	}
	request, err := submitProfileOwnerRequest(state, operation, featurePath, callerID)
	if err != nil {
		return nil, err
	}
	response, err := awaitProfileOwnerResponse(ctx, state, request)
	if err != nil && ctx.Err() != nil && operation == "open" {
		// Cancel the accepted request once; never repeat opening a feature to
		// recover a lost response. The owner serializes cancellation and cleanup.
		id, idErr := randomID()
		if idErr == nil {
			cancelRequest := profileOwnerRequest{SchemaVersion: 1, ProjectRoot: state.ProjectRoot, InstanceID: state.InstanceID, Generation: state.Generation, CallerID: callerID, RequestID: id, Operation: "cancel", CancelRequestID: request.RequestID}
			cancelRequest.ClientProcess = request.ClientProcess
			_ = writeProfileJSON(profileControlPath(profileOwnerRoot(state.ProjectRoot), state.Generation, "requests", id), cancelRequest)
		}
	}
	return response, err
}
