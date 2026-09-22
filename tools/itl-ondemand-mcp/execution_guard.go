package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"time"
)

type databaseConnection struct {
	Kind string `json:"kind"`
	Path string `json:"path"`
}

type executionContextProof struct {
	Encoded   string   `json:"executionContext"`
	Key       string   `json:"executionContextKey"`
	ID        string   `json:"executionId"`
	Resources []string `json:"resources"`
}

type executionGuardRequest struct {
	SchemaVersion       int                  `json:"schemaVersion"`
	Root                string               `json:"root"`
	Bases               []databaseConnection `json:"bases"`
	Operation           string               `json:"operation"`
	ExecutionID         string               `json:"executionId"`
	Timeout             float64              `json:"timeout"`
	InheritedContext    string               `json:"inheritedContext,omitempty"`
	InheritedContextKey string               `json:"inheritedContextKey,omitempty"`
}

type executionGuardEvent struct {
	Event               string   `json:"event"`
	Status              string   `json:"status"`
	Error               string   `json:"error"`
	ExecutionID         string   `json:"executionId"`
	Resources           []string `json:"resources"`
	WaitSeconds         float64  `json:"waitSeconds"`
	ExecutionContext    string   `json:"executionContext"`
	ExecutionContextKey string   `json:"executionContextKey"`
}

type executionGuardOwner struct {
	Proof     executionContextProof
	command   *exec.Cmd
	input     io.WriteCloser
	events    chan executionGuardEvent
	done      chan struct{}
	abandoned chan struct{}
	closeOnce sync.Once
	writeMu   sync.Mutex
	waitErr   error
}

var executionIDPattern = regexp.MustCompile(`^[a-f0-9]{32}$`)

func newExecutionID() (string, error) {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", fmt.Errorf("EXECUTION_ID_GENERATION_FAILED: %w", err)
	}
	return hex.EncodeToString(raw[:]), nil
}

func acquireExecutionGuard(ctx context.Context, python, runtimeRoot string, request executionGuardRequest,
	progress func(executionGuardEvent)) (*executionGuardOwner, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if python == "" {
		python = "python"
	}
	cmd := exec.Command(python, "-B", "-X", "utf8", "-u", "-m", "itl_remote.execution_guard_host")
	cmd.Dir = runtimeRoot
	cmd.Env = executionHostEnvironment(runtimeRoot)
	hideExecutionGuardHost(cmd)
	cmd.Stderr = io.Discard
	input, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	output, err := cmd.StdoutPipe()
	if err != nil {
		_ = input.Close()
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		_ = input.Close()
		_ = output.Close()
		return nil, fmt.Errorf("EXECUTION_GUARD_HOST_START_FAILED: %w", err)
	}
	owner := &executionGuardOwner{command: cmd, input: input, events: make(chan executionGuardEvent, 1),
		done: make(chan struct{}), abandoned: make(chan struct{})}
	go owner.read(output)
	if err := owner.send(request); err != nil {
		_ = owner.Close()
		return nil, err
	}
	for {
		event, err := owner.next(ctx)
		if err != nil {
			_ = owner.Close()
			return nil, err
		}
		switch event.Event {
		case "waiting":
			if progress != nil {
				progress(event)
			}
		case "admitted":
			if !executionIDPattern.MatchString(event.ExecutionID) || event.ExecutionContext == "" || event.ExecutionContextKey == "" || len(event.Resources) == 0 {
				_ = owner.Close()
				return nil, errors.New("EXECUTION_GUARD_HOST_PROOF_INVALID")
			}
			owner.Proof = executionContextProof{Encoded: event.ExecutionContext, Key: event.ExecutionContextKey,
				ID: event.ExecutionID, Resources: event.Resources}
			if err := ctx.Err(); err != nil {
				cleanupCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				defer cancel()
				return nil, errors.Join(err, owner.Release(cleanupCtx, "cancelled", err.Error()))
			}
			return owner, nil
		default:
			_ = owner.Close()
			return nil, errors.New("EXECUTION_GUARD_HOST_RESPONSE_INVALID")
		}
	}
}

func executionHostEnvironment(runtimeRoot string) []string {
	values := map[string]string{"PYTHONPATH": runtimeRoot, "PYTHONUTF8": "1", "PYTHONIOENCODING": "utf-8", "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1"}
	result := []string{}
	for _, value := range os.Environ() {
		key, _, _ := strings.Cut(value, "=")
		if strings.EqualFold(key, "PYTHONHOME") {
			continue
		}
		if _, replaced := values[strings.ToUpper(key)]; !replaced {
			result = append(result, value)
		}
	}
	for key, value := range values {
		result = append(result, key+"="+value)
	}
	return result
}

func (owner *executionGuardOwner) read(output io.Reader) {
	defer close(owner.done)
	defer close(owner.events)
	decoder := json.NewDecoder(output)
	for {
		var event executionGuardEvent
		if err := decoder.Decode(&event); err != nil {
			if !errors.Is(err, io.EOF) {
				owner.publish(executionGuardEvent{Event: "error", Error: "EXECUTION_GUARD_HOST_RESPONSE_INVALID"})
			}
			_, _ = io.Copy(io.Discard, output)
			owner.waitErr = owner.command.Wait()
			return
		}
		owner.publish(event)
	}
}

func (owner *executionGuardOwner) publish(event executionGuardEvent) {
	select {
	case owner.events <- event:
	case <-owner.abandoned:
	}
}

func (owner *executionGuardOwner) send(value any) error {
	owner.writeMu.Lock()
	defer owner.writeMu.Unlock()
	if err := json.NewEncoder(owner.input).Encode(value); err != nil {
		return errors.New("EXECUTION_GUARD_HOST_WRITE_FAILED")
	}
	return nil
}

func (owner *executionGuardOwner) next(ctx context.Context) (executionGuardEvent, error) {
	select {
	case event, ok := <-owner.events:
		if !ok {
			return executionGuardEvent{}, errors.New("EXECUTION_GUARD_HOST_DISCONNECTED")
		}
		if event.Event == "error" {
			return executionGuardEvent{}, errors.New(event.Error)
		}
		return event, nil
	case <-ctx.Done():
		return executionGuardEvent{}, ctx.Err()
	}
}

func (owner *executionGuardOwner) Release(ctx context.Context, result, message string) error {
	defer owner.Close()
	if result == "" {
		result = "succeeded"
	}
	if err := owner.send(map[string]any{"action": "release", "result": result, "error": message}); err != nil {
		return err
	}
	event, err := owner.next(ctx)
	if err != nil {
		return err
	}
	if event.Event != "released" || event.Status != result {
		return errors.New("EXECUTION_GUARD_HOST_RELEASE_UNCONFIRMED")
	}
	select {
	case <-owner.done:
		if owner.waitErr != nil {
			return errors.New("EXECUTION_GUARD_HOST_RELEASE_UNCONFIRMED")
		}
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (owner *executionGuardOwner) Close() error {
	owner.closeOnce.Do(func() {
		close(owner.abandoned)
		_ = owner.input.Close()
	})
	select {
	case <-owner.done:
		return nil
	case <-time.After(5 * time.Second):
		_ = owner.command.Process.Kill()
	}
	select {
	case <-owner.done:
		return errors.New("EXECUTION_GUARD_HOST_EXIT_TIMEOUT")
	case <-time.After(5 * time.Second):
		return errors.New("EXECUTION_GUARD_HOST_EXIT_UNCONFIRMED")
	}
}
