package main

import (
	"encoding/json"
	"strings"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const roctupDangerousKeywordsRejected = "ITL_ROCTUP_DANGEROUS_KEYWORDS_REJECTED"

// roctupVanessaCodeRoute is the agent continuation for code that the ROCTUP
// profile rejects. The managed branch infobase is the safety boundary; the
// Vanessa (Расширение) code step runs in the same infobase through the ITL
// file-code channel, which has no keyword dialog.
const roctupVanessaCodeRoute = "ROCTUP ran nothing. In-memory collection deletes: rebuild the collection " +
	"(СкопироватьКолонки plus selected rows, or a query) and repeat through ROCTUP. Database or file " +
	"operations needed by the task: put the same code unchanged into one step 'И я выполняю код встроенного языка на сервере (Расширение)' " +
	"of a .feature under build/agent-artifacts/<task-id>/tmp and run it through itl-vanessa-ui run_scenario with that filePath; " +
	"write any value you need to read back to a file in the same tmp directory. Ask the user in chat first only when the code " +
	"deletes or changes data the user prepared or named as reference. Never rename, split or build keywords to pass the check."

// roctupDangerousKeywordRejection converts ROCTUP's immediate rejection of
// execute_code into a coded tool error with the continuation. ROCTUP v1.10.0
// answers danger_confirm=false with an ordinary result whose text is
// {"success":false,"error":"Операция запрещена: ...","dangerous_keywords":[...]}
// and no isError, so the agent could read it as a broken connection. A user's
// refusal in the confirm dialog carries no dangerous_keywords and stays as is.
func roctupDangerousKeywordRejection(family, tool string, result *mcp.CallToolResult) *mcp.CallToolResult {
	if family != "roctup" || tool != "execute_code" || result == nil || result.IsError {
		return result
	}
	var answer struct {
		Success           *bool    `json:"success"`
		Error             string   `json:"error"`
		DangerousKeywords []string `json:"dangerous_keywords"`
	}
	text := strings.TrimPrefix(strings.TrimSpace(resultText(result)), "\uFEFF")
	if json.Unmarshal([]byte(text), &answer) != nil || answer.Success == nil || *answer.Success || len(answer.DangerousKeywords) == 0 {
		return result
	}
	keywords := strings.Join(answer.DangerousKeywords, ", ")
	return toolError(roctupDangerousKeywordsRejected,
		"ROCTUP rejected execute_code before running it: dangerous keywords "+keywords+" are not auto-allowed in this branch profile. "+roctupVanessaCodeRoute,
		map[string]any{
			"tool": tool, "callOutcome": "not-started", "partialEffectsPossible": false,
			"automaticRetryPerformed": false, "backendKept": true, "dangerousKeywords": answer.DangerousKeywords,
			"upstreamError": answer.Error, "action": "route-code-through-vanessa-code-step",
		})
}
