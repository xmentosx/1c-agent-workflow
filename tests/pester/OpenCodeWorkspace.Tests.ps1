Describe "OpenCode native ITL workspaces" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HelperPath = $context.HelperPath
        $LifecyclePath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.lifecycle.ps1"
        $LifecycleText = Get-Content -LiteralPath $LifecyclePath -Raw -Encoding UTF8
        $PluginPath = Join-Path $RepoRoot ".agents\skills\1c-workflow\opencode-plugin-templates\itl-workspace.js.template"
        $PluginText = Get-Content -LiteralPath $PluginPath -Raw -Encoding UTF8
    }

    It "keeps external creation as the legacy path and never adds a second worktree during adopt" {
        $newStart = $LifecycleText.IndexOf('function New-DevBranchCore')
        $newEnd = $LifecycleText.IndexOf('function New-DevBranch', $newStart + 1)
        $adoptStart = $LifecycleText.IndexOf('function Adopt-DevWorktree')
        $adoptEnd = $LifecycleText.IndexOf('function Get-ResumableDevBranchState', $adoptStart)
        $newStart | Should -BeGreaterThan -1
        $adoptStart | Should -BeGreaterThan -1
        $newBlock = $LifecycleText.Substring($newStart, $newEnd - $newStart)
        $adoptBlock = $LifecycleText.Substring($adoptStart, $adoptEnd - $adoptStart)
        $newBlock | Should -Match 'worktree", "add"'
        $adoptBlock | Should -Not -Match 'worktree", "add"'
        $adoptBlock | Should -Match 'Initialize-DevBranchRuntime'
        $adoptBlock | Should -Match 'Existing legacy development branch state will not be migrated'
        $adoptBlock | Should -Match 'workspace runtime root mismatch'
    }

    It "persists only new OpenCode state in the main worktree" {
        $initStart = $LifecycleText.IndexOf('function Initialize-DevBranchRuntime')
        $planStart = $LifecycleText.IndexOf('function Get-DevWorkspacePlan')
        $initBlock = $LifecycleText.Substring($initStart, $planStart - $initStart)
        $initBlock | Should -Match '\[string\]\$StateProjectRoot = \$script:ProjectRoot'
        $initBlock | Should -Match 'workspaceProvider'
        $initBlock | Should -Match 'clientWorkspaceId'
        $initBlock | Should -Match 'runtimeRoot'
        $initBlock | Should -Match 'worktreeLocked'
        $initBlock | Should -Match 'if \(\$WorkspaceProvider\)'
        $initBlock | Should -Match 'ProjectRootOverride \$stateProjectRoot'
    }

    It "preflights a new branch without mutating Git or tracked files" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-opencode-plan-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"masterBranch":"master","aiRules":{"tools":["opencode"]}}'
            Set-Content -LiteralPath (Join-Path $tempRoot ".gitignore") -Encoding UTF8 -Value ".agent-1c/`n.dev.env`n"
            Set-Content -LiteralPath (Join-Path $tempRoot "tracked.txt") -Encoding UTF8 -Value "base"
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot add .gitignore tracked.txt
            & git -C $tempRoot commit -m "base" *> $null
            & git -C $tempRoot branch -M master
            $before = ((& git -C $tempRoot rev-parse HEAD) -join "").Trim()
            $plan = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help -DevBranchName "native" -DevBranchKind configuration *> $null
                Get-DevWorkspacePlan | ConvertFrom-Json
            }
            $plan.mode | Should -Be "create"
            $plan.branch | Should -Be "itldev/native"
            $plan.baseCommit | Should -Be $before
            $plan.mainWorktreePath | Should -Be ([IO.Path]::GetFullPath($tempRoot))
            $plan.runtimeRoot | Should -Be (Join-Path ([IO.Path]::GetFullPath($tempRoot)) ".agent-1c\workspaces\native")
            ((& git -C $tempRoot rev-parse HEAD) -join "").Trim() | Should -Be $before
            @(& git -C $tempRoot status --porcelain) | Should -BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "refuses an existing legacy branch without changing its state" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-opencode-legacy-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c\dev-branches") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"masterBranch":"master","aiRules":{"tools":["opencode"]}}'
            Set-Content -LiteralPath (Join-Path $tempRoot ".gitignore") -Encoding UTF8 -Value ".agent-1c/`n.dev.env`n"
            Set-Content -LiteralPath (Join-Path $tempRoot "tracked.txt") -Encoding UTF8 -Value "base"
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot add .gitignore tracked.txt
            & git -C $tempRoot commit -m "base" *> $null
            & git -C $tempRoot branch -M master
            & git -C $tempRoot branch itldev/legacy
            $statePath = Join-Path $tempRoot ".agent-1c\dev-branches\legacy.json"
            Set-Content -LiteralPath $statePath -Encoding UTF8 -Value '{"devBranchName":"legacy","devBranch":"itldev/legacy","initializationStatus":"ready"}'
            $before = (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash
            $errorText = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help -DevBranchName "legacy" -DevBranchKind configuration *> $null
                try { Get-DevWorkspacePlan | Out-Null } catch { $_.Exception.Message }
            }
            $errorText | Should -Match 'legacy development branch will not be migrated'
            (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash | Should -Be $before
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "resumes only provider-marked OpenCode state and locks its existing worktree" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-opencode-resume-" + [guid]::NewGuid().ToString("N"))
        $worktreeRoot = $tempRoot + "-workspace"
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c\dev-branches") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"masterBranch":"master","aiRules":{"tools":["opencode"]}}'
            Set-Content -LiteralPath (Join-Path $tempRoot ".gitignore") -Encoding UTF8 -Value ".agent-1c/`n.dev.env`n"
            Set-Content -LiteralPath (Join-Path $tempRoot "tracked.txt") -Encoding UTF8 -Value "base"
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot add .gitignore tracked.txt
            & git -C $tempRoot commit -m "base" *> $null
            & git -C $tempRoot branch -M master
            & git -C $tempRoot worktree add --quiet -b itldev/resume $worktreeRoot master *> $null
            $state = [ordered]@{
                devBranchName = "resume"
                safeDevBranchName = "resume"
                devBranch = "itldev/resume"
                workspaceProvider = "opencode"
                worktreePath = [IO.Path]::GetFullPath($worktreeRoot)
                mainWorktreePath = [IO.Path]::GetFullPath($tempRoot)
                initializationStatus = "failed"
            }
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\dev-branches\resume.json") -Encoding UTF8 -Value (($state | ConvertTo-Json -Depth 5) + "`n")
            $plan = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help -DevBranchName "resume" -DevBranchKind configuration *> $null
                Get-DevWorkspacePlan | ConvertFrom-Json
            }
            $plan.mode | Should -Be "resume"
            $plan.worktreePath | Should -Be ([IO.Path]::GetFullPath($worktreeRoot))
            $plan.baseCommit | Should -Be (((& git -C $worktreeRoot rev-parse HEAD) -join "").Trim())

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Lock-OpenCodeDevWorktree -MainRoot $tempRoot -WorktreePath $worktreeRoot -Branch "itldev/resume"
            }
            ((& git -C $tempRoot worktree list --porcelain) -join "`n") | Should -Match '(?m)^locked ITL managed OpenCode workspace$'
        } finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                & git -C $tempRoot worktree remove --force --force $worktreeRoot *> $null
            }
            Remove-Item -LiteralPath $worktreeRoot, $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "unlocks only closed provider state and relocks a failed deregistration" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-opencode-close-" + [guid]::NewGuid().ToString("N"))
        $worktreeRoot = $tempRoot + "-workspace"
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c\dev-branches") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"masterBranch":"master","aiRules":{"tools":["opencode"]}}'
            Set-Content -LiteralPath (Join-Path $tempRoot ".gitignore") -Encoding UTF8 -Value ".agent-1c/`n.dev.env`n"
            Set-Content -LiteralPath (Join-Path $tempRoot "tracked.txt") -Encoding UTF8 -Value "base"
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot add .gitignore tracked.txt
            & git -C $tempRoot commit -m "base" *> $null
            & git -C $tempRoot branch -M master
            & git -C $tempRoot worktree add --quiet -b itldev/close $worktreeRoot master *> $null
            & git -C $tempRoot worktree lock --reason "ITL managed OpenCode workspace" $worktreeRoot
            $state = [ordered]@{
                devBranchName = "close"
                safeDevBranchName = "close"
                devBranch = "itldev/close"
                workspaceProvider = "opencode"
                clientWorkspaceId = "old-id"
                worktreePath = [IO.Path]::GetFullPath($worktreeRoot)
                mainWorktreePath = [IO.Path]::GetFullPath($tempRoot)
                worktreeLocked = $true
                initializationStatus = "ready"
                closedAt = (Get-Date).ToString("o")
            }
            $statePath = Join-Path $tempRoot ".agent-1c\dev-branches\close.json"
            Set-Content -LiteralPath $statePath -Encoding UTF8 -Value (($state | ConvertTo-Json -Depth 5) + "`n")

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help -DevBranchName "close" -DeregistrationStatus pending -ClientWorkspaceId "new-id" *> $null
                Set-DevWorkspaceDeregistration
            }
            ((& git -C $tempRoot worktree list --porcelain) -join "`n") | Should -Not -Match '(?m)^locked'
            $pending = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $pending.pendingDeregistration | Should -BeTrue
            $pending.clientWorkspaceId | Should -Be "new-id"

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help -DevBranchName "close" -DeregistrationStatus failed -DeregistrationError "mock remove failure" -ClientWorkspaceId "new-id" *> $null
                Set-DevWorkspaceDeregistration
            }
            ((& git -C $tempRoot worktree list --porcelain) -join "`n") | Should -Match '(?m)^locked ITL managed OpenCode workspace$'
            $failed = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $failed.pendingDeregistration | Should -BeTrue
            $failed.pendingDeregistrationError | Should -Be "mock remove failure"

            & git -C $tempRoot worktree unlock $worktreeRoot
            & git -C $tempRoot worktree remove --force $worktreeRoot
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help -DevBranchName "close" -DeregistrationStatus complete -ClientWorkspaceId "new-id" *> $null
                Set-DevWorkspaceDeregistration
            }
            $complete = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $complete.pendingDeregistration | Should -BeFalse
            $complete.worktreeLocked | Should -BeFalse
            $complete.workspaceDeregisteredAt | Should -Not -BeNullOrEmpty
        } finally {
            if ((Test-Path -LiteralPath $tempRoot -PathType Container) -and (Test-Path -LiteralPath $worktreeRoot -PathType Container)) {
                & git -C $tempRoot worktree remove --force --force $worktreeRoot *> $null
            }
            Remove-Item -LiteralPath $worktreeRoot, $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "encodes capability failure readiness adopt resume and warp in the plugin contract" {
        $PluginText | Should -Match 'OPENCODE_WORKSPACE_API_UNAVAILABLE'
        $PluginText | Should -Match 'workspace\.adapter\.list'
        $PluginText | Should -Match 'workspace\.syncList'
        $PluginText | Should -Match 'workspace\.create'
        $PluginText | Should -Match 'waitUntilReady'
        $PluginText | Should -Match 'adopt-dev-worktree'
        $PluginText | Should -Match 'workspace\.warp'
        $PluginText | Should -Match 'itl_close_dev_workspace'
        $PluginText | Should -Match 'workspace\.remove'
        $PluginText | Should -Match 'OPENCODE_WORKSPACE_DEREGISTRATION_PENDING'
        $PluginText | Should -Match 'set-dev-workspace-deregistration'
        $PluginText | Should -Match '60_000'
        $PluginText | Should -Not -Match 'experimental\.worktree\.create'
        $syntaxPath = Join-Path ([IO.Path]::GetTempPath()) ("itl-opencode-plugin-" + [guid]::NewGuid().ToString("N") + ".mjs")
        try {
            Set-Content -LiteralPath $syntaxPath -Encoding UTF8 -Value $PluginText
            & node --check $syntaxPath
            $LASTEXITCODE | Should -Be 0
        } finally { Remove-Item -LiteralPath $syntaxPath -Force -ErrorAction SilentlyContinue }
    }

    It "runs create readiness adopt and warp against the mock native API contract" {
        $mockRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-opencode-mock-" + [guid]::NewGuid().ToString("N"))
        $workspaceRoot = Join-Path $mockRoot "workspace"
        try {
            $packageRoot = Join-Path $mockRoot "node_modules\@opencode-ai\plugin"
            New-Item -ItemType Directory -Force -Path $packageRoot, (Join-Path $workspaceRoot ".agents\skills\1c-workflow\scripts") | Out-Null
            Set-Content -LiteralPath (Join-Path $workspaceRoot ".agents\skills\1c-workflow\scripts\agent-1c.ps1") -Encoding UTF8 -Value "# mock"
            Set-Content -LiteralPath (Join-Path $packageRoot "package.json") -Encoding UTF8 -Value '{"type":"module","exports":"./index.js"}'
            Set-Content -LiteralPath (Join-Path $packageRoot "index.js") -Encoding UTF8 -Value @'
export const tool = (config) => config
const schema = () => ({ optional() { return this }, min() { return this } })
tool.schema = { enum: schema, string: schema, boolean: schema }
'@
            $pluginCopy = Join-Path $mockRoot "itl-workspace.mjs"
            Set-Content -LiteralPath $pluginCopy -Encoding UTF8 -Value $PluginText
            $harness = Join-Path $mockRoot "harness.mjs"
            Set-Content -LiteralPath $harness -Encoding UTF8 -Value @'
import { pathToFileURL } from "node:url"
const main = process.env.ITL_MOCK_MAIN
const workspace = process.env.ITL_MOCK_WORKSPACE
const branch = "itldev/mock"
const commit = "0123456789012345678901234567890123456789"
const events = []
const output = (text, code = 0) => ({ stdout: new Blob([text]), stderr: new Blob([""]), exited: Promise.resolve(code) })
globalThis.Bun = { spawn(args) {
  const joined = args.join(" ")
  if (joined.includes("get-dev-workspace-plan")) return output(JSON.stringify({ mode: "create", kind: "configuration", safeName: "mock", branch, baseCommit: commit, mainWorktreePath: main, worktreePath: "", runtimeRoot: main + "/.agent-1c/workspaces/mock" }) + "\n")
  if (joined.includes("branch --show-current")) return output(branch + "\n")
  if (joined.includes("rev-parse HEAD")) return output(commit + "\n")
  if (joined.includes("worktree list --porcelain")) return output("worktree " + workspace.replaceAll("\\", "/") + "\nbranch refs/heads/" + branch + "\n")
  if (joined.includes("adopt-dev-worktree")) { events.push("adopt"); return output('{"status":"succeeded"}\n') }
  throw new Error("unexpected spawn: " + joined)
} }
const client = { experimental: { workspace: {
  adapter: { list: async () => { events.push("probe"); return { data: [{ type: "worktree" }] } } },
  list: async () => { events.push("list"); return { data: [] } },
  create: async (input) => { events.push("create:" + input.branch); return { data: { id: "workspace-id", directory: workspace, branch } } },
  syncList: async () => { events.push("sync") },
  warp: async (input) => { events.push("warp:" + input.id); return {} },
} } }
const { ItlWorkspacePlugin } = await import(pathToFileURL(process.env.ITL_PLUGIN))
const plugin = await ItlWorkspacePlugin({ client })
await plugin.tool.itl_create_dev_workspace.execute({ kind: "configuration", name: "mock" }, { worktree: main, sessionID: "session-id" })
process.stdout.write(JSON.stringify(events))
'@
            $oldMain = $env:ITL_MOCK_MAIN
            $oldWorkspace = $env:ITL_MOCK_WORKSPACE
            $oldPlugin = $env:ITL_PLUGIN
            try {
                $env:ITL_MOCK_MAIN = $mockRoot
                $env:ITL_MOCK_WORKSPACE = $workspaceRoot
                $env:ITL_PLUGIN = $pluginCopy
                $events = (& node $harness) | ConvertFrom-Json
                $LASTEXITCODE | Should -Be 0
                @($events) -join "," | Should -Be "probe,list,create:itldev/mock,adopt,warp:workspace-id"
            } finally {
                $env:ITL_MOCK_MAIN = $oldMain
                $env:ITL_MOCK_WORKSPACE = $oldWorkspace
                $env:ITL_PLUGIN = $oldPlugin
            }
        } finally { Remove-Item -LiteralPath $mockRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
