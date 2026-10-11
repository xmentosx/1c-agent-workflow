BeforeAll {
    . (Join-Path $PSScriptRoot "TestSupport.ps1")
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
}

Describe 'Owned E2E artifact cleanup' {
It "removes an exact disposable E2E repository, worktree, and launcher registration" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl-e2e-cleanup-" + [guid]::NewGuid().ToString("N")); $main = Join-Path $root "d-1234abcd"; $branch = Join-Path $root "d-1234abcd-develop-golden"; $launcher = Join-Path $root "appdata\1C\1CEStart\ibases.v8i"
        try { New-Item -ItemType Directory -Force -Path $main | Out-Null; & git -C $main init *> $null; & git -C $main config user.name "ITL Test"; & git -C $main config user.email "itl-test@example.invalid"
            Set-Content -LiteralPath (Join-Path $main "value.txt") -Value "one" -Encoding ASCII; & git -C $main add value.txt; & git -C $main commit -m init *> $null; & git -C $main worktree add --quiet -b itldev/develop-golden $branch *> $null; . (Join-Path $RepoRoot "scripts\develop-e2e-cleanup.ps1")
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $launcher) | Out-Null; $infoBase = Join-Path $branch ".agent-1c\infobases\dev-branches\develop-golden"; New-Item -ItemType Directory -Force -Path $infoBase | Out-Null
            @('[keep]','Connect=File="C:\keep";','Folder=/','', '[d-1234abcd-develop-golden]','Connect=File="C:\keep-duplicate";','Folder=/Other','', '[d-1234abcd-develop-golden]',"Connect=File=`"$infoBase`";",'Folder=/ITL/d-1234abcd','', '[d-1234abcd]','OrderInList=-1','Folder=/ITL') | Set-Content -LiteralPath $launcher -Encoding UTF8
            Remove-DevelopE2EFreshProject -FreshProjectsRoot $root -Path $main -BranchPath $branch -LauncherListPath $launcher; Test-Path -LiteralPath $main | Should -BeFalse; Test-Path -LiteralPath $branch | Should -BeFalse
            $launcherText = Get-Content -LiteralPath $launcher -Raw -Encoding UTF8; $launcherText | Should -Match '\[keep\]'; $launcherText | Should -Match 'C:\\keep-duplicate'; $launcherText | Should -Not -Match 'Folder=/ITL/d-1234abcd'; $launcherText | Should -Not -Match '(?m)^\[d-1234abcd\]$'; @(Get-ChildItem -LiteralPath (Split-Path -Parent $launcher) -Filter 'ibases.v8i.*.bak').Count | Should -Be 1
            $bytes = [IO.File]::ReadAllBytes($launcher); @($bytes[0], $bytes[1], $bytes[2]) | Should -Be @(0xEF, 0xBB, 0xBF)
        } finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
    }

It "removes the owned Cyrillic-path branch left after Git unregisters it but fails to delete its directory" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl-e2e-cleanup-p Проект-" + [guid]::NewGuid().ToString('N'))
        $main = Join-Path $root 'd-1234abcd'; $branch = "$main-develop-golden"; $launcher = Join-Path $root 'appdata\1C\1CEStart\ibases.v8i'; $sibling = "$root-keep"
        try {
            New-Item -ItemType Directory -Force -Path $main, $sibling | Out-Null
            & git -C $main init *> $null; & git -C $main config user.name 'ITL Test'; & git -C $main config user.email 'itl-test@example.invalid'
            Set-Content -LiteralPath (Join-Path $main 'value.txt') -Value 'one' -Encoding ASCII
            & git -C $main add value.txt; & git -C $main commit -m init *> $null
            & git -C $main worktree add --quiet -b itldev/develop-golden $branch *> $null
            $gitPointer = Get-Content -LiteralPath (Join-Path $branch '.git') -Raw -Encoding UTF8
            & git -C $main worktree remove --force -- $branch *> $null
            $LASTEXITCODE | Should -Be 0
            New-Item -ItemType Directory -Force -Path (Join-Path $branch 'ignored') | Out-Null
            [IO.File]::WriteAllText((Join-Path $branch '.git'), $gitPointer, [Text.UTF8Encoding]::new($false))
            Set-Content -LiteralPath (Join-Path $branch 'ignored\residue.txt') -Value 'left by Git' -Encoding UTF8
            . (Join-Path $RepoRoot 'scripts\develop-e2e-cleanup.ps1')
            Remove-DevelopE2EFreshProject -FreshProjectsRoot $root -Path $main -BranchPath $branch -LauncherListPath $launcher
            Test-Path -LiteralPath $main | Should -BeFalse
            Test-Path -LiteralPath $branch | Should -BeFalse
            Test-Path -LiteralPath $sibling | Should -BeTrue
        } finally {
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
            if (Test-Path -LiteralPath $sibling) { Remove-Item -LiteralPath $sibling -Recurse -Force }
        }
    }

It "bulk-removes only missing Develop E2E launcher registrations" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl-e2e-launcher-cleanup-" + [guid]::NewGuid().ToString("N")); $launcher = Join-Path $root "appdata\1C\1CEStart\ibases.v8i"; $existing = Join-Path $root "d-22222222-develop-golden\.agent-1c\infobases\dev-branches\develop-golden"
        try { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $launcher), $existing | Out-Null; . (Join-Path $RepoRoot "scripts\develop-e2e-cleanup.ps1")
            $missing = Join-Path $root "d-11111111-develop-golden\.agent-1c\infobases\dev-branches\develop-golden"; @('[d-11111111-develop-golden]',"Connect=File=`"$missing`";",'Folder=/ITL/d-11111111','', '[d-11111111]','OrderInList=-1','Folder=/ITL','', '[d-22222222-develop-golden]',"Connect=File=`"$existing`";",'Folder=/ITL/d-22222222','', '[d-22222222]','OrderInList=-1','Folder=/ITL','', '[user-base]','Connect=File="C:\user";','Folder=/') | Set-Content -LiteralPath $launcher -Encoding UTF8
            Remove-DevelopE2EStaleLauncherRegistrations -FreshProjectsRoot $root -LauncherListPath $launcher | Should -Be 1; $launcherText = Get-Content -LiteralPath $launcher -Raw -Encoding UTF8
            $launcherText | Should -Not -Match 'd-11111111'; $launcherText | Should -Match 'd-22222222-develop-golden'; $launcherText | Should -Match '\[user-base\]'
        } finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
    }

