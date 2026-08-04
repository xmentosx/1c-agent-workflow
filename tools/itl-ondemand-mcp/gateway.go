package main

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const (
	gatewayResolveTool           = "resolve_tool"
	gatewayCallTool              = "call_tool"
	gatewayToolLimit             = 3
	gatewaySummaryRunes          = 240
	gatewayArgumentsJSONMaxBytes = 256 * 1024
)

type gatewayCallArguments struct {
	Name          string         `json:"name"`
	Arguments     map[string]any `json:"arguments,omitempty"`
	ArgumentsJSON *string        `json:"argumentsJson,omitempty"`
}

type gatewayResolveArguments struct {
	Query string `json:"query"`
	Limit int    `json:"limit,omitempty"`
}

type gatewayResolution struct {
	Name        string               `json:"name"`
	Summary     string               `json:"summary"`
	Required    []string             `json:"required,omitempty"`
	InputSchema any                  `json:"inputSchema,omitempty"`
	Annotations *mcp.ToolAnnotations `json:"annotations,omitempty"`
}

func addGatewayTools(server *mcp.Server, rt *runtime) {
	server.AddTool(gatewayResolveDefinition(rt.family), func(_ context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		return resolveGatewayTool(rt.catalog, rt.family, req.Params.Arguments), nil
	})
	server.AddTool(gatewayCallDefinition(rt.family), func(ctx context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		var input gatewayCallArguments
		if err := decodeGatewayArguments(req.Params.Arguments, &input); err != nil {
			return toolError("ITL_ONDEMAND_GATEWAY_ARGUMENTS_INVALID", err.Error(), nil), nil
		}
		input.Name = strings.TrimSpace(input.Name)
		if input.Name == "" {
			return toolError("ITL_ONDEMAND_GATEWAY_ARGUMENTS_INVALID", "name is required", nil), nil
		}
		arguments, err := decodeGatewayCallInnerArguments(input)
		if err != nil {
			return toolError("ITL_ONDEMAND_GATEWAY_ARGUMENTS_INVALID", err.Error(), nil), nil
		}
		return rt.callNamed(ctx, req, input.Name, arguments)
	})
}

func gatewayResolveDefinition(family string) *mcp.Tool {
	return &mcp.Tool{
		Name:        gatewayResolveTool,
		Description: "Find an exact inner " + family + " tool without starting 1C. Returns at most three compact candidates and the best candidate's verified input schema. If the inner tool name and arguments are already known, skip this and call call_tool directly.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"query": map[string]any{"type": "string", "description": "Exact tool name or short description of the required operation."},
				"limit": map[string]any{"type": "integer", "minimum": 1, "maximum": gatewayToolLimit, "default": gatewayToolLimit},
			},
			"required":             []any{"query"},
			"additionalProperties": false,
		},
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: true, DestructiveHint: gatewayBool(false), OpenWorldHint: gatewayBool(false), IdempotentHint: true},
	}
}

func gatewayBool(value bool) *bool { return &value }

func gatewayCallDefinition(family string) *mcp.Tool {
	return &mcp.Tool{
		Name:        gatewayCallTool,
		Description: "Call one verified inner " + family + " tool by exact name. For a parameterized tool, put the exact JSON object in argumentsJson, for example {\"query\":\"...\",\"limit\":10}. Use arguments={} for a no-argument tool. Never send arguments and argumentsJson together. The facade parses and validates the verified inner schema before lazy backend startup.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"name": map[string]any{"type": "string", "description": "Exact inner tool name returned by resolve_tool or named by the active ITL skill."},
				"arguments": map[string]any{
					"type": "object", "additionalProperties": true,
					"description": "Backward-compatible inner argument object. Use an empty object for a no-argument tool; schema-restricting clients should use argumentsJson for parameterized calls.",
				},
				"argumentsJson": map[string]any{
					"type": "string", "maxLength": gatewayArgumentsJSONMaxBytes,
					"description": "JSON-encoded inner argument object for parameterized tools. Preserve exact property names and values; example: {\"query\":\"...\",\"limit\":10}.",
				},
			},
			"required":             []any{"name"},
			"additionalProperties": false,
		},
	}
}

func decodeGatewayCallInnerArguments(input gatewayCallArguments) (map[string]any, error) {
	if input.Arguments != nil && input.ArgumentsJSON != nil {
		return nil, fmt.Errorf("arguments and argumentsJson are mutually exclusive")
	}
	if input.ArgumentsJSON == nil {
		if input.Arguments == nil {
			return map[string]any{}, nil
		}
		return input.Arguments, nil
	}
	if len(*input.ArgumentsJSON) > gatewayArgumentsJSONMaxBytes {
		return nil, fmt.Errorf("argumentsJson exceeds %d bytes", gatewayArgumentsJSONMaxBytes)
	}
	var arguments map[string]any
	if err := json.Unmarshal([]byte(*input.ArgumentsJSON), &arguments); err != nil {
		return nil, fmt.Errorf("decode argumentsJson: %w", err)
	}
	if arguments == nil {
		return nil, fmt.Errorf("argumentsJson must encode a JSON object")
	}
	return arguments, nil
}

func decodeGatewayArguments(raw json.RawMessage, target any) error {
	if len(raw) == 0 {
		return fmt.Errorf("arguments object is required")
	}
	if err := json.Unmarshal(raw, target); err != nil {
		return fmt.Errorf("decode gateway arguments: %w", err)
	}
	return nil
}

