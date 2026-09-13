package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// Production brokers always implement this boundary. Protocol-only fake
// brokers may omit it; integration fixtures implement it with the real host.
type databasePlanningBroker interface {
	DatabaseAccessPlan(context.Context) (*facadeDatabasePlan, error)
	DatabaseRuntimeRoot() string
}

const databaseProofMetaKey = "itlDatabaseAccess"

const finishDatabaseAccessTool = "finish_database_access"

func databaseParentProof(meta mcp.Meta) (*databaseAccessProof, error) {
	var raw []byte
	if value, ok := meta[databaseProofMetaKey]; ok {
		var err error
		raw, err = json.Marshal(value)
		if err != nil {
			return nil, fmt.Errorf("INFOBASE_ACCESS_INHERITED_PROOF_INVALID")
		}
	} else if value := os.Getenv("ITL_INFOBASE_ACCESS_LEASE"); value != "" {
		raw = []byte(value)
	} else {
		return nil, nil
	}
	var proof databaseAccessProof
	if json.Unmarshal(raw, &proof) != nil || proof.Coordinator == "" || len(proof.Ticket) != 32 || proof.Token == "" ||
		(proof.Purpose != "" && proof.Purpose != "operation") {
		return nil, fmt.Errorf("INFOBASE_ACCESS_INHERITED_PROOF_INVALID")
	}
	if proof.Purpose == "" {
		proof.Purpose = "operation"
	}
	mode, err := normalizeDatabaseAccessMode(proof.AccessMode)
	if err != nil {
		return nil, fmt.Errorf("INFOBASE_ACCESS_INHERITED_PROOF_INVALID")
	}
	proof.AccessMode = mode
	return &proof, nil
}

func publicBackendMeta(meta mcp.Meta) mcp.Meta {
	result := make(mcp.Meta, len(meta))
	for key, value := range meta {
		if key != databaseProofMetaKey {
			result[key] = value
		}
	}
	return result
}

