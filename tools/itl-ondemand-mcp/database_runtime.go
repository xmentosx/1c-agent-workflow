package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The name remains local to the facade while the wire contract is execution
// scoped. A protocol-only fake broker may omit planning entirely.
type executionPlanningBroker interface {
	ExecutionPlan(context.Context) (*facadeExecutionPlan, error)
	ExecutionRuntimeRoot() string
}

const executionContextMetaKey = "itlExecutionContext"
const executionContextKeyMetaKey = "itlExecutionContextKey"

func executionParentContext(meta mcp.Meta) (*executionContextProof, error) {
	encoded, _ := meta[executionContextMetaKey].(string)
	key, _ := meta[executionContextKeyMetaKey].(string)
	if encoded == "" {
		encoded = os.Getenv("ITL_EXECUTION_CONTEXT")
		key = os.Getenv("ITL_EXECUTION_CONTEXT_KEY")
	}
	if encoded == "" && key == "" {
		return nil, nil
	}
	if encoded == "" || key == "" {
		return nil, fmt.Errorf("EXECUTION_CONTEXT_INVALID")
	}
	return &executionContextProof{Encoded: encoded, Key: key}, nil
}

func publicBackendMeta(meta mcp.Meta) mcp.Meta {
	result := make(mcp.Meta, len(meta))
	for key, value := range meta {
		if key != executionContextMetaKey && key != executionContextKeyMetaKey {
			result[key] = value
		}
	}
	return result
}

