package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"sort"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type catalogFile struct {
	SchemaVersion   int         `json:"schemaVersion"`
	Family          string      `json:"family"`
	BackendVersions any         `json:"backendVersions"`
	Tools           []*mcp.Tool `json:"tools"`
}

type loadedCatalog struct {
	Path   string
	SHA256 string
	Data   catalogFile
}

func loadCatalog(path, family string) (*loadedCatalog, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read catalog: %w", err)
	}
	var data catalogFile
	if err := json.Unmarshal(raw, &data); err != nil {
		return nil, fmt.Errorf("decode catalog: %w", err)
	}
	if data.SchemaVersion != 1 {
		return nil, fmt.Errorf("unsupported catalog schemaVersion %d", data.SchemaVersion)
	}
	if data.Family != family {
		return nil, fmt.Errorf("catalog family %q does not match %q", data.Family, family)
	}
	seen := map[string]bool{}
	for _, tool := range data.Tools {
		if tool == nil || tool.Name == "" || tool.InputSchema == nil {
			return nil, fmt.Errorf("catalog contains an invalid tool")
		}
		if seen[tool.Name] {
			return nil, fmt.Errorf("catalog contains duplicate tool %q", tool.Name)
		}
		seen[tool.Name] = true
	}
	if len(data.Tools) == 0 {
		return nil, fmt.Errorf("catalog contains no tools")
	}
	hash := sha256.Sum256(raw)
	return &loadedCatalog{Path: path, SHA256: hex.EncodeToString(hash[:]), Data: data}, nil
}

type catalogDiff struct {
	Added   []string `json:"added,omitempty"`
	Removed []string `json:"removed,omitempty"`
	Changed []string `json:"changed,omitempty"`
}

func compareTools(expected, actual []*mcp.Tool) (*catalogDiff, error) {
	want := make(map[string]*mcp.Tool, len(expected))
	got := make(map[string]*mcp.Tool, len(actual))
	for _, tool := range expected {
		want[tool.Name] = tool
	}
	for _, tool := range actual {
		got[tool.Name] = tool
	}
	diff := &catalogDiff{}
	for name := range want {
		if got[name] == nil {
			diff.Removed = append(diff.Removed, name)
			continue
		}
		a, err := canonicalTool(want[name])
		if err != nil {
			return nil, err
		}
		b, err := canonicalTool(got[name])
		if err != nil {
			return nil, err
		}
		if string(a) != string(b) {
			diff.Changed = append(diff.Changed, name)
		}
	}
	for name := range got {
		if want[name] == nil {
			diff.Added = append(diff.Added, name)
		}
	}
	sort.Strings(diff.Added)
	sort.Strings(diff.Removed)
	sort.Strings(diff.Changed)
	return diff, nil
}

func canonicalTool(tool *mcp.Tool) ([]byte, error) {
	// Compare only the fields promised by the facade contract. JSON round-tripping
	// normalizes arbitrary schema maps and makes map key order deterministic.
	value := struct {
		Name         string               `json:"name"`
		Description  string               `json:"description,omitempty"`
		InputSchema  any                  `json:"inputSchema"`
		OutputSchema any                  `json:"outputSchema,omitempty"`
		Annotations  *mcp.ToolAnnotations `json:"annotations,omitempty"`
	}{tool.Name, tool.Description, tool.InputSchema, tool.OutputSchema, tool.Annotations}
	return json.Marshal(value)
}

func (d *catalogDiff) empty() bool {
	return len(d.Added) == 0 && len(d.Removed) == 0 && len(d.Changed) == 0
}