func (r *runtime) lockDatabaseCalls(ctx context.Context) (func(), error) {
	if _, coordinated := r.broker.(databasePlanningBroker); !coordinated {
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

// Ordering: per-backend serialization -> global database admission -> local
// runtime read lock. A top-level facade retains the runtime read lock between
// calls until an explicit finish or terminal close proves cleanup.
func (r *runtime) beginDatabaseCall(ctx context.Context, meta mcp.Meta) (context.Context, func() error, error) {
	r.mu.Lock()
	finishing := r.databaseFinishing
	r.mu.Unlock()
	if finishing {
		return ctx, nil, fmt.Errorf("INFOBASE_ACCESS_FINISH_IN_PROGRESS")
	}
	unlock, err := r.lockDatabaseCalls(ctx)
	if err != nil {
		return ctx, nil, err
	}
	r.mu.Lock()
	finishing = r.databaseFinishing
	r.mu.Unlock()
	if finishing {
		unlock()
		return ctx, nil, fmt.Errorf("INFOBASE_ACCESS_FINISH_IN_PROGRESS")
	}
	planner, coordinated := r.broker.(databasePlanningBroker)
	if coordinated {
		parent, err := databaseParentProof(meta)
		if err != nil {
			unlock()
			return ctx, nil, err
		}
		if r.databaseRetainInherited && parent == nil {
			unlock()
			return ctx, nil, fmt.Errorf("INFOBASE_ACCESS_PROFILE_OUTER_OWNERSHIP_REQUIRED")
		}
		if r.databaseOwner == nil {
			plan, err := planner.DatabaseAccessPlan(ctx)
			if err != nil {
				unlock()
				return ctx, nil, err
			}
			identity := r.databaseOwnerIdentity()
			if threadID, ok := meta["openai/threadId"].(string); ok && threadID != "" {
				identity["threadId"] = threadID
			}
			accessMode, err := normalizeDatabaseAccessMode(plan.AccessMode)
			if err != nil {
				unlock()
				return ctx, nil, err
			}
			plan.AccessMode = accessMode
			if parent != nil && r.family == "vanessa-ui" {
				// An inherited facade cannot upgrade the outer ticket. Preserve the
				// previous fail-closed contract: Vanessa preparation is admitted only
				// when its caller already owns an exclusive operation lease.
				accessMode = "mutation-exclusive"
			}
			owner, err := acquireDatabasePipeOwner(ctx, plan.Python, planner.DatabaseRuntimeRoot(), databaseAccessRequest{
				SchemaVersion: 1, Coordinator: plan.Coordinator, Bases: plan.Bases, Timeout: plan.WaitTimeoutSeconds,
				Owner: identity, Inherited: parent, AccessMode: accessMode,
			}, func(event databaseAccessEvent) {
				r.logger.Info("waiting for database access", "status", event.Status, "resources", event.Resources, "blockers", event.Blockers)
			})
			if err != nil {
				unlock()
				return ctx, nil, err
			}
			r.databaseOwner, r.databasePlan, r.databaseParent = owner, plan, parent
			r.databaseNativePending = plan.RuntimePresent
		} else {
			if !sameDatabaseParent(r.databaseParent, parent) {
				unlock()
				return ctx, nil, fmt.Errorf("INFOBASE_ACCESS_BACKEND_OWNER_CHANGED")
			}
			if err := r.databaseOwner.Validate(ctx); err != nil {
				unlock()
				return ctx, nil, err
			}
			fresh, err := planner.DatabaseAccessPlan(withDatabaseInvocation(ctx, r.databaseOwner.Proof, r.databasePlan))
			if err != nil {
				unlock()
				return ctx, nil, err
			}
			if !sameDatabasePlan(r.databasePlan, fresh) {
				unlock()
				return ctx, nil, fmt.Errorf("ITL_ONDEMAND_DATABASE_PLAN_CHANGED: cached backend target or manager inputs changed")
			}
		}
		ctx = withDatabaseInvocation(ctx, r.databaseOwner.Proof, r.databasePlan)
	}
	retainPhase := coordinated && (r.databaseParent == nil || r.databaseRetainInherited)
	var callLock *runtimeReadLock
	if retainPhase {
		err = r.ensureDatabasePhaseLock()
	} else {
		callLock, err = acquireRuntimeReadLock(filepath.Join(r.projectRoot, ".agent-1c", "locks", "runtime-mcp.lock"))
	}
	if err != nil {
		if coordinated && !r.databaseNativePending {
			cleanupCtx, cancel := context.WithTimeout(context.Background(), time.Minute)
			defer cancel()
			if releaseErr := r.releaseDatabaseOwner(cleanupCtx); releaseErr != nil {
				err = fmt.Errorf("%v; database release: %w", err, releaseErr)
			}
		}
		unlock()
		return ctx, nil, fmt.Errorf("ITL_ONDEMAND_RUNTIME_LOCK: %w", err)
	}
	return ctx, func() error {
		defer unlock()
		if callLock != nil {
			defer callLock.Close()
		}
		if !coordinated {
			return nil
		}
		r.mu.Lock()
		defer r.mu.Unlock()
		if (r.databaseParent != nil && !r.databaseRetainInherited) || r.session == nil {
			cleanupCtx, cancel := context.WithTimeout(context.Background(), time.Minute)
			defer cancel()
			if err := r.stopDatabaseBackendLocked(cleanupCtx, true); err != nil {
				return err
			}
			if retainPhase {
				return r.releaseDatabasePhaseLocked()
			}
		}
		return nil
	}, nil
}

func (r *runtime) databaseOwnerIdentity() map[string]any {
	return map[string]any{
		"project": r.projectRoot, "operation": "ondemand-" + r.family, "requestId": r.instanceID,
		"lifecycle": "on-demand", "releaseAction": databaseReleaseAction(r.family, r.instanceID),
	}
}

// Called without r.mu. The database gate serializes production admissions;
// r.mu protects the retained handle from finish/close and test-only brokers.
func (r *runtime) ensureDatabasePhaseLock() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.databaseFinishing {
		return fmt.Errorf("INFOBASE_ACCESS_FINISH_IN_PROGRESS")
	}
	if r.databasePhaseLock != nil {
		return nil
	}
	lock, err := acquireRuntimeReadLock(filepath.Join(r.projectRoot, ".agent-1c", "locks", "runtime-mcp.lock"))
	if err != nil {
		return err
	}
	r.databasePhaseLock = lock
	return nil
}

// Called with r.mu held, after owned native/database cleanup was proven.
func (r *runtime) releaseDatabasePhaseLocked() error {
	if r.databasePhaseLock == nil {
		return nil
	}
	if err := r.databasePhaseLock.Close(); err != nil {
		return err
	}
	r.databasePhaseLock = nil
	return nil
}

func (r *runtime) finishDatabaseAccess(ctx context.Context) (bool, error) {
	r.databaseFinishMu.Lock()
	defer r.databaseFinishMu.Unlock()
	r.mu.Lock()
	alreadyReleased := r.databasePhaseLock == nil && r.databaseOwner == nil && r.backend == nil && r.session == nil && !r.databaseNativePending
	r.databaseFinishing = true
	r.mu.Unlock()
	if err := r.stop(ctx); err != nil {
		// Keep the facade fenced after an unproven finish. A repeated finish may
		// retry exact owned cleanup; ordinary database calls remain rejected.
		return false, err
	}
	r.mu.Lock()
	r.databaseFinishing = false
	r.mu.Unlock()
	return alreadyReleased, nil
}

func sameDatabaseParent(first, second *databaseAccessProof) bool {
	if first == nil || second == nil {
		return first == second
	}
	return first.Ticket == second.Ticket && first.Token == second.Token && first.Purpose == second.Purpose && first.AccessMode == second.AccessMode &&
		strings.EqualFold(filepath.Clean(first.Coordinator), filepath.Clean(second.Coordinator))
}

func sameDatabasePlan(first, second *facadeDatabasePlan) bool {
	if first == nil || second == nil || first.Family != second.Family ||
		!strings.EqualFold(filepath.Clean(first.ProjectRoot), filepath.Clean(second.ProjectRoot)) ||
		!strings.EqualFold(filepath.Clean(first.Coordinator), filepath.Clean(second.Coordinator)) ||
		first.AuxiliaryContour != second.AuxiliaryContour || first.AccessMode != second.AccessMode ||
		!sameDatabaseConnection(first.TargetBase, second.TargetBase) {
		return false
	}
	if (first.PrimaryBase == nil) != (second.PrimaryBase == nil) ||
		(first.PrimaryBase != nil && !sameDatabaseConnection(*first.PrimaryBase, *second.PrimaryBase)) {
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
		} else {
			if json.Unmarshal(raw, &after) != nil {
				return false
			}
		}
	}
	if before == nil || after == nil {
		return before == after
	}
	return before.Generation == after.Generation && before.Template == after.Template &&
		sameDatabaseConnection(databaseConnection{Kind: before.Kind, Path: before.Path}, databaseConnection{Kind: after.Kind, Path: after.Path})
}