It "finds nested special-path fresh entries and retains only three launcher backups" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl nested launcher Проект " + [guid]::NewGuid().ToString("N")); $launcher = Join-Path $root "appdata\1C\1CEStart\ibases.v8i"
        try {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $launcher) | Out-Null; . (Join-Path $RepoRoot "scripts\develop-e2e-cleanup.ps1")
            $missing = Join-Path $root "p Проект\d-11111111-develop-golden\.agent-1c\infobases\dev-branches\develop-golden"
            @('[d-11111111-develop-golden]',"Connect=File=`"$missing`";",'Folder=/ITL/d-11111111','', '[d-11111111]','OrderInList=-1','Folder=/ITL') | Set-Content -LiteralPath $launcher -Encoding UTF8
            1..5 | ForEach-Object { Copy-Item -LiteralPath $launcher -Destination "$launcher.2026082$_-120000-000.bak" }
            Remove-DevelopE2EStaleLauncherRegistrations -FreshProjectsRoot $root -LauncherListPath $launcher | Should -Be 1
            @(Get-ChildItem -LiteralPath (Split-Path -Parent $launcher) -Filter 'ibases.v8i.*.bak').Count | Should -Be 3
            Get-Content -LiteralPath $launcher -Raw -Encoding UTF8 | Should -Not -Match 'd-11111111'
        } finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
    }

It "removes only exact missing release-seed launcher entries" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl release launcher " + [guid]::NewGuid().ToString("N")); $launcher = Join-Path $root "appdata\1C\1CEStart\ibases.v8i"
        try {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $launcher) | Out-Null; . (Join-Path $RepoRoot "scripts\develop-e2e-cleanup.ps1")
            $missing = Join-Path $root 'itlsa-1234abcd\.agent-1c\infobases\dev-branches\release-seed-a-1234abcd'
            @('[itl-workflow-e2e-pm5-release-seed-a-1234abcd]',"Connect=File=`"$missing`";",'Folder=/ITL/itl-workflow-e2e-pm5','', '[user-base]',"Connect=File=`"$missing`";",'Folder=/') | Set-Content -LiteralPath $launcher -Encoding UTF8
            Remove-ReleaseE2EStaleLauncherRegistrations -LauncherListPath $launcher -SeedRoot $root | Should -Be 1
            $text = Get-Content -LiteralPath $launcher -Raw -Encoding UTF8; $text | Should -Not -Match 'itl-workflow-e2e-pm5-release-seed'; $text | Should -Match '\[user-base\]'
        } finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
    }

