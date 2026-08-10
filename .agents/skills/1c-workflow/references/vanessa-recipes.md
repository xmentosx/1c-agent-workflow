# Vanessa Automation: Worked Recipes

> Read only the recipe selected by `vanessa-tests.md`. Companion files live in
> `assets/vanessa-authoring-examples`; they are examples, not a runnable suite.

## Contract

Choose one recipe by the behavior to prove. Before copying a `@template` file,
replace every `<...>` marker, remove `@template`, confirm each step through the
current local libraries or `search_for_steps_by_keywords`, and confirm selectors
against current metadata/runtime evidence. Then keep only setup, one action, and
one to three observable assertions. Never turn all recipes into a mandatory
checklist.

The portable `unit-like.feature` has no product identifiers and can be passed to
`check_syntax` unchanged. The other files are deliberately product-neutral
templates: static lint verifies their safe structure, while only an adapted
project scenario can be executed and accepted by `/itl-check`.

Upstream `docs/AI` is research input, not an installed runtime dependency. Do
not link a live `develop` document as a normative rule or copy its full prompts.
Re-audit it only when upgrading the pinned Vanessa version, and bring over a
bounded pattern only when it improves these local recipes or a verified tool
contract.

## 1. Unit-Like Logic

Use `unit-like.feature` when one TestClient-side `(Расширение)` server block can calculate and assert the
result. Keep all local values in that block. Replace the demonstration expression
with the application call and an exact expected value; do not open a form merely
to reach the same logic.

## 2. Integration Or Persistence

Use `integration-persistence.feature` for creating an object, invoking one
operation, and reading the persisted result. Replace all BSL markers in one
server block, or replace the block with an established exported business
scenario. Use unique data and assert the exact object/register state, not only
that posting or saving did not raise an error.

## 3. UI Navigation And Command

Use `ui-navigation.feature` when the requirement is visible UI behavior. Open the
target through a verified application/library step, then use the supported pair:

```gherkin
И я сохраняю навигационную ссылку текущего окна в переменную "Ссылка"
И Я открываю навигационную ссылку "$Ссылка$"
```

Never create `$Ссылка$` as a local BSL variable: local block state does not enter
Vanessa context. Prefer internal element names, check warning/ErrorWindow before
dependent actions, and assert the resulting visible state.

## 4. Stable Table Row

Use `table-row.feature` when the action targets a table row. Position by a stable
business key immediately before selecting the current row. Add key columns if a
single value is ambiguous. Assert a value or state produced by the selection;
the click itself is not the result.

## 5. Report Output

Use `report-output.feature` when the requirement concerns generated report
content. Establish parameters and mode explicitly, form the report, and compare
the named table document with a small versioned template. Confirm the exact
comparison step in the current runtime because report-step wording varies across
Vanessa/library versions. Do not replace a semantic comparison with a screenshot.

## Runtime Discovery, Only When Needed

If static evidence cannot identify the actual interaction, use one Vanessa UI
MCP facade instance. Connect `itl-ondemand`, call `user_actions_recording` with
`action=start`, perform the shortest human interaction, then call it with
`action=stop`. Treat returned Turbo Gherkin as a draft: remove noise, replace
captions/coordinates with stable names, make setup deterministic, and add exact
assertions.

For deterministic exploratory input, prefer one `execute_form_actions` call with
a short `actions_json` array over repeated single-field calls. First inspect only
the relevant form state. End a batch before a modal dialog, window change, or
state that must be checked before the next action. The inner call shape is:

```json
{"name":"execute_form_actions","argumentsJson":"{\"actions_json\":\"[{\\\"action\\\":\\\"set_value\\\",\\\"element_name\\\":\\\"<ИмяПоля>\\\",\\\"value\\\":\\\"<Значение>\\\"}]\"}"}
```

For visual evidence, call `get_window_list_os`, select
the exact returned title, then call `get_window_screenshot_os`; screenshots are
supplementary. Query the knowledge base only for a named gap and request a small
portion; never load `format=all`. Text `search_string` is supported for narrow
`question_search` or `answers_search`; use `questions_only` followed by one
`one_question` when browsing by question number is cheaper.

During diagnosis, `run_scenario` with `reloadAndRunFromLine` and a real step line
may shorten a rerun, for example inner arguments
`{"filePath":"<absolute.feature>","mode":"reloadAndRunFromLine","lineNumber":42}`.
It can skip setup and therefore never proves the whole scenario. Pair any run
with `get_test_results` from the same facade instance and feature SHA.
`/itl-check` remains the only executable verification gate.

## Wrong To Right

- Wrong: invent `$НавигационнаяСсылка$` inside BSL. Right: use a supported Vanessa
  variable step or consume the value in the same BSL block.
- Wrong: select the current row left by another scenario. Right: position by a
  unique key immediately before selection.
- Wrong: use `Пауза 5` after every click. Right: wait for a named window/state;
  retain a pause only for an unavoidable external event and explain it.
- Wrong: assert only that no exception occurred. Right: assert the changed value,
  record, movement, row, command state, or report content.
- Wrong: copy a large upstream/external feature. Right: adapt one local recipe and
  validate its steps, selectors, data, and assertions in the current project.
