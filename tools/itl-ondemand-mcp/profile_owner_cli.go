package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

const profileOwnerResultMarker = "ITL_VANESSA_PROFILE_OWNER_RESULT="

func resolveProfileCaller(explicit string, create bool) (string, error) {
	value := explicit
	if value == "" && os.Getenv("CODEX_THREAD_ID") != "" {
		value = "codex:" + os.Getenv("CODEX_THREAD_ID")
	}
	if value == "" && create {
		id, err := randomID()
		if err != nil {
			return "", err
		}
		value = "session:" + id
	}
	if !profileCallerPattern.MatchString(value) {
		return "", fmt.Errorf("ITL_PROFILE_OWNER_CALLER_REQUIRED: use the session owner ID returned by start when no chat identity is available")
	}
	return value, nil
}

func runProfileOwner(args []string) error {
	flags := flag.NewFlagSet("vanessa-profile-owner", flag.ContinueOnError)
	var config profileOwnerConfig
	flags.StringVar(&config.ProjectRoot, "project-root", "", "absolute project root")
	flags.StringVar(&config.CatalogPath, "catalog", "", "verified Vanessa catalog")
	flags.StringVar(&config.HelperPath, "helper", "", "workflow helper")
	flags.StringVar(&config.InstanceID, "instance-id", "", "owned runtime instance")
	flags.StringVar(&config.Generation, "owner-generation", "", "control generation")
	flags.StringVar(&config.CallerID, "caller-id", "", "interactive session owner")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if os.Getenv("ITL_INFOBASE_ACCESS_LEASE") != "" || os.Getenv("ITL_DATABASE_ACCESS_CONTEXT") != "" {
		return fmt.Errorf("ITL_PROFILE_OWNER_MUST_OWN_ITS_LIFETIME")
	}
	rt, err := newProfileOwnerRuntime(config, false)
	if err != nil {
		return err
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), time.Minute)
		defer cancel()
		_ = rt.close(cleanup)
	}()
	return serveProfileOwner(context.Background(), config, profileOwnerCallbacks{
		Open: func(ctx context.Context, feature string) (*vanessaProfileResult, error) {
			return startInteractiveVanessaProfile(ctx, rt, feature)
		},
		Stop: rt.stopOwnedRuntime,
		NativeExited: func() bool {
			rt.mu.Lock()
			defer rt.mu.Unlock()
			if rt.backend == nil || rt.backend.PID <= 0 || rt.backend.TestClientPID <= 0 {
				return false
			}
			_, managerErr := readProfileProcessIdentity(rt.backend.PID)
			_, clientErr := readProfileProcessIdentity(rt.backend.TestClientPID)
			return errors.Is(managerErr, os.ErrNotExist) && errors.Is(clientErr, os.ErrNotExist)
		},
	})
}

func runProfileOwnerControl(operation string, args []string) error {
	flags := flag.NewFlagSet("vanessa-profile-"+operation, flag.ContinueOnError)
	root := flags.String("project-root", "", "project root")
	instance := flags.String("instance-id", "", "expected runtime instance")
	generation := flags.String("owner-generation", "", "expected control generation")
	callerID := flags.String("caller-id", "", "interactive session owner; defaults to the current Codex thread")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *root == "" {
		return fmt.Errorf("--project-root is required")
	}
	absolute, err := filepath.Abs(*root)
	if err != nil {
		return err
	}
	state, err := readProfileOwnerState(absolute)
	if err != nil {
		return err
	}
	if (*instance != "" && *instance != state.InstanceID) || (*generation != "" && *generation != state.Generation) {
		return fmt.Errorf("ITL_PROFILE_OWNER_GENERATION_CHANGED")
	}
	var result any = state
	if operation == "stop" {
		caller, err := resolveProfileCaller(*callerID, false)
		if err != nil {
			return err
		}
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
		defer cancel()
		response, err := requestProfileOwner(ctx, state, "stop", "", caller)
		if err != nil {
			return err
		}
		if response.Status != "stopped" || !response.CleanupConfirmed {
			return fmt.Errorf("ITL_PROFILE_OWNER_STOP_UNCONFIRMED: %s", response.Error)
		}
		result = response
	} else {
		alive, err := profileOwnerIsAlive(state)
		if err != nil {
			return err
		}
		if !alive && !state.CleanupConfirmed {
			state.Status = "owner-exited-unconfirmed"
		} else if !alive {
			state.Status = "stopped"
		}
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		return err
	}
	fmt.Printf("%s%s\n", profileOwnerResultMarker, encoded)
	return nil
}
