package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

type databaseConnection struct {
	Kind string `json:"kind"`
	Path string `json:"path"`
}

type databaseAccessProof struct {
	Coordinator string `json:"coordinator"`
	Ticket      string `json:"ticket"`
	Token       string `json:"token"`
	Purpose     string `json:"purpose,omitempty"`
}

type databaseAccessRequest struct {
	SchemaVersion int                  `json:"schemaVersion"`
	Coordinator   string               `json:"coordinator"`
	Bases         []databaseConnection `json:"bases"`
	Owner         map[string]any       `json:"owner"`
	Timeout       float64              `json:"timeout"`
	Inherited     *databaseAccessProof `json:"inherited,omitempty"`
	Purpose       string               `json:"purpose,omitempty"`
}

type databaseAccessEvent struct {
	Event     string               `json:"event"`
	Status    string               `json:"status"`
	Error     string               `json:"error"`
	Proof     *databaseAccessProof `json:"proof,omitempty"`
	Owner     json.RawMessage      `json:"owner,omitempty"`
	Resources []string             `json:"resources,omitempty"`
	Blockers  json.RawMessage      `json:"blockers,omitempty"`
}

// The pipes and Proof are private to the native owner. Never log this object.
// Closing without Release leaves admitted work for recovery, not for replay.
type databasePipeOwner struct {
	Proof     *databaseAccessProof
	Public    json.RawMessage
	command   *exec.Cmd
	input     io.WriteCloser
	events    chan databaseAccessEvent
	done      chan struct{}
	abandoned chan struct{}
	closeOnce sync.Once
	writeMu   sync.Mutex
	waitErr   error
}

func acquireDatabasePipeOwner(ctx context.Context, python, runtimeRoot string, request databaseAccessRequest, progress func(databaseAccessEvent)) (*databasePipeOwner, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if python == "" {
		python = "python"
	}
	cmd := exec.Command(python, "-B", "-X", "utf8", "-u", "-m", "itl_remote.access_host")
	cmd.Dir = runtimeRoot
	cmd.Env = databaseHostEnvironment(runtimeRoot)
	hideDatabaseHost(cmd)
	// The host emits sanitized error codes on stdout. Never include Python's
	// arbitrary stderr in public MCP errors or argument/evidence journals.
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
		return nil, fmt.Errorf("INFOBASE_ACCESS_HOST_START_FAILED: %w", err)
	}
	owner := &databasePipeOwner{command: cmd, input: input, events: make(chan databaseAccessEvent, 1),
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
			if event.Proof == nil || event.Proof.Ticket == "" || event.Proof.Token == "" || event.Proof.Coordinator == "" {
				_ = owner.Close()
				return nil, errors.New("INFOBASE_ACCESS_HOST_PROOF_INVALID")
			}
			owner.Proof, owner.Public = event.Proof, event.Owner
			if err := ctx.Err(); err != nil {
				// No operation has received this grant yet. Confirm that no work
				// ran, instead of manufacturing orphan debt for a known cancellation.
				cleanupCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				_, releaseErr := owner.Release(cleanupCtx, nil)
				cancel()
				return nil, errors.Join(err, releaseErr)
			}
			return owner, nil
		default:
			_ = owner.Close()
			return nil, errors.New("INFOBASE_ACCESS_HOST_RESPONSE_INVALID")
		}
	}
}

func databaseHostEnvironment(runtimeRoot string) []string {
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

func (owner *databasePipeOwner) read(output io.Reader) {
	defer close(owner.done)
	defer close(owner.events)
	decoder := json.NewDecoder(output)
	for {
		var event databaseAccessEvent
		if err := decoder.Decode(&event); err != nil {
			if !errors.Is(err, io.EOF) {
				owner.publish(databaseAccessEvent{Event: "error", Error: "INFOBASE_ACCESS_HOST_RESPONSE_INVALID"})
			}
			// Drain before Wait: Wait closes redirected pipes and could otherwise
			// race the final release response or strand a noisy failed child.
			_, _ = io.Copy(io.Discard, output)
			owner.waitErr = owner.command.Wait()
			return
		}
		owner.publish(event)
	}
}

func (owner *databasePipeOwner) publish(event databaseAccessEvent) {
	select {
	case owner.events <- event:
	case <-owner.abandoned:
	}
}

func (owner *databasePipeOwner) send(value any) error {
	owner.writeMu.Lock()
	defer owner.writeMu.Unlock()
	if err := json.NewEncoder(owner.input).Encode(value); err != nil {
		return errors.New("INFOBASE_ACCESS_HOST_WRITE_FAILED")
	}
	return nil
}

func (owner *databasePipeOwner) next(ctx context.Context) (databaseAccessEvent, error) {
	select {
	case event, ok := <-owner.events:
		if !ok {
			return databaseAccessEvent{}, errors.New("INFOBASE_ACCESS_HOST_DISCONNECTED")
		}
		if event.Event == "error" {
			return databaseAccessEvent{}, errors.New(event.Error)
		}
		return event, nil
	case <-ctx.Done():
		return databaseAccessEvent{}, ctx.Err()
	}
}

func (owner *databasePipeOwner) Release(ctx context.Context, cleanupErrors []string) (string, error) {
	defer owner.Close()
	if cleanupErrors == nil {
		cleanupErrors = []string{}
	}
	if err := owner.send(map[string]any{"event": "release", "cleanupErrors": cleanupErrors}); err != nil {
		return "", err
	}
	event, err := owner.next(ctx)
	if err != nil {
		return "", err
	}
	if event.Event != "released" || (event.Status != "released" && event.Status != "needs-attention") {
		return "", errors.New("INFOBASE_ACCESS_HOST_RELEASE_UNCONFIRMED")
	}
	select {
	case <-owner.done:
		if owner.waitErr != nil {
			return "", errors.New("INFOBASE_ACCESS_HOST_RELEASE_UNCONFIRMED")
		}
		return event.Status, nil
	case <-ctx.Done():
		return "", ctx.Err()
	}
}

func (owner *databasePipeOwner) Validate(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := owner.send(map[string]string{"event": "validate"}); err != nil {
		return err
	}
	event, err := owner.next(ctx)
	if err != nil {
		return err
	}
	if event.Event != "validated" {
		return errors.New("INFOBASE_ACCESS_HOST_VALIDATION_UNCONFIRMED")
	}
	return nil
}

func (owner *databasePipeOwner) Close() error {
	owner.closeOnce.Do(func() {
		close(owner.abandoned)
		_ = owner.input.Close()
	})
	select {
	case <-owner.done:
		return nil
	case <-time.After(5 * time.Second):
		// Exact child process handle; never a name/PID scan or a 1C stop.
		_ = owner.command.Process.Kill()
	}
	select {
	case <-owner.done:
		return errors.New("INFOBASE_ACCESS_HOST_EXIT_TIMEOUT")
	case <-time.After(5 * time.Second):
		return errors.New("INFOBASE_ACCESS_HOST_EXIT_UNCONFIRMED")
	}
}
