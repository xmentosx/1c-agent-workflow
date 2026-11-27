package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestDesktopConsentClockKeepsRemainingTimeAndCallerCancellation(t *testing.T) {
	for _, cancelCaller := range []bool{false, true} {
		name := "resumed-budget-expires"
		if cancelCaller {
			name = "caller-cancels"
		}
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "pause.json")
			writePause := func(pause desktopConsentPause) {
				t.Helper()
				data, err := json.Marshal(pause)
				if err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(path, data, 0600); err != nil {
					t.Fatal(err)
				}
			}
			caller, abort := context.WithCancel(context.Background())
			defer abort()
			phase, endPhase := context.WithTimeout(caller, 160*time.Millisecond)
			defer endPhase()
			ctx, stop := withDesktopConsentClock(phase, caller, path)
			defer stop()
			start := time.Now()
			writePause(desktopConsentPause{StartedUTC: start, UntilUTC: start.Add(time.Minute)})

			<-phase.Done()
			if ctx.Err() != nil {
				t.Fatalf("explicit pause did not survive the original budget: %v", context.Cause(ctx))
			}
			want := context.Canceled
			if cancelCaller {
				abort()
			} else {
				writePause(desktopConsentPause{TotalPausedMs: time.Since(start).Milliseconds()})
				want = context.DeadlineExceeded
			}
			select {
			case <-ctx.Done():
				if !errors.Is(context.Cause(ctx), want) {
					t.Fatalf("cause = %v, want %v", context.Cause(ctx), want)
				}
			case <-time.After(3 * time.Second):
				t.Fatal("the paused budget was not canceled or restored")
			}
		})
	}
}

func TestDesktopConsentPauseCountsAtMostThreeHours(t *testing.T) {
	start := time.Now()
	pause := desktopConsentPause{TotalPausedMs: 10, StartedUTC: start, UntilUTC: start.Add(3 * time.Hour)}
	if got := pause.elapsed(start.Add(4 * time.Hour)); got != 3*time.Hour+10*time.Millisecond {
		t.Fatalf("expired pause elapsed = %s", got)
	}
	if got := pause.elapsed(start.Add(-time.Minute)); got != 10*time.Millisecond {
		t.Fatalf("future pause elapsed = %s", got)
	}
}
