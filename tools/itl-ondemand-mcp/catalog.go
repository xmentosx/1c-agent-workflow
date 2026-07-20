package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"sort"

	"github.com/google/jsonschema-go/jsonschema"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type catalogFile struct {
	SchemaVersion   int         `json:"schemaVersion"`
	Family          string      `json:"family"`
	BackendVersions any         `json:"backendVersions"`
	Tools           []*mcp.Tool `json:"tools"`
}

type loadedCatalog struct {
	Path       string
	SHA256     string
	Data       catalogFile
	tools      map[string]*mcp.Tool
	validators map[string]*jsonschema.Resolved
}

func loadCatalog(path, family string) (*loadedCatalog, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read catalog: %w", err)
	}
	raw = bytes.TrimPrefix(raw, []byte{0xef, 0xbb, 0xbf})
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
	tools := make(map[string]*mcp.Tool, len(data.Tools))
	validators := make(map[string]*jsonschema.Resolved, len(data.Tools))
	for _, tool := range data.Tools {
		if tool == nil || tool.Name == "" || tool.InputSchema == nil {
			return nil, fmt.Errorf("catalog contains an invalid tool")
		}
		if seen[tool.Name] {
			return nil, fmt.Errorf("catalog contains duplicate tool %q", tool.Name)
		}
		seen[tool.Name] = true
		tools[tool.Name] = tool
		validator, err := resolveInputSchema(tool.InputSchema)
		if err != nil {
			return nil, fmt.Errorf("catalog tool %q has an invalid input schema: %w", tool.Name, err)
		}
		validators[tool.Name] = validator
	}
	if len(data.Tools) == 0 {
		return nil, fmt.Errorf("catalog contains no tools")
	}
	hash := sha256.Sum256(canonicalCatalogBytes(raw))
	return &loadedCatalog{Path: path, SHA256: hex.EncodeToString(hash[:]), Data: data, tools: tools, validators: validators}, nil
}

func resolveInputSchema(value any) (*jsonschema.Resolved, error) {
	raw, err := json.Marshal(value)
	if err != nil {
		return nil, err
	}
	var schema jsonschema.Schema
	if err := json.Unmarshal(raw, &schema); err != nil {
		return nil, err
	}
	return schema.Resolve(nil)
}

func (c *loadedCatalog) tool(name string) *mcp.Tool {
	if c == nil {
		return nil
	}
	if c.tools == nil {
		c.tools = make(map[string]*mcp.Tool, len(c.Data.Tools))
		for _, tool := range c.Data.Tools {
			if tool != nil {
				c.tools[tool.Name] = tool
			}
		}
	}
	return c.tools[name]
}

func (c *loadedCatalog) validate(name string, arguments any) error {
	if c.tool(name) == nil {
		return fmt.Errorf("unknown catalog tool %q", name)
	}
	validator := c.validators[name]
	if validator == nil {
		var err error
		validator, err = resolveInputSchema(c.tools[name].InputSchema)
		if err != nil {
			return err
		}
		if c.validators == nil {
			c.validators = make(map[string]*jsonschema.Resolved)
		}
		c.validators[name] = validator
	}
	return validator.Validate(arguments)
}

func canonicalCatalogBytes(raw []byte) []byte {
	raw = bytes.TrimPrefix(raw, []byte{0xef, 0xbb, 0xbf})
	raw = bytes.ReplaceAll(raw, []byte("\r\n"), []byte("\n"))
	return bytes.ReplaceAll(raw, []byte("\r"), []byte("\n"))
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
