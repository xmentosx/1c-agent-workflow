package main

import (
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func TestFirstOSWindowTitleUsesVanessaListResult(t *testing.T) {
	result := &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: "Для снятия скриншотов найдено 1 окон:\n  -dev_test / 1С:Предприятие"}}}
	if got := firstOSWindowTitle(result); got != "dev_test / 1С:Предприятие" {
		t.Fatalf("title=%q", got)
	}
}
