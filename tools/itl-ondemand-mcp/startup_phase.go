package main

import (
	"context"
	"errors"
	"fmt"
	"time"
)

func remainingPhaseMilliseconds(ctx context.Context) int64 {
	if deadline, ok := ctx.Deadline(); ok {
		return max(0, time.Until(deadline).Milliseconds())
	}
	return -1
}

// One request owns all startup phases. Record the phase before failure cleanup
// consumes more time; diagnostics contain no connection arguments or tokens.
func (r *runtime) backendPhase(ctx context.Context, phase string) func(error) error {
	started, budget := time.Now(), remainingPhaseMilliseconds(ctx)
	r.logger.Info("ensure backend", "family", r.family, "instanceId", r.instanceID, "stage", phase)
	return func(err error) error {
		err = errors.Join(err, ctx.Err())
		elapsed, remaining := time.Since(started).Milliseconds(), remainingPhaseMilliseconds(ctx)
		r.logger.Info("backend phase completed", "stage", phase, "elapsedMs", elapsed, "budgetMs", budget, "remainingMs", remaining, "succeeded", err == nil)
		if err == nil {
			return nil
		}
		return fmt.Errorf("phase=%s elapsedMs=%d budgetMs=%d remainingMs=%d: %w", phase, elapsed, budget, remaining, err)
	}
}