func (r *runtime) lockDatabaseCalls(ctx context.Context) (func(), error) {
	if _, coordinated := r.broker.(executionPlanningBroker); !coordinated {
		return func() {}, nil
	}
	r.databaseGateOnce.Do(func() { r.databaseGate = make(chan struct{}, 1) })
	select {
	case r.databaseGate <- struct{}{}:
		if err := ctx.Err(); err != nil {
			<-r.databaseGate
			return nil, err
		}
		return func() { <-r.databaseGate }, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

// One MCP tool call is one database execution. Backend lifetime is independent:
// an idle warmed backend never retains this guard between calls. Unconfirmed
// native cleanup remains part of the original execution until owned stop.
func (r *runtime) beginDatabaseCall(ctx context.Context, meta mcp.Meta) (context.Context, func(string, string) error, error) {
	return r.beginDatabaseExecution(ctx, meta, false)
}

// Only the existing owned-stop path may continue an execution whose native
// cleanup is unconfirmed. A new tool call never inherits that pending owner.
func (r *runtime) beginDatabaseExecution(ctx context.Context, meta mcp.Meta, ownedCleanup bool) (context.Context, func(string, string) error, error) {
	unlock, err := r.lockDatabaseCalls(ctx)
	if err != nil {
		return ctx, nil, err
	}
	return r.beginDatabaseExecutionWithLocalGate(ctx, meta, ownedCleanup, unlock)
}

// The caller already owns the local gate. Native stop may first establish that
// a private runtime is idle without waiting for unrelated database execution.
func (r *runtime) beginDatabaseExecutionWithLocalGate(ctx context.Context, meta mcp.Meta, ownedCleanup bool, unlock func()) (context.Context, func(string, string) error, error) {
	planner, coordinated := r.broker.(executionPlanningBroker)
	if !coordinated {
		return ctx, func(string, string) error { unlock(); return nil }, nil
	}
	r.mu.Lock()
	retainedOwner, retainedPlan, pending := r.executionOwner, r.executionPlan, r.cleanupUnconfirmed
	r.mu.Unlock()
	if pending && !ownedCleanup {
		// Finish only our previous native execution before admitting a new tool.
		// Keep the local gate across both phases; the old signed context is used
		// for cleanup only and never for dispatching the next operation.
		cleanupCtx, cancel := context.WithTimeout(ctx, time.Minute)
		defer cancel()
		cleanupCtx, finish, err := r.beginDatabaseExecutionWithLocalGate(cleanupCtx, meta, true, func() {})
		if err != nil {
			unlock()
			return ctx, nil, err
		}
		r.mu.Lock()
		stopErr := r.stopDatabaseBackendLocked(cleanupCtx, true)
		r.mu.Unlock()
		terminal, message := "succeeded", ""
		if stopErr != nil {
			terminal, message = "failed", stopErr.Error()
		}
		if err := errors.Join(stopErr, finish(terminal, message)); err != nil {
			unlock()
			return ctx, nil, fmt.Errorf("EXECUTION_GUARD_OWNED_CALL_CLEANUP_UNCONFIRMED: %w", err)
		}
		retainedOwner, retainedPlan = nil, nil
	}
	if retainedOwner != nil {
		if !ownedCleanup || !pending || retainedPlan == nil {
			unlock()
			return ctx, nil, fmt.Errorf("EXECUTION_GUARD_OWNED_CALL_CLEANUP_UNCONFIRMED: original execution still owns the infobase; call %s through this facade, preserve the unknown result, then retry only after owned cleanup is proven", ownerRecoveryTool)
		}
		ctx = withExecutionInvocation(ctx, retainedOwner.Proof, retainedPlan)
		return ctx, r.finishDatabaseExecution(retainedOwner, unlock), nil
	}
	plan, err := planner.ExecutionPlan(ctx)
	if err != nil {
		unlock()
		return ctx, nil, err
	}
	parent, err := executionParentContext(meta)
	if err != nil {
		unlock()
		return ctx, nil, err
	}
	executionID, err := newExecutionID()
	if err != nil {
		unlock()
		return ctx, nil, err
	}
	request := executionGuardRequest{SchemaVersion: 1, Root: plan.GuardRoot, Bases: plan.Bases,
		Operation: "ondemand-" + r.family + "-call", ExecutionID: executionID,
		Timeout: plan.WaitTimeoutSeconds}
	if parent != nil {
		request.InheritedContext, request.InheritedContextKey = parent.Encoded, parent.Key
	}
	owner, err := acquireExecutionGuard(ctx, plan.Python, planner.ExecutionRuntimeRoot(), request, func(event executionGuardEvent) {
		r.logger.Info("waiting for database execution", "status", event.Status,
			"resources", event.Resources, "waitSeconds", event.WaitSeconds)
	})
	if err != nil {
		unlock()
		return ctx, nil, err
	}
	ctx = withExecutionInvocation(ctx, owner.Proof, plan)
	fresh, err := planner.ExecutionPlan(ctx)
	if err != nil || !sameExecutionPlan(plan, fresh) {
		cleanupCtx, cancel := context.WithTimeout(context.Background(), time.Minute)
		defer cancel()
		releaseErr := owner.Release(cleanupCtx, "failed", "ITL_ONDEMAND_EXECUTION_PLAN_CHANGED")
		unlock()
		if err != nil {
			return ctx, nil, errors.Join(fmt.Errorf("ITL_ONDEMAND_EXECUTION_PLAN_REVALIDATION_FAILED: %w", err), releaseErr)
		}
		if releaseErr != nil {
			return ctx, nil, releaseErr
		}
		return ctx, nil, fmt.Errorf("ITL_ONDEMAND_EXECUTION_PLAN_CHANGED")
	}
	r.mu.Lock()
	r.executionOwner, r.executionPlan = owner, plan
	r.mu.Unlock()
	return ctx, r.finishDatabaseExecution(owner, unlock), nil
}

func (r *runtime) finishDatabaseExecution(owner *executionGuardOwner, unlock func()) func(string, string) error {
	return func(result, message string) error {
		defer unlock()
		r.mu.Lock()
		pending := r.cleanupUnconfirmed
		r.mu.Unlock()
		if pending {
			return fmt.Errorf("EXECUTION_GUARD_OWNED_CALL_CLEANUP_UNCONFIRMED: original resource owner retained; call %s through this facade before another tool call; no uncertain call was replayed", ownerRecoveryTool)
		}
		cleanupCtx, cancel := context.WithTimeout(context.Background(), time.Minute)
		defer cancel()
		if result == "" {
			result = "succeeded"
		}
		err := owner.Release(cleanupCtx, result, message)
		r.mu.Lock()
		if r.executionOwner == owner {
			r.executionOwner, r.executionPlan = nil, nil
		}
		r.mu.Unlock()
		return err
	}
}

func sameExecutionPlan(first, second *facadeExecutionPlan) bool {
	if first == nil || second == nil || first.Family != second.Family || first.ExecutionHost != second.ExecutionHost ||
		!strings.EqualFold(filepath.Clean(first.ProjectRoot), filepath.Clean(second.ProjectRoot)) ||
		!strings.EqualFold(filepath.Clean(first.GuardRoot), filepath.Clean(second.GuardRoot)) ||
		first.AuxiliaryContour != second.AuxiliaryContour ||
		!sameDatabaseConnection(first.TargetBase, second.TargetBase) {
		return false
	}
	if (first.PrimaryBase == nil) != (second.PrimaryBase == nil) ||
		(first.PrimaryBase != nil && !sameDatabaseConnection(*first.PrimaryBase, *second.PrimaryBase)) ||
		len(first.Bases) != len(second.Bases) {
		return false
	}
	for _, connection := range second.Bases {
		found := false
		for _, reserved := range first.Bases {
			if sameDatabaseConnection(connection, reserved) {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	type managerIdentity struct {
		Kind       string `json:"kind"`
		Path       string `json:"path"`
		Generation string `json:"generation"`
		Template   struct {
			SHA256 string `json:"sha256"`
			User   string `json:"user"`
		} `json:"template"`
	}
	var before, after *managerIdentity
	for i, raw := range []json.RawMessage{first.ServicePlan, second.ServicePlan} {
		if len(raw) == 0 {
			continue
		}
		if i == 0 {
			if json.Unmarshal(raw, &before) != nil {
				return false
			}
		} else if json.Unmarshal(raw, &after) != nil {
			return false
		}
	}
	if before == nil || after == nil {
		return before == after
	}
	return before.Generation == after.Generation && before.Template == after.Template &&
		sameDatabaseConnection(databaseConnection{Kind: before.Kind, Path: before.Path},
			databaseConnection{Kind: after.Kind, Path: after.Path})
}

func sameDatabaseConnection(first, second databaseConnection) bool {
	return first.Kind == second.Kind && strings.EqualFold(strings.TrimRight(first.Path, "\\/"), strings.TrimRight(second.Path, "\\/"))
}

// Exclusive v2 guards have no access-mode transitions. Preparation and normal
// calls share the same outer execution until the atomic result is complete.
func (r *runtime) enterDatabasePreparationMode(context.Context) error { return nil }
func (r *runtime) restoreDatabaseRuntimeMode(context.Context) error   { return nil }

// Called under the per-runtime gate and r.mu. Guard release belongs to the
// outer call, never to backend idle cleanup.
func (r *runtime) stopDatabaseBackendLocked(ctx context.Context, _ bool) error {
	if r.backend != nil || r.cleanupUnconfirmed {
		if err := r.broker.Stop(ctx); err != nil {
			r.cleanupUnconfirmed = true
			return err
		}
	}
	if r.session != nil {
		_ = r.session.Close()
		r.clearProgress(r.session)
		r.session = nil
	}
	r.backend = nil
	r.cleanupUnconfirmed = false
	if r.timer != nil {
		r.timer.Stop()
		r.timer = nil
	}
	return nil
}

func (r *runtime) stopBrokerAfterFailure(ctx context.Context) {
	cleanup, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	_ = r.stopDatabaseBackendLocked(preserveExecutionInvocation(ctx, cleanup), true)
}

// A transport error or deadline leaves the inner side effect uncertain. Stop
// the exact owned backend while the outer execution guard is still held; only
// then may the deferred guard release admit the next same-base call.
func (r *runtime) cleanupFailedDatabaseCallLocked(callContext context.Context, callError error) error {
	cleanup, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	cleanup = preserveExecutionInvocation(callContext, cleanup)
	if err := r.stopDatabaseBackendLocked(cleanup, true); err != nil {
		return errors.Join(callError, fmt.Errorf("EXECUTION_GUARD_OWNED_CALL_CLEANUP_UNCONFIRMED: %w", err))
	}
	return callError
}
