package main

import (
	"encoding/json"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"testing"
)

func TestProductionDatabaseAccessCallsMatchMachineInventory(t *testing.T) {
	type site struct {
		File, Function, Call, Mode string
	}
	var manifest struct {
		GoCalls []site `json:"goCalls"`
	}
	manifestPath := filepath.Join("..", "..", "tests", "database-access-producers.json")
	payload, err := os.ReadFile(manifestPath)
	if err != nil || json.Unmarshal(payload, &manifest) != nil {
		t.Fatalf("read database producer inventory: %v", err)
	}
	wanted := make([]string, 0, len(manifest.GoCalls))
	for _, item := range manifest.GoCalls {
		if item.Mode != "request-canonical" && item.Mode != "canonical-transition" {
			t.Fatalf("unknown Go mode contract %q", item.Mode)
		}
		wanted = append(wanted, item.File+"|"+item.Function+"|"+item.Call)
	}

	entries := []string{}
	if err := filepath.Walk(".", func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if !info.IsDir() && filepath.Ext(path) == ".go" && !(len(path) >= len("_test.go") && path[len(path)-len("_test.go"):] == "_test.go") {
			entries = append(entries, path)
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	actual := []string{}
	for _, path := range entries {
		file, err := parser.ParseFile(token.NewFileSet(), path, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		for _, declaration := range file.Decls {
			function, ok := declaration.(*ast.FuncDecl)
			if !ok || function.Body == nil {
				continue
			}
			ast.Inspect(function.Body, func(node ast.Node) bool {
				call, ok := node.(*ast.CallExpr)
				if !ok {
					return true
				}
				name := ""
				switch target := call.Fun.(type) {
				case *ast.Ident:
					if target.Name == "acquireDatabasePipeOwner" {
						name = target.Name
					}
				case *ast.SelectorExpr:
					if target.Sel.Name == "Transition" {
						name = target.Sel.Name
					}
				}
				if name != "" {
					actual = append(actual, filepath.ToSlash(filepath.Join("tools", "itl-ondemand-mcp", path))+"|"+function.Name.Name+"|"+name)
				}
				return true
			})
		}
	}
	sort.Strings(actual)
	sort.Strings(wanted)
	if len(actual) != len(wanted) {
		t.Fatalf("database call inventory changed: actual=%v wanted=%v", actual, wanted)
	}
	for index := range actual {
		if actual[index] != wanted[index] {
			t.Fatalf("database call inventory changed: actual=%v wanted=%v", actual, wanted)
		}
	}
}
