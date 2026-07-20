package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func TestLoadCatalogAndCompare(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "catalog.json")
	raw := `{"schemaVersion":1,"family":"roctup","backendVersions":{"roctup":"v1"},"tools":[{"name":"ping","description":"Ping","inputSchema":{"type":"object"}}]}`
	if err := os.WriteFile(path, []byte(raw), 0o600); err != nil {
		t.Fatal(err)
	}
	catalog, err := loadCatalog(path, "roctup")
	if err != nil {
		t.Fatal(err)
	}
	diff, err := compareTools(catalog.Data.Tools, []*mcp.Tool{{Name: "ping", Description: "Ping", InputSchema: map[string]any{"type": "object"}}})
	if err != nil || !diff.empty() {
		t.Fatalf("compareTools = %#v, %v", diff, err)
	}
	diff, err = compareTools(catalog.Data.Tools, []*mcp.Tool{{Name: "other", InputSchema: map[string]any{"type": "object"}}})
	if err != nil || len(diff.Added) != 1 || len(diff.Removed) != 1 {
		t.Fatalf("unexpected diff: %#v, %v", diff, err)
	}
}

func TestLoadCatalogHashIgnoresLineEndingsAndBOM(t *testing.T) {
	dir := t.TempDir()
	lfPath := filepath.Join(dir, "lf.json")
	crlfPath := filepath.Join(dir, "crlf.json")
	raw := "{\n\"schemaVersion\":1,\n\"family\":\"roctup\",\n\"backendVersions\":{\"roctup\":\"v1\"},\n\"tools\":[{\"name\":\"ping\",\"inputSchema\":{\"type\":\"object\"}}]\n}\n"
	if err := os.WriteFile(lfPath, []byte(raw), 0o600); err != nil {
		t.Fatal(err)
	}
	crlf := append([]byte{0xef, 0xbb, 0xbf}, []byte(strings.ReplaceAll(raw, "\n", "\r\n"))...)
	if err := os.WriteFile(crlfPath, crlf, 0o600); err != nil {
		t.Fatal(err)
	}
	lf, err := loadCatalog(lfPath, "roctup")
	if err != nil {
		t.Fatal(err)
	}
	windows, err := loadCatalog(crlfPath, "roctup")
	if err != nil {
		t.Fatal(err)
	}
	if lf.SHA256 != windows.SHA256 {
		t.Fatalf("catalog hashes differ: lf=%s crlf=%s", lf.SHA256, windows.SHA256)
	}
}

func TestReleaseCatalogSchemasResolveAndIndex(t *testing.T) {
	root := filepath.Join("..", "..", ".agents", "skills", "1c-workflow", "assets", "ondemand-mcp", "catalogs")
	for _, test := range []struct {
		family string
		file   string
		count  int
	}{
		{family: "roctup", file: "roctup-v1.7.1.json", count: 13},
		{family: "vanessa-ui", file: "vanessa-ui-v0.6.5-va-1.2.043.28.json", count: 38},
	} {
		t.Run(test.family, func(t *testing.T) {
			catalog, err := loadCatalog(filepath.Join(root, test.file), test.family)
			if err != nil {
				t.Fatal(err)
			}
			if len(catalog.Data.Tools) != test.count || len(catalog.validators) != test.count {
				t.Fatalf("catalog tools=%d validators=%d", len(catalog.Data.Tools), len(catalog.validators))
			}
			for _, tool := range catalog.Data.Tools {
				if catalog.tool(tool.Name) == nil {
					t.Fatalf("tool %q was not indexed", tool.Name)
				}
			}
		})
	}
}

func TestParseBrokerOutputUsesLastMarker(t *testing.T) {
	info, err := parseBrokerOutput("noise\n" + brokerMarker + `{"schemaVersion":1,"status":"running","url":"http://127.0.0.1:6003/mcp"}` + "\n")
	if err != nil {
		t.Fatal(err)
	}
	if info.Status != "running" || info.URL == "" {
		t.Fatalf("unexpected info: %#v", info)
	}
}

func TestValidateBackendVersion(t *testing.T) {
	if err := validateBackendVersion("roctup", map[string]any{"roctup": "v1"}, "v1"); err != nil {
		t.Fatal(err)
	}
	if err := validateBackendVersion("vanessa-ui", map[string]any{"clientMcp": "v1", "vaExtension": "v2"}, "clientMcp=v1;vaExtension=v2"); err != nil {
		t.Fatal(err)
	}
	if err := validateBackendVersion("roctup", map[string]any{"roctup": "v1"}, "v2"); err == nil {
		t.Fatal("incompatible backend version was accepted")
	}
}
