package main

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type phaseBudgetKey struct{}

// The execution host sends the remaining phase budget on each RPC. Remote
// clocks are not compared, and nested broker calls cannot restart this budget.
func phaseRequestContext(parent context.Context, meta mcp.Meta) (context.Context, context.CancelFunc, error) {
	budget := 10 * time.Minute
	if value, ok := meta["itlPhaseRemainingMs"]; ok {
		encoded, err := json.Marshal(value)
		var milliseconds float64
		if err != nil || json.Unmarshal(encoded, &milliseconds) != nil || math.IsNaN(milliseconds) ||
			math.IsInf(milliseconds, 0) || milliseconds <= 0 || milliseconds > 86400000 {
			return nil, nil, fmt.Errorf("invalid itlPhaseRemainingMs; expected a positive number up to 86400000")
		}
		budget = time.Duration(milliseconds * float64(time.Millisecond))
		parent = context.WithValue(parent, phaseBudgetKey{}, true)
	}
	ctx, cancel := context.WithTimeout(parent, budget)
	return ctx, cancel, nil
}

func brokerCallTimeout(ctx context.Context, configured time.Duration) time.Duration {
	if configured != 0 {
		return configured
	}
	if inherited, _ := ctx.Value(phaseBudgetKey{}).(bool); inherited {
		if deadline, ok := ctx.Deadline(); ok {
			return time.Until(deadline)
		}
	}
	return 5 * time.Minute
}