func resolveGatewayTool(catalog *loadedCatalog, family string, raw json.RawMessage) *mcp.CallToolResult {
	var input gatewayResolveArguments
	if err := decodeGatewayArguments(raw, &input); err != nil {
		return toolError("ITL_ONDEMAND_GATEWAY_ARGUMENTS_INVALID", err.Error(), nil)
	}
	input.Query = strings.TrimSpace(input.Query)
	if input.Query == "" {
		return toolError("ITL_ONDEMAND_GATEWAY_ARGUMENTS_INVALID", "query is required", nil)
	}
	if input.Limit == 0 {
		input.Limit = gatewayToolLimit
	}
	if input.Limit < 1 || input.Limit > gatewayToolLimit {
		return toolError("ITL_ONDEMAND_GATEWAY_ARGUMENTS_INVALID", fmt.Sprintf("limit must be between 1 and %d", gatewayToolLimit), nil)
	}
	matches := searchCatalogTools(catalog, family, input.Query, input.Limit)
	resolutions := make([]gatewayResolution, 0, len(matches))
	for index, tool := range matches {
		item := gatewayResolution{
			Name: tool.Name, Summary: compactToolSummary(tool.Description),
			Required: requiredToolArguments(tool.InputSchema), Annotations: tool.Annotations,
		}
		if index == 0 {
			item.InputSchema = tool.InputSchema
		}
		resolutions = append(resolutions, item)
	}
	payload := map[string]any{
		"family": family, "query": input.Query, "matched": len(resolutions), "tools": resolutions,
		"next": "Call call_tool with the exact inner name. Put parameterized input in argumentsJson as a JSON-encoded object; use arguments={} only for a no-argument tool.",
	}
	encoded, _ := json.Marshal(payload)
	return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: string(encoded)}}}
}

type scoredTool struct {
	tool  *mcp.Tool
	score int
}

func searchCatalogTools(catalog *loadedCatalog, family, query string, limit int) []*mcp.Tool {
	normalizedQuery := normalizeSearchText(query)
	queryTerms := strings.Fields(normalizedQuery)
	scored := make([]scoredTool, 0, len(catalog.Data.Tools))
	for _, tool := range catalog.Data.Tools {
		name := normalizeSearchText(tool.Name)
		haystack := normalizeSearchText(tool.Name + " " + tool.Description + " " + gatewayAliases(family, tool.Name))
		score := 0
		if normalizedQuery == "*" {
			score = 1
		} else if name == normalizedQuery {
			score = 10000
		} else {
			if strings.Contains(name, normalizedQuery) {
				score += 1000
			}
			for _, term := range queryTerms {
				if term == "" {
					continue
				}
				if strings.Contains(name, term) {
					score += 100
				}
				if strings.Contains(haystack, term) {
					score += 10
				}
			}
		}
		if score > 0 {
			scored = append(scored, scoredTool{tool: tool, score: score})
		}
	}
	sort.Slice(scored, func(i, j int) bool {
		if scored[i].score != scored[j].score {
			return scored[i].score > scored[j].score
		}
		return scored[i].tool.Name < scored[j].tool.Name
	})
	if len(scored) > limit {
		scored = scored[:limit]
	}
	result := make([]*mcp.Tool, 0, len(scored))
	for _, item := range scored {
		result = append(result, item.tool)
	}
	return result
}

func normalizeSearchText(value string) string {
	return strings.Join(strings.FieldsFunc(strings.ToLower(value), func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r)
	}), " ")
}

func compactToolSummary(value string) string {
	value = strings.TrimSpace(strings.Split(strings.ReplaceAll(value, "\r\n", "\n"), "\n")[0])
	if utf8.RuneCountInString(value) <= gatewaySummaryRunes {
		return value
	}
	runes := []rune(value)
	return strings.TrimSpace(string(runes[:gatewaySummaryRunes-1])) + "…"
}

func requiredToolArguments(schema any) []string {
	object, ok := schema.(map[string]any)
	if !ok {
		return nil
	}
	raw, ok := object["required"].([]any)
	if !ok {
		return nil
	}
	result := make([]string, 0, len(raw))
	for _, value := range raw {
		if text, ok := value.(string); ok {
			result = append(result, text)
		}
	}
	return result
}

func gatewayAliases(family, name string) string {
	if family != "roctup" {
		return ""
	}
	return map[string]string{
		"get_metadata":               "метаданные структура объекты реквизиты справочник документ",
		"execute_query":              "запрос данные строки таблица выборка",
		"get_event_log":              "журнал регистрации события ошибки",
		"get_screenshot":             "скриншот окно изображение",
		"get_access_rights":          "права доступ роли пользователь",
		"find_references_to_object":  "ссылки использования зависимости объекта",
		"get_bsl_syntax_help":        "синтаксис справка язык 1с bsl",
		"get_link_of_object":         "навигационная ссылка объекта",
		"get_object_by_link":         "получить объект по ссылке",
		"execute_code":               "выполнить код 1с",
		"restart_1c_session":         "перезапустить сеанс 1с",
		"close_1c_session":           "закрыть сеанс 1с",
		"submit_for_deanonymization": "деанонимизация ответа",
	}[name]
}
