# Аудит тестов исходного workflow

Базовая точка до перестройки: 36 файлов, 581 `It`, 23 366 строк. После первой
ревизии и добавления проверок нового delivery-процесса: 35 файлов, 566 `It`,
23 365 строк. Каталог качества механически требует оставаться ниже исходной
точки и не позволяет компенсировать новые journey бесконтрольным ростом Pester.

## Правила решения

- `keep`: уникальная исполняемая или safety-граница.
- `merge`: несколько текстовых или инфраструктурных случаев принадлежат одному
  контракту и выполняются одним `It` без потери assertions.
- `delete`: тот же контракт уже проверяется основным owner-suite.
- `move`: assertions сохранены, но перенесены к основному владельцу.

| Набор | Решение | Основной контракт |
|---|---|---|
| AiRulesClients | keep | client/rules packaging |
| AiRulesCompatibilityPromotion | keep | evidence-backed fork promotion |
| AiRulesMigration | keep | installed rules migration |
| AiRulesOverlay | keep | controlled overlay identity |
| BootstrapUpdate | keep | bootstrap and update-workflow |
| BranchSeedRefreshLite | keep | latest-only seed and lite refresh |
| ClientAdaptersAndModes | keep | native client adapters |
| CompactItlRunner | keep | bounded structured runner |
| DependencyLocks | keep | immutable dependency agreement |
| DesignerCompletion | keep | Designer completion/failure boundaries |
| DesignerMemoryGuard | keep | independent memory guard |
| DevBranchLifecycle | keep | branch lifecycle and rollback |
| ExtensionInitialization | keep | extension branch initialization |
| FormElementContext | keep | bounded safe Form.xml lookup |
| GitHubDependencyFallback | keep | authenticated immutable fallback |
| HostTooling | keep | standalone host contracts |
| KiloContextDiagnostics | keep | client context diagnostics |
| KiloVerificationRecovery | merge | completion and requiredAction flow |
| LifecycleOperationLock | keep | lock ownership and recovery |
| LocalQualityGate | merge | source gate, catalog and qualification |
| McpConfig | keep | MCP configuration ownership |
| OnDemandMcp | keep | on-demand process isolation |
| OpenCodeWorkspace | keep | external workspace lifecycle |
| ParserDocsBudgets | merge | parser, docs and ignored runtime inventory |
| ReleaseGate | keep | release-only orchestration boundaries |
| ReleaseReadiness | keep | fail-fast release preflight |
| ReleaseUnsafeActionProtection | keep | unsafe-action confirmation identity |
| TriageContract | delete | duplicated by ParserDocsBudgets triage contract |
| UiTools | keep | installed UI tools contract |
| VanessaArtifactIntegration | keep | pinned artifact integration |
| VanessaAuthoring | keep | executable authoring behavior |
| VanessaAuthoringLint | keep | feature lint boundaries |
| VanessaInteractiveProfile | keep | isolated interactive profile |
| VanessaPatchedArtifact | keep | patched artifact provenance |
| VanessaRuntimeCleanup | keep | exact runtime cleanup ownership |
| VanessaTestGuide | move/delete | markers moved into ParserDocsBudgets |

## Удалённое покрытие

- `TriageContract.Tests.ps1`: четыре сочетания `executionPath/planningMode`,
  promotion semantics и согласованность документов уже принадлежат
  `ParserDocsBudgets.Tests.ps1`; controlled-fork identity остаётся частью Full
  compatibility inventory.
- `VanessaTestGuide.Tests.ps1`: пять отдельных текстовых случаев заменены одним
  owner-контрактом в `ParserDocsBudgets.Tests.ps1`; markers Gherkin, runtime
  visibility, form research, BSL contexts и product neutrality сохранены.
- Раздельные parse- и gitignore-cases в `ParserDocsBudgets.Tests.ps1` объединены
  в табличные проходы. Все исходные файлы и пути продолжают проверяться.
- Три текстовых completion-cases в `KiloVerificationRecovery.Tests.ps1`
  объединены вокруг одного перехода `failed -> requiredAction -> recovery ->
  fresh passed`; исполняемый snapshot test оставлен отдельным.

Следующий тест добавляется только при новом контракте. Если существующий owner
уже доказывает поведение, агент регистрирует его id через `-CoverageContract`,
а `Targeted` действительно запускает соответствующий файл.

## Измерение времени

- Последнее сохранённое доказательство прежней статической `Full`-квалификации:
  470 235 мс.
- После перестройки статическая часть прошла 566/566 без ошибок; самый долгий
  изолированный shard занял 298 441 мс, а от старта gate до перехода к первому
  `Develop` journey прошло 362 393 мс.
- Финальные длительности всех стадий не переписываются в этот tracked-отчёт
  после квалификации: они сохраняются вместе с точным деревом в
  `build/test-results/local/check-summary.json` и qualification JSON.
