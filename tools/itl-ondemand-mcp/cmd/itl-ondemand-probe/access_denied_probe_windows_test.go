//go:build windows

package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestCreateAccessDeniedProbeLocksAndRemovesFile(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "Путь с пробелами")
	if err := os.MkdirAll(directory, 0o755); err != nil {
		t.Fatal(err)
	}
	path, cleanup, err := createAccessDeniedProbe(directory)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.ReadFile(path); err == nil {
		t.Fatal("exclusive probe file remained readable")
	}
	if err := cleanup(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("exclusive probe file was not removed: %v", err)
	}
}
