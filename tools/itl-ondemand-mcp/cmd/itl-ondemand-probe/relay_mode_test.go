package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// Release qualifies the pinned relay: in -relay mode every probe session starts
// the relay, which serves the facade named by a probe-only launch descriptor.
func TestFacadeCommandRunsThroughTheRelay(t *testing.T) {
	root := filepath.Join(t.TempDir(), "проект с пробелом")
	facade := filepath.Join(t.TempDir(), "фасад", "itl-ondemand-mcp.exe")
	if err := os.MkdirAll(filepath.Dir(facade), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(facade, []byte("facade bytes"), 0o755); err != nil {
		t.Fatal(err)
	}
	relayExe = filepath.Join(t.TempDir(), "itl-ondemand-relay.exe")
	t.Cleanup(func() { relayExe = "" })

	command := facadeCommand(facade, "vanessa-ui", root, "catalog.json", "agent-1c.ps1", time.Minute)
	want := []string{relayExe, "--project-root", root, "--server", "itl-probe-vanessa-ui"}
	if fmt.Sprint(command.Args) != fmt.Sprint(want) {
		t.Fatalf("relay command = %q, want %q", command.Args, want)
	}
	path := filepath.Join(root, ".agent-1c", "mcp", "ondemand", "launch", "itl-probe-vanessa-ui.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var descriptor struct {
		SchemaVersion int      `json:"schemaVersion"`
		Family        string   `json:"family"`
		FacadePath    string   `json:"facadePath"`
		FacadeSha256  string   `json:"facadeSha256"`
		Args          []string `json:"args"`
	}
	if err := json.Unmarshal(raw, &descriptor); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte("facade bytes"))
	if descriptor.SchemaVersion != 1 || descriptor.Family != "vanessa-ui" || descriptor.FacadePath != facade || descriptor.FacadeSha256 != fmt.Sprintf("%x", sum[:]) {
		t.Fatalf("descriptor does not name the facade: %+v", descriptor)
	}
	if len(descriptor.Args) < 4 || descriptor.Args[0] != "serve" || descriptor.Args[4] != root {
		t.Fatalf("descriptor lost the facade arguments: %q", descriptor.Args)
	}
	// A second instance writes the identical descriptor without changing it.
	before, _ := os.Stat(path)
	facadeCommand(facade, "vanessa-ui", root, "catalog.json", "agent-1c.ps1", time.Minute)
	if after, _ := os.Stat(path); !after.ModTime().Equal(before.ModTime()) {
		t.Fatal("an identical descriptor was rewritten")
	}

	relayExe = ""
	if direct := facadeCommand(facade, "roctup", root, "catalog.json", "agent-1c.ps1", time.Minute); direct.Args[0] != facade || direct.Args[1] != "serve" {
		t.Fatalf("without -relay the probe must start the facade: %q", direct.Args)
	}
}
