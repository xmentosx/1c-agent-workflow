# Vanessa MCP Authoring Contract

Read this together with `vanessa-tests.md` only while creating or editing `.feature` files.

## Flow

Run `/itl-vanessa-author`. The helper updates the copied branch infobase, starts Vanessa UI MCP, and persists worktree-local reload/resume state. For every changed feature use:

`search_for_steps_by_keywords → open_feature_file → check_syntax → get_info_about_line_scenario → run_scenario → get_test_results`.

The search schema is `search_name`, `search_description`, `search_type`, `exclude_name`, `exclude_description`, `exclude_type`, and `limit`. Never invent `keywords`, call the endpoint through raw HTTP, or treat KB/reference text as proof that the current runtime exposes a step. Finish through `complete-vanessa-authoring`; the helper stops MCP and cleans managed client config. Then run `/itl-check` for `TESTMANAGER → TESTCLIENT`, JUnit, and event-log evidence.

## Libraries And References

`Libraries/ITL/Core` and exactly one of `Libraries/ITL/PM4|PM5` are workflow-managed. `Libraries/Product` is project-owned. Current reference URLs are in `assets/vanessa-reference-suites.json` and always use latest `master`, not pinned commits. PM4 is executable only for PM4; in PM5 it can suggest business cases and Gherkin structure, but steps, data, selectors, forms, and assertions require PM5/MCP validation.

Use the established navigation-link pair:

```gherkin
И я сохраняю навигационную ссылку текущего окна в переменную "Ссылка"
И Я открываю навигационную ссылку "$Ссылка$"
```

In BSL use `ПолучитьНавигационнуюСсылку(Объект.Ссылка)`. A local server-block variable does not become a Vanessa `$Переменная$`; consume it inside that block or transfer it through supported Vanessa context/library steps.
