function Get-SourceE2ECatalogArguments {
    param([string]$Root, [string]$ConfigurationPath='', [switch]$AllowBoundQualificationFixture)
    # Qualification data only: never infer a business-project association. The
    # repository's exact minimal configuration identifies this technical stand.
    $projectPath=Join-Path $Root '.agent-1c/project.json'
    if(-not (Test-Path -LiteralPath $projectPath -PathType Leaf)){return @()}
    $project=Get-Content -LiteralPath $projectPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if($project.PSObject.Properties['productProject'] -and $null -ne $project.productProject){
        if(-not $AllowBoundQualificationFixture -or
            [string]$project.productProject.projectId -cne 'itl-gate-qualification' -or
            [string]$project.productProject.productId -cne 'itl-gate-fixture' -or
            [string]$project.productProject.requiredCapability -cne 'product-project-registry-v1'){return @()}
    }
    if(-not $ConfigurationPath){$ConfigurationPath=Join-Path $Root 'src/cf/Configuration.xml'}
    if(-not (Test-Path -LiteralPath $ConfigurationPath -PathType Leaf)){return @()}
    $fixturePath=Join-Path $PSScriptRoot '../tests/fixtures/gate-stand/cf/Configuration.xml'
    $actual=[xml](Get-Content -LiteralPath $ConfigurationPath -Raw -Encoding UTF8)
    $fixture=[xml](Get-Content -LiteralPath $fixturePath -Raw -Encoding UTF8)
    if([string]$actual.MetaDataObject.Configuration.uuid -cne [string]$fixture.MetaDataObject.Configuration.uuid){return @()}
    return @('-CatalogProjectId','itl-gate-qualification','-CatalogDecision','keep-local')
}