It "removes verified Develop E2E CF exports while preserving unrelated result files" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl e2e exports Проект " + [guid]::NewGuid().ToString("N"))
        try {
            $resultRoot = Join-Path $root "build\result"; New-Item -ItemType Directory -Force -Path $resultRoot | Out-Null
            $artifact = Join-Path $resultRoot "current.cf"; Set-Content -LiteralPath $artifact -Encoding ASCII -Value "verified"
            $manifestPath = "$artifact.manifest.json"; $sha = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
            [IO.File]::WriteAllText($manifestPath, (([ordered]@{ artifact = [ordered]@{ path = $artifact; sha256 = $sha } } | ConvertTo-Json -Depth 4) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            Set-Content -LiteralPath (Join-Path $resultRoot "old.cf") -Encoding ASCII -Value "old"
            Set-Content -LiteralPath (Join-Path $resultRoot "old.cf.manifest.json") -Encoding ASCII -Value "old manifest"
            Set-Content -LiteralPath (Join-Path $resultRoot "keep.txt") -Encoding ASCII -Value "keep"
            . (Join-Path $RepoRoot "scripts\develop-e2e-cleanup.ps1")
            $cleanup = Remove-DevelopE2EExportArtifacts -Root $root -Summary ([pscustomobject]@{ resultManifestPath = $manifestPath })
            $cleanup.removedFiles | Should -Be 4; $cleanup.removedBytes | Should -BeGreaterThan 0
            @(Get-ChildItem -LiteralPath $resultRoot -Filter "*.cf*" -File).Count | Should -Be 0
            Test-Path -LiteralPath (Join-Path $resultRoot "keep.txt") -PathType Leaf | Should -BeTrue
        } finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
    }

It "removes only unconfigured workflow Release E2E worktrees after a passed journey" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("itl e2e worktrees Проект " + [guid]::NewGuid().ToString("N")); $main = Join-Path $root "main"; $release = Join-Path $root "release"; $develop = Join-Path $root "develop"; $stale = Join-Path $root "stale"
        $preserved = Join-Path $root "retained evidence"
        try {
            New-Item -ItemType Directory -Force -Path $main | Out-Null; & git -C $main init --quiet; & git -C $main config user.name "ITL Test"; & git -C $main config user.email "itl-test@example.invalid"
            Set-Content -LiteralPath (Join-Path $main ".gitignore") -Encoding ASCII -Value ".agent-1c/`nbuild/"; Set-Content -LiteralPath (Join-Path $main "README.md") -Encoding ASCII -Value "fixture"
            & git -C $main add .gitignore README.md; & git -C $main commit --quiet -m init
            & git -C $main worktree add --quiet -b itldev/workflow-release-e2e $release; & git -C $main worktree add --quiet -b itldev/workflow-release-e2e-preflight $develop; & git -C $main worktree add --quiet -b itldev/workflow-release-e2e-rules $stale
            & git -C $main worktree add --quiet -b itldev/workflow-release-e2e-retained $preserved
            $pendingPath = Join-Path $preserved ".agent-1c/dev-branches/workflow-release-e2e-retained.json"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $pendingPath) | Out-Null
            [IO.File]::WriteAllText($pendingPath, '{"pendingMergeOperation":"refresh-dev-branch","pendingMergeStage":"merged"}', [Text.UTF8Encoding]::new($false))
            $pendingHash = (Get-FileHash -LiteralPath $pendingPath -Algorithm SHA256).Hash
            Set-Content -LiteralPath (Join-Path $preserved "README.md") -Encoding ASCII -Value "preserved user edit"
            New-Item -ItemType Directory -Force -Path (Join-Path $main ".agent-1c"), (Join-Path $stale "build\result") | Out-Null
            [IO.File]::WriteAllText((Join-Path $main ".agent-1c\release-e2e.json"), (([ordered]@{ schemaVersion=1; devBranchName="workflow-release-e2e"; worktreePath=$release; developDevBranchName="workflow-release-e2e-preflight"; developWorktreePath=$develop; preserveWorktreePaths=@($preserved) } | ConvertTo-Json -Depth 4) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            Set-Content -LiteralPath (Join-Path $stale "build\result\obsolete.cf") -Encoding ASCII -Value "obsolete"
            . (Join-Path $RepoRoot "scripts\develop-e2e-cleanup.ps1")
            $cleanup = Remove-DevelopE2EStaleStandWorktrees -ProjectRoot $main
            $cleanup.removedWorktrees | Should -Be 1; Test-Path -LiteralPath $stale | Should -BeFalse; Test-Path -LiteralPath $release | Should -BeTrue; Test-Path -LiteralPath $develop | Should -BeTrue
            Test-Path -LiteralPath $preserved -PathType Container | Should -BeTrue
            (Get-FileHash -LiteralPath $pendingPath -Algorithm SHA256).Hash | Should -BeExactly $pendingHash
            (Get-Content -LiteralPath (Join-Path $preserved "README.md") -Raw).Trim() | Should -BeExactly "preserved user edit"
            & git -C $main show-ref --verify --quiet refs/heads/itldev/workflow-release-e2e-retained; $LASTEXITCODE | Should -Be 0
            & git -C $main show-ref --verify --quiet refs/heads/itldev/workflow-release-e2e-rules; $LASTEXITCODE | Should -Be 1
            $dirty = Join-Path $root "dirty"; & git -C $main worktree add --quiet -b itldev/workflow-release-e2e-dirty $dirty
            Set-Content -LiteralPath (Join-Path $dirty "README.md") -Encoding ASCII -Value "tracked drift"
            { Remove-DevelopE2EStaleStandWorktrees -ProjectRoot $main } | Should -Throw "*tracked changes*"
            Test-Path -LiteralPath $dirty -PathType Container | Should -BeTrue
        } finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
    }
}
