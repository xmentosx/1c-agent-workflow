package main

import (
	"context"
	"encoding/json"
	"os"
	"time"
)

type desktopConsentPause struct {
	TotalPausedMs int64     `json:"totalPausedMs"`
	StartedUTC    time.Time `json:"startedUtc"`
	UntilUTC      time.Time `json:"untilUtc"`
}

func readDesktopConsentPause(path string) (desktopConsentPause, bool) {
	var pause desktopConsentPause
	data, err := os.ReadFile(path)
	if err != nil || json.Unmarshal(data, &pause) != nil || pause.TotalPausedMs < 0 {
		return desktopConsentPause{}, false
	}
	return pause, true
}

func (p desktopConsentPause) elapsed(now time.Time) time.Duration {
	elapsed := time.Duration(p.TotalPausedMs) * time.Millisecond
	pauseLength := p.UntilUTC.Sub(p.StartedUTC)
	if p.StartedUTC.IsZero() || pauseLength <= 0 || pauseLength > 3*time.Hour {
		return elapsed
	}
	return elapsed + min(pauseLength, max(0, now.Sub(p.StartedUTC)))
}

// The helper's group snapshot counts only time spent on an explicit user pause.
// An incoming cancellation and a caller's explicit phase deadline keep their
// normal authority, and the clock never replays a dispatched request.
func withDesktopConsentClock(phase, caller context.Context, path string) (context.Context, context.CancelFunc) {
	deadline, ok := phase.Deadline()
	if !ok || phase.Err() != nil {
		return phase, func() {}
	}
	started := time.Now()
	snapshot, _ := readDesktopConsentPause(path)
	baseline := snapshot.elapsed(started)
	ctx, cancel := context.WithCancelCause(context.WithoutCancel(phase))
	cancelOnCaller := context.AfterFunc(caller, func() { cancel(context.Cause(caller)) })
	if caller.Err() != nil {
		cancel(context.Cause(caller))
	}
	go func() {
		timer := time.NewTimer(time.Until(deadline))
		defer timer.Stop()
		var credited time.Duration
		for {
			select {
			case <-ctx.Done():
				return
			case now := <-timer.C:
				if latest, ok := readDesktopConsentPause(path); ok {
					snapshot = latest
				}
				credited = max(credited, snapshot.elapsed(now)-baseline)
				remaining := deadline.Add(credited).Sub(now)
				if remaining <= 0 {
					cancel(context.DeadlineExceeded)
					return
				}
				if now.Before(snapshot.UntilUTC) && !now.Before(snapshot.StartedUTC) {
					// A pause that starts just before the deadline must not busy-poll the file.
					remaining = max(remaining, 250*time.Millisecond)
				}
				timer.Reset(remaining)
			}
		}
	}()
	return ctx, func() {
		cancelOnCaller()
		cancel(context.Canceled)
	}
}
