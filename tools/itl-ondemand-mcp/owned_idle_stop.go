package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync/atomic"
)

var errIdleChildActive = errors.New("ITL_ONDEMAND_IDLE_CHILD_ACTIVE")

// Retiring only the local transport prevents the SDK's Close HTTP DELETE from
// reaching a replacement listener after native cleanup releases its port.
// The SDK then cancels and joins its own receive loop before native cleanup.
type backendHTTPTransport struct{ retired atomic.Bool }

func (t *backendHTTPTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	if t.retired.Load() {
		return nil, context.Canceled
	}
	return http.DefaultTransport.RoundTrip(req)
}

type privateRuntimeBroker interface {
	PrivateRuntime() bool
	StopOwnedIdle(context.Context, *backendInfo) error
}

type testClientCloseBroker interface {
	CompleteTestClientClose(context.Context, *backendInfo) error
}

type ownedIdleInvocationKey struct{}
type ownedIdleInvocation struct {
	SchemaVersion int          `json:"schemaVersion"`
	Kind          string       `json:"kind"`
	ProjectRoot   string       `json:"projectRoot"`
	Family        string       `json:"family"`
	InstanceID    string       `json:"instanceId"`
	CatalogSHA256 string       `json:"catalogSha256"`
	Expected      *backendInfo `json:"expectedBackend"`
}

func (b *powershellBroker) PrivateRuntime() bool { return b.privateRuntime }

func (b *powershellBroker) StopOwnedIdle(ctx context.Context, expected *backendInfo) error {
	if !b.privateRuntime || expected == nil || b.recoveryCandidate != "" {
		return errIdleChildActive
	}
	ctx = context.WithValue(ctx, ownedIdleInvocationKey{}, &ownedIdleInvocation{
		SchemaVersion: 3, Kind: "owned-idle-stop", ProjectRoot: b.ProjectRoot,
		Family: b.Family, InstanceID: b.InstanceID, CatalogSHA256: b.CatalogHash, Expected: expected,
	})
	info, err := b.invoke(ctx, "stop", nil)
	if err != nil {
		if strings.Contains(err.Error(), "ITL_ONDEMAND_IDLE_CHILD_ACTIVE:") ||
			strings.Contains(err.Error(), "ITL_ONDEMAND_STOP_UNCONFIRMED:") {
			// A lifecycle drain may have already removed the registration and
			// leases. This is not a cleanup receipt: continue through the existing
			// signed stop, which proves retained process/port/lease cleanup.
			return errIdleChildActive
		}
		return err
	}
	if info.Status != "stopped" {
		return fmt.Errorf("ITL_ONDEMAND_STOP_UNCONFIRMED")
	}
	b.cleanupConfirmed, b.lastBackend = true, nil
	return nil
}

func (b *powershellBroker) CompleteTestClientClose(ctx context.Context, expected *backendInfo) error {
	invocation, ok := ctx.Value(executionInvocationKey{}).(*executionInvocation)
	if !ok || expected == nil {
		return fmt.Errorf("ITL_ONDEMAND_EXECUTION_CONTEXT_REQUIRED")
	}
	copy := *invocation
	copy.ExpectedBackend = expected
	ctx = context.WithValue(ctx, executionInvocationKey{}, &copy)
	info, err := b.invoke(ctx, "complete-test-client-close", []string{
		"-InternalOnDemandExpectedPid", fmt.Sprint(expected.PID),
		"-InternalOnDemandExpectedPort", fmt.Sprint(expected.Port),
	})
	if err != nil {
		return err
	}
	if info.Status != "test-client-closed" {
		return fmt.Errorf("ITL_VANESSA_TESTCLIENT_CLOSE_UNCONFIRMED")
	}
	return nil
}

// Eligibility concerns this private foreground runtime, not database-wide
// background jobs. Persistent/manual/unknown activity never becomes idle just
// because a later read returned successfully.
func (r *runtime) noteIdleActivityLocked(name string, arguments any) {
	args, _ := arguments.(map[string]any)
	if r.family == "roctup" {
		switch name {
		case "get_metadata", "execute_query", "find_references_to_object", "get_access_rights", "get_bsl_syntax_help", "get_event_log", "get_link_of_object", "get_object_by_link":
		default:
			r.idleActivityUnresolved = true
		}
	} else if name == "stop_scenario" || name == "user_actions_recording" || (name == "manage_breakpoints" && args["action"] != "get") {
		r.idleActivityUnresolved = true
	}
}

func (r *runtime) tryOwnedIdleStopLocked(ctx context.Context) (bool, error) {
	broker, ok := r.broker.(privateRuntimeBroker)
	if !ok || !broker.PrivateRuntime() || r.idleActivityUnresolved || r.active != 0 || r.executionOwner != nil || r.cleanupUnconfirmed {
		return false, nil
	}
	if r.backend == nil {
		return true, nil
	}
	if r.session != nil {
		if r.sessionTransport != nil {
			r.sessionTransport.retired.Store(true)
		}
		_ = r.session.Close()
		r.clearProgress(r.session)
		r.session = nil
	}
	if err := broker.StopOwnedIdle(ctx, r.backend); err != nil {
		if errors.Is(err, errIdleChildActive) {
			return false, nil
		}
		r.cleanupUnconfirmed = true
		return true, err
	}
	r.backend = nil
	if r.timer != nil {
		r.timer.Stop()
		r.timer = nil
	}
	return true, nil
}

func ownedIdleEnvironment(ctx context.Context) (string, error) {
	value, ok := ctx.Value(ownedIdleInvocationKey{}).(*ownedIdleInvocation)
	if !ok {
		return "", nil
	}
	if _, signed := ctx.Value(executionInvocationKey{}).(*executionInvocation); signed {
		return "", fmt.Errorf("ITL_ONDEMAND_EXECUTION_CONTEXT_INVALID")
	}
	raw, err := json.Marshal(value)
	return string(raw), err
}
