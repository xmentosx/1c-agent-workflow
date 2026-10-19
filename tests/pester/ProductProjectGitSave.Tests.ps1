Describe 'Catalog Git authoring uses the existing native capture owner' {
    BeforeAll {
        $RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        . (Join-Path $RepoRoot 'scripts/git-path-list.ps1')
        foreach($leaf in @('core','vanessa','vibecoding1c-mcp','product-catalog','product-project')) {
            . (Join-Path $RepoRoot ".agents/skills/1c-workflow/scripts/lib/agent-1c.$leaf.ps1")
        }
        function Resolve-Agent1cFullPath { param($Path) [IO.Path]::GetFullPath($Path) }
        function New-SaveFixture {
            param([string]$Root)
            [void][IO.Directory]::CreateDirectory($Root)
            $source=Join-Path $Root 'Исходный каталог'
            [void][IO.Directory]::CreateDirectory((Join-Path $source 'catalog'))
            $null=Invoke-RepositoryGit $source @('init','-b','main')
            $null=Invoke-RepositoryGit $source @('config','user.name','Catalog Fixture')
            $null=Invoke-RepositoryGit $source @('config','user.email','catalog@example.test')
            $documents=@{
                'registry.json'=@{schemaVersion=2;hosts=@();future='preserve'}
                'catalog/catalog.json'=@{schemaVersion=1;products=@(@{productId='corp';name='КОРП'});projects=@();sources=@();instances=@();future=@{note='Сохранить'}}
                'catalog/product-relations.json'=@{schemaVersion=1;relations=@();knowledgeAreas=@{}}
            }
            foreach($path in $documents.Keys){[IO.File]::WriteAllText((Join-Path $source $path),($documents[$path] | ConvertTo-Json -Depth 40),[Text.UTF8Encoding]::new($false))}
            $null=Invoke-RepositoryGit $source @('add','.')
            $null=Invoke-RepositoryGit $source @('commit','-m','initial')
            $remote=Join-Path $Root 'Общий реестр.git'
            $null=Invoke-RepositoryGit $Root @('clone','--bare',$source,$remote)
            $null=Invoke-RepositoryGit $source @('remote','add','origin',$remote)
            $null=Invoke-RepositoryGit $source @('fetch','origin')
            $null=Invoke-RepositoryGit $source @('remote','set-head','origin','main')
            return @{source=$source;remote=$remote;base=(Invoke-RepositoryGit $source @('rev-parse','HEAD')).stdout.Trim();record=@{projectId='customer';productId='corp';name='Заказчик А'}}
        }
        function Read-SavedFixture { param($f) Read-ItlProductCatalogSnapshot $f.remote 'refs/heads/main' }
        $NativeCatalogGit=${function:Invoke-ItlCatalogGit}
    }

    It 'saves and confirms a Unicode project without changing the reader checkout or other files' {
        $f=New-SaveFixture (Join-Path $TestDrive 'Unicode путь')
        $before=Get-FileHash (Join-Path $f.source 'catalog/catalog.json')
        $s=Read-SavedFixture $f
        $r=Save-ItlCatalogRecord -RepositoryRoot $f.source -BaseCommit $f.base -Record $f.record
        $r.status | Should -Be 'saved'
        $r.outcome | Should -Be 'confirmed'
        $actual=Read-SavedFixture $f
        $actual.catalog.projects[0].name | Should -Be 'Заказчик А'
        $actual.catalog.future.note | Should -Be 'Сохранить'
        $actual.inputGitObjectIds.'registry.json' | Should -Be $s.inputGitObjectIds.'registry.json'
        $actual.inputGitObjectIds.'catalog/product-relations.json' | Should -Be $s.inputGitObjectIds.'catalog/product-relations.json'
        (Get-FileHash (Join-Path $f.source 'catalog/catalog.json')).Hash | Should -Be $before.Hash
        (Invoke-RepositoryGit $f.source @('status','--porcelain','-z')).stdout | Should -BeNullOrEmpty
    }

    It 'reuses the same stable ID after a lost successful push reply' {
        $f=New-SaveFixture (Join-Path $TestDrive 'lost reply')
        Mock Invoke-ItlCatalogGit {
            param($Root,$Arguments,$DeadlineUtc,$AllowFailure)
            $r=& $NativeCatalogGit -Root $Root -Arguments $Arguments -DeadlineUtc $DeadlineUtc -AllowFailure:$AllowFailure
            if($Arguments[0] -eq 'push'){$r.exitCode=1}
            $r
        }
        (Save-ItlCatalogRecord $f.source $f.base -Record $f.record).status | Should -Be 'saved'
        (Save-ItlCatalogRecord $f.source $f.base -Record $f.record).status | Should -Be 'saved'
        @( (Read-SavedFixture $f).catalog.projects ).Count | Should -Be 1
        (Invoke-RepositoryGit $f.remote @('rev-list','--count','main')).stdout.Trim() | Should -Be '2'
        Should -Invoke Invoke-ItlCatalogGit -Times 1 -Exactly -ParameterFilter { $Arguments[0] -eq 'push' }
    }

    It 'merges an independent remote record against the original pinned base' {
        $f=New-SaveFixture (Join-Path $TestDrive 'independent')
        $other=@{projectId='other';productId='corp';name='Другой проект'}
        (Save-ItlCatalogRecord $f.source $f.base -Record $other).status | Should -Be 'saved'
        (Save-ItlCatalogRecord $f.source $f.base -Record $f.record).status | Should -Be 'saved'
        @((Read-SavedFixture $f).catalog.projects).Count | Should -Be 2
    }

    It 'returns applied/current/proposed on a same-record conflict without overwriting remote' {
        $f=New-SaveFixture (Join-Path $TestDrive 'conflict')
        $other=@{projectId='customer';productId='corp';name='Чужая правка'}
        (Save-ItlCatalogRecord $f.source $f.base -Record $other).status | Should -Be 'saved'
        $r=Save-ItlCatalogRecord $f.source $f.base -Record $f.record
        $r.status | Should -Be 'conflict'
        $r.comparison.current.name | Should -Be 'Чужая правка'
        $r.comparison.proposed.name | Should -Be 'Заказчик А'
        (Read-SavedFixture $f).catalog.projects[0].name | Should -Be 'Чужая правка'
    }

    It 'returns a complete unsubmitted request when the actual remote hook denies write' {
        $f=New-SaveFixture (Join-Path $TestDrive 'denied')
        [IO.File]::WriteAllText((Join-Path $f.remote 'hooks/pre-receive'),"#!/bin/sh`nexit 1`n",[Text.UTF8Encoding]::new($false))
        $r=Save-ItlCatalogRecord $f.source $f.base -Record $f.record
        $r.status | Should -Be 'prepared-request'
        $r.outcome | Should -Be 'not-saved'
        $r.recordId | Should -Be 'customer'
        $r.record.name | Should -Be 'Заказчик А'
        (Read-SavedFixture $f).catalogRevision | Should -Be $f.base
    }

    It 'preserves an unknown remote outcome until a subsequent exact read-back' {
        $f=New-SaveFixture (Join-Path $TestDrive 'unknown')
        $script:fixturePushSeen=$false
        Mock Invoke-ItlCatalogGit {
            param($Root,$Arguments,$DeadlineUtc,$AllowFailure)
            if($script:fixturePushSeen -and $Arguments[0] -eq 'fetch'){throw 'network unavailable after push'}
            $r=& $NativeCatalogGit -Root $Root -Arguments $Arguments -DeadlineUtc $DeadlineUtc -AllowFailure:$AllowFailure
            if($Arguments[0] -eq 'push'){$script:fixturePushSeen=$true}
            $r
        }
        $r=Save-ItlCatalogRecord $f.source $f.base -Record $f.record
        $r.outcome | Should -Be 'unknown'
        $r.status | Should -Not -Be 'saved'
        (Read-SavedFixture $f).catalog.projects[0].projectId | Should -Be 'customer'
        Should -Invoke Invoke-ItlCatalogGit -Times 1 -Exactly -ParameterFilter {$Arguments[0] -eq 'push'}
    }

    It 'rejects invalid model data before starting any Git authoring operation' {
        $f=New-SaveFixture (Join-Path $TestDrive 'invalid')
        $f.record.productId='missing'
        Mock Invoke-ItlCatalogGit {throw 'must not run'}
        {Save-ItlCatalogRecord $f.source $f.base -Record $f.record} | Should -Throw '*CATALOG_INVALID*'
        Should -Invoke Invoke-ItlCatalogGit -Times 0 -Exactly
    }

    It 'retains the record and reader on an expired operation deadline' {
        $f=New-SaveFixture (Join-Path $TestDrive 'deadline')
        $r=Save-ItlCatalogRecord $f.source $f.base -Record $f.record -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(-1))
        $r.status | Should -Be 'prepared-request'
        $r.recordId | Should -Be 'customer'
        (Read-SavedFixture $f).catalogRevision | Should -Be $f.base
        (Invoke-RepositoryGit $f.source @('status','--porcelain','-z')).stdout | Should -BeNullOrEmpty
    }

    It 'does not persist credentials embedded in catalog URL metadata' {
        $f=New-SaveFixture (Join-Path $TestDrive 'url credentials')
        $f.record.dashboard='https://fixture:fixture@example.test/'
        Mock Invoke-ItlCatalogGit {throw 'must not run'}
        {Save-ItlCatalogRecord $f.source $f.base -Record $f.record} | Should -Throw '*URL credentials*'
        Should -Invoke Invoke-ItlCatalogGit -Times 0 -Exactly
    }

    It 'reconciles an actual non-fast-forward race without overwriting <Kind>' -TestCases @(@{Kind='independent'},@{Kind='same-record'}) {
        param($Kind)
        $f=New-SaveFixture (Join-Path $TestDrive ('race-' + $Kind))
        $script:outerSaveRoot=''; $script:outerPushes=0; $script:raceInjected=$false
        Mock Invoke-ItlCatalogGit {
            param($Root,$Arguments,$DeadlineUtc,$AllowFailure)
            if($Arguments[0] -eq 'push'){
                if(-not $script:outerSaveRoot){$script:outerSaveRoot=$Root}
                if($Root -ceq $script:outerSaveRoot){$script:outerPushes++}
                if(-not $script:raceInjected){
                    $script:raceInjected=$true
                    $competing=@{projectId=$(if($Kind -eq 'independent'){'other'}else{'customer'});productId='corp';name='Concurrent record'}
                    $competed=Save-ItlCatalogRecord $f.source $f.base -Record $competing
                    if($competed.status -ne 'saved'){throw 'Race fixture did not publish its competing record'}
                }
            }
            & $NativeCatalogGit -Root $Root -Arguments $Arguments -DeadlineUtc $DeadlineUtc -AllowFailure:$AllowFailure
        }
        $r=Save-ItlCatalogRecord $f.source $f.base -Record $f.record
        if($Kind -eq 'independent'){
            $r.status | Should -Be 'saved'
            @((Read-SavedFixture $f).catalog.projects).Count | Should -Be 2
            $script:outerPushes | Should -Be 2
        }else{
            $r.status | Should -Be 'conflict'
            (Read-SavedFixture $f).catalog.projects[0].name | Should -Be 'Concurrent record'
            $script:outerPushes | Should -Be 1
        }
    }
}