function Initialize-SourceE2ECatalog {
    param([string]$Root, [string[]]$AdditionalRoots=@(), [string]$ConfigurationPath='', [switch]$RestoreQualificationPublisher)
    # A technical copy retains its binding but Git does not carry the ignored
    # publisher. Restore that dependency only for the exact qualification UUID
    # and binding, without selecting or replacing a business association.
    $selection=@(Get-SourceE2ECatalogArguments -Root $Root -ConfigurationPath $ConfigurationPath -AllowBoundQualificationFixture:$RestoreQualificationPublisher)
    if(-not $selection.Count){return @()}
    $project=Get-Content -LiteralPath (Join-Path $Root '.agent-1c/project.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $publisher=Join-Path $Root '.agent-1c/mcp/qualification-catalog'
    if(-not (Test-Path -LiteralPath (Join-Path $publisher '.git') -PathType Container)){
        [void][IO.Directory]::CreateDirectory((Join-Path $publisher 'catalog'))
        $utf8=[Text.UTF8Encoding]::new($false)
        $data=@{
            'registry.json'=@{schemaVersion=2;hosts=@()}
            'catalog/catalog.json'=@{schemaVersion=1;products=@(@{productId='itl-gate-fixture';name='ITL technical qualification fixture';baseConfigurationVersion=[string]$project.baseConfigurationVersion});projects=@(@{projectId='itl-gate-qualification';name='ITL qualification only';productId='itl-gate-fixture'});profiles=@();sources=@();instances=@()}
            'catalog/product-relations.json'=@{schemaVersion=1;relations=@();knowledgeAreas=@{}}
        }
        foreach($path in $data.Keys){[IO.File]::WriteAllText((Join-Path $publisher $path),($data[$path]|ConvertTo-Json -Depth 12),$utf8)}
        foreach($arguments in @(@('init','--quiet','--initial-branch=main'),@('add','--','registry.json','catalog'),@('-c','user.name=ITL qualification','-c','user.email=qualification@example.invalid','commit','--quiet','-m','Publish technical qualification catalog'))){
            & git -C $publisher @arguments
            if($LASTEXITCODE -ne 0){throw 'SOURCE_E2E_CATALOG_PUBLICATION_FAILED: retain the fixture and its local Git publisher; diagnose before retrying.'}
        }
    }
    foreach($target in @($Root)+@($AdditionalRoots)){
        $settings=Get-Content -LiteralPath (Join-Path $target '.agent-1c/project.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if($settings.PSObject.Properties['productProject'] -and $null -ne $settings.productProject){
            if(-not $RestoreQualificationPublisher -or @(Get-SourceE2ECatalogArguments -Root $target -AllowBoundQualificationFixture).Count -eq 0){continue}
        }
        $envPath=Join-Path $target '.dev.env'
        $lines=@(if(Test-Path -LiteralPath $envPath){[IO.File]::ReadAllLines($envPath,[Text.Encoding]::UTF8) | Where-Object {$_ -notmatch '^VIBECODING1C_MCP_REGISTRY_(REPO|PATH)='}})
        $lines+=@("VIBECODING1C_MCP_REGISTRY_REPO=$publisher","VIBECODING1C_MCP_REGISTRY_PATH=$publisher")
        [IO.File]::WriteAllText($envPath,(($lines -join [Environment]::NewLine)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
    }
    return $selection
}

function Get-SourceE2EBootstrapCatalogArguments {
    param([string]$BootstrapPath, [string[]]$CatalogArguments)
    $parameters=(Get-Command -Name $BootstrapPath).Parameters
    for($i=0;$i -lt $CatalogArguments.Count;$i+=2){
        if($parameters.ContainsKey($CatalogArguments[$i].TrimStart('-'))){$CatalogArguments[$i..($i+1)]}
    }
}

function Test-SourceE2ELegacyUpdateEvidence {
    param([object]$ProcessResult, [string]$Root, [string]$CandidateRoot, [datetime]$StartedAt, [switch]$AllowCatalogSelection)
    # A compact parent may only report POST_COPY_INCOMPLETE. Admit the exact
    # fresh child's terminal guard, never recovery prose or an older run.
    try {
        $summary = Read-SourceE2ECompactSummary -ProcessResult $ProcessResult
        if ([int]$ProcessResult.exitCode -eq 0 -or $summary.action -cne 'update-workflow' -or
            $summary.status -cne 'failed' -or $summary.blockerRequiresUserDecision -ne $false) { return $false }
        $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
        $candidatePath = [IO.Path]::GetFullPath($CandidateRoot).TrimEnd('\','/')
        $statusPath = [IO.Path]::GetFullPath([string]$summary.statusPath)
        $runsPath = (Join-Path $rootPath '.agent-1c/runs') + [IO.Path]::DirectorySeparatorChar
        if (-not $statusPath.StartsWith($runsPath, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($statusPath) -cne 'status.json') { return $false }
        $matches = @(Get-ChildItem -LiteralPath (Split-Path -Parent $statusPath) -Filter 'status.json.fresh-*.json' -File | ForEach-Object {
            $status = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($status.action -ceq 'update-workflow' -and $status.status -ceq 'failed' -and
                $status.stage -ceq 'workflow-update.post-copy' -and [int]$status.exitCode -ne 0 -and
                $status.blockerRequiresUserDecision -eq $false -and
                ([datetimeoffset]$status.startedAt).UtcDateTime -ge $StartedAt.ToUniversalTime() -and
                [string]::Equals([IO.Path]::GetFullPath([string]$status.projectRoot).TrimEnd('\','/'), $rootPath, [StringComparison]::OrdinalIgnoreCase) -and
                ([string]$status.errorMessage -cmatch '^(UI_TESTING_POLICY_LEGACY_SNAPSHOT|VERIFICATION_MODEL_POLICY_LEGACY_SNAPSHOT):' -or
                    ($AllowCatalogSelection -and [string]$status.errorMessage -cmatch '^CATALOG_PROJECT_REQUIRED:')) -and
                ([string]$status.errorMessage).Contains("Original candidate: '$candidatePath'.")) { $status }
        })
        return $matches.Count -eq 1
    } catch { return $false }
}

function Invoke-SourceE2EWorkflowUpdate {
    param([string]$Root, [string]$CandidateRoot, [string]$AgentTarget, [int]$TimeoutSeconds,
        [scriptblock]$InstalledOperation, [scriptblock]$SourceOperation)
    $started = [datetime]::UtcNow
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        # Baseline/factory preparation owns registry settings. Updating a seed
        # only selects its project, leaving the first transaction backup exact.
        $catalogArguments=@(Get-SourceE2ECatalogArguments -Root $Root)
        $initial = & $InstalledOperation $TimeoutSeconds $catalogArguments
        $continuation = $null
        if ([int]$initial.exitCode -ne 0) {
            if (-not (Test-SourceE2ELegacyUpdateEvidence -ProcessResult $initial -Root $Root -CandidateRoot $CandidateRoot -StartedAt $started -AllowCatalogSelection:($catalogArguments.Count -gt 0))) {
                throw "SOURCE_E2E_UPDATE_FAILED: legacy continuation refused; original logs=$($initial.stdout), $($initial.stderr)"
            }
            $remaining = [int][math]::Floor($TimeoutSeconds - $watch.Elapsed.TotalSeconds)
            if ($remaining -lt 1) { throw "SOURCE_E2E_UPDATE_TIMEOUT: original operation budget exhausted; logs=$($initial.stdout)" }
            # The existing source updater alone owns snapshot admission, resume,
            # rollback and branch rollout. There is no E2E receipt/state repair.
            $arguments = @('-ProjectRoot',$Root,'-SourceRoot',$CandidateRoot,'-Recovery','update','-AgentTarget',$AgentTarget)
            $arguments += $catalogArguments
            $continuation = & $SourceOperation (Join-Path $CandidateRoot 'scripts/update-installed-workflow.ps1') $arguments $remaining
            if ([int]$continuation.exitCode -ne 0) {
                throw "SOURCE_E2E_UPDATE_CONTINUATION_FAILED: original logs=$($initial.stdout); continuation logs=$($continuation.stdout), $($continuation.stderr)"
            }
        } else {
            $summary = Read-SourceE2ECompactSummary -ProcessResult $initial
            if ($summary.action -cne 'update-workflow' -or $summary.status -cne 'succeeded') { throw "SOURCE_E2E_UPDATE_FAILED: invalid successful summary; logs=$($initial.stdout)" }
        }
        return [pscustomobject]@{ initial=$initial; continuation=$continuation; durationMs=[int64]$watch.ElapsedMilliseconds }
    } finally { $watch.Stop() }
}