func sameDatabaseConnection(first, second databaseConnection) bool {
	return first.Kind == second.Kind && strings.EqualFold(strings.TrimRight(first.Path, "\\/"), strings.TrimRight(second.Path, "\\/"))
}

func (r *runtime) transitionDatabaseMode(ctx context.Context, accessMode string) error {
	if r.databaseOwner == nil || r.databasePlan == nil || r.databaseOwner.AccessMode == accessMode {
		return nil
	}
	if r.databaseParent != nil {
		if accessMode == "mutation-exclusive" && r.databaseOwner.AccessMode != "mutation-exclusive" {
			return fmt.Errorf("INFOBASE_ACCESS_INHERITED_MODE_INSUFFICIENT")
		}
		return nil
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	timeout := r.databasePlan.WaitTimeoutSeconds
	if deadline, ok := ctx.Deadline(); ok {
		remaining := time.Until(deadline).Seconds()
		if remaining <= 0 {
			return context.DeadlineExceeded
		}
		if timeout > 0 && remaining < timeout {
			timeout = remaining
		}
	}
	err := r.databaseOwner.Transition(ctx, accessMode, timeout, func(event databaseAccessEvent) {
		r.logger.Info("waiting for database access mode", "status", event.Status, "accessMode", accessMode,
			"resources", event.Resources, "blockers", event.Blockers)
	})
	if err != nil {
		return fmt.Errorf("INFOBASE_ACCESS_MODE_TRANSITION_FAILED: %w", err)
	}
	return nil
}

func (r *runtime) enterDatabasePreparationMode(ctx context.Context) error {
	if r.family != "vanessa-ui" {
		return nil
	}
	return r.transitionDatabaseMode(ctx, "mutation-exclusive")
}

func (r *runtime) restoreDatabaseRuntimeMode(ctx context.Context) error {
	if r.databasePlan == nil {
		return nil
	}
	return r.transitionDatabaseMode(ctx, r.databasePlan.AccessMode)
}

// Called under the database gate and r.mu, with the runtime read lock held.
func (r *runtime) stopDatabaseBackendLocked(ctx context.Context, releaseOwner bool) error {
	if r.databaseOwner != nil {
		if err := r.databaseOwner.Validate(ctx); err != nil {
			return err
		}
		ctx = withDatabaseInvocation(ctx, r.databaseOwner.Proof, r.databasePlan)
	}
	if r.backend != nil || r.databaseNativePending {
		if err := r.broker.Stop(ctx); err != nil {
			return err
		}
		r.databaseNativePending = false
	}
	if r.session != nil {
		_ = r.session.Close()
		r.clearProgress(r.session)
		r.session = nil
	}
	r.backend = nil
	if r.timer != nil {
		r.timer.Stop()
		r.timer = nil
	}
	if releaseOwner {
		return r.releaseDatabaseOwner(ctx)
	}
	return nil
}

func (r *runtime) releaseDatabaseOwner(ctx context.Context) error {
	if r.databaseOwner == nil {
		return nil
	}
	if r.databaseNativePending {
		return fmt.Errorf("INFOBASE_ACCESS_NATIVE_CLEANUP_UNCONFIRMED")
	}
	status, err := r.databaseOwner.Release(ctx, nil)
	if err != nil {
		return err
	}
	if status != "released" {
		return fmt.Errorf("INFOBASE_ACCESS_RELEASE_UNCONFIRMED")
	}
	r.databaseOwner, r.databasePlan, r.databaseParent = nil, nil, nil
	return nil
}

// Startup failure cleanup retains the explicit proof while dropping an expired
// phase deadline. Its success is remembered so a missing state is not mistaken
// for either live work or an independently proven stop on the next attempt.
func (r *runtime) stopBrokerAfterFailure(ctx context.Context) {
	cleanup, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	if err := r.broker.Stop(preserveDatabaseInvocation(ctx, cleanup)); err == nil {
		r.databaseNativePending = false
		r.backend = nil
	}
}
