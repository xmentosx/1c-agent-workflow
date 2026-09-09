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
// runtime read lock. finish retains the read lock through inherited cleanup.
func (r *runtime) beginDatabaseCall(ctx context.Context, meta mcp.Meta) (context.Context, func() error, error) {
	unlock, err := r.lockDatabaseCalls(ctx)
	if err != nil {
		return ctx, nil, err
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
			identity := map[string]any{"project": r.projectRoot, "operation": "ondemand-" + r.family, "requestId": r.instanceID}
			if threadID, ok := meta["openai/threadId"].(string); ok && threadID != "" {
				identity["threadId"] = threadID
			}
			owner, err := acquireDatabasePipeOwner(ctx, plan.Python, planner.DatabaseRuntimeRoot(), databaseAccessRequest{
				SchemaVersion: 1, Coordinator: plan.Coordinator, Bases: plan.Bases, Timeout: plan.WaitTimeoutSeconds,
				Owner:     identity,
				Inherited: parent,
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
	lock, err := acquireRuntimeReadLock(filepath.Join(r.projectRoot, ".agent-1c", "locks", "runtime-mcp.lock"))
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
		defer lock.Close()
		if !coordinated {
			return nil
		}
		r.mu.Lock()
		defer r.mu.Unlock()
		if (r.databaseParent != nil && !r.databaseRetainInherited) || r.session == nil {
			cleanupCtx, cancel := context.WithTimeout(context.Background(), time.Minute)
			defer cancel()
			return r.stopDatabaseBackendLocked(cleanupCtx)
		}
		return nil
	}, nil
}

func sameDatabaseParent(first, second *databaseAccessProof) bool {
	if first == nil || second == nil {
		return first == second
	}
	return first.Ticket == second.Ticket && first.Token == second.Token && first.Purpose == second.Purpose &&
		strings.EqualFold(filepath.Clean(first.Coordinator), filepath.Clean(second.Coordinator))
}

func sameDatabasePlan(first, second *facadeDatabasePlan) bool {
	if first == nil || second == nil || first.Family != second.Family ||
		!strings.EqualFold(filepath.Clean(first.ProjectRoot), filepath.Clean(second.ProjectRoot)) ||
		!strings.EqualFold(filepath.Clean(first.Coordinator), filepath.Clean(second.Coordinator)) ||
		first.AuxiliaryContour != second.AuxiliaryContour || !sameDatabaseConnection(first.TargetBase, second.TargetBase) {
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

// Called under the database gate and r.mu, with the runtime read lock held.
func (r *runtime) stopDatabaseBackendLocked(ctx context.Context) error {
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
	return r.releaseDatabaseOwner(ctx)
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
