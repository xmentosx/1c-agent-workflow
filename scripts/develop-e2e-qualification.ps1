Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "git-path-list.ps1")
. (Join-Path $PSScriptRoot "quality-contracts.ps1")
. (Join-Path $PSScriptRoot "stand-env-identity.ps1")
. (Join-Path $PSScriptRoot 'develop-journey-inputs.ps1')

function Get-DevelopE2EInputFileSha256 {
    param([string]$Path, [string]$RelativePath)
    # Git may materialize workflow PowerShell source as LF or CRLF in different
    # clean worktrees. Bind its UTF-8 source, retaining BOM and every other byte.
    # Native artifacts, 1C transport and third-party source remain byte-exact.
    if ($RelativePath -notmatch '^(scripts/|\.agents/skills/|templates/).*\.ps1$') {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    $text = $encoding.GetString([IO.File]::ReadAllBytes($Path)).Replace("`r`n", "`n")
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($encoding.GetBytes($text)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-DevelopE2EInputIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][ValidateSet('upgrade','fresh')][string]$Journey,
        [object]$Catalog = $null,
        [string]$ProjectRoot = '', [string]$AiRulesSource = '', [string]$AgentTarget = '',
        [object]$ExternalBinding = $null, [object]$ArtifactBinding = $null,
        [AllowNull()][Collections.Generic.List[object]]$Diagnostics=$null
    )
    try {
        if ($null -eq $Catalog) { $Catalog = Get-QualityContractCatalog -RepositoryRoot $RepositoryRoot }
        $projection = Get-DevelopE2EJourneyContractProjection -Catalog $Catalog -Journey $Journey
        $patterns = @($projection.contracts | ForEach-Object { @($_.paths) })
        $patterns += @($projection.contracts | ForEach-Object { Get-QualityContractReuseInputPaths -Contract $_ })
        # Conservative source inventory; this is not an installed managed-copy policy.
        $patterns += @('.agents/skills/*','templates/*','AGENT-INSTALL.md','install-agent-1c-workflow.ps1','tools/*')
        $patterns += @('scripts/invoke-develop-e2e.ps1','scripts/source-e2e-manifest-repair.ps1','scripts/develop-e2e-cleanup.ps1','scripts/stand-env-identity.ps1',
            'scripts/git-path-list.ps1','scripts/check.ps1','scripts/test-release-readiness.ps1','scripts/Build-ItlOnDemandMcp.ps1')
        if ($Journey -eq 'upgrade') { $patterns += 'scripts/develop-configuration-rejection.ps1' }
        # Git inventory is unique. Ordinal ordering also stays identical between
        # the Core supervisor and its Windows PowerShell checker child.
        [string[]]$paths = @(Get-RepositoryGitPathList -RepositoryRoot $RepositoryRoot -Arguments @('ls-files','-z','--'))
        [Array]::Sort($paths, [StringComparer]::Ordinal)
        $inputs = @(foreach ($path in @(Select-QualityPaths -Paths $paths -Pattern $patterns)) {
            # Isolated Pester execution belongs to the separate static proof.
            # Journey fixtures/features and all production inputs remain bound.
            if ($path -like 'tests/pester/*.Tests.ps1') { continue }
            $physical = Join-Path $RepositoryRoot $path.Replace('/','\')
            if (-not (Test-Path -LiteralPath $physical -PathType Leaf)) { throw 'DEVELOP_INPUT_MISSING' }
            [ordered]@{ path=$path; sha256=Get-DevelopE2EInputFileSha256 -Path $physical -RelativePath $path }
        })
        # The positive stand uses this same source snapshot. Capture source
        # inputs once per invocation; every stand/environment is still read
        # independently, and a later checker invocation takes a new snapshot.
        function Get-DevelopStandInputIdentity {
            param([string]$ProjectRoot,[object]$ExternalBinding)
            $positiveIdentity = $null
            if ($null -eq $ExternalBinding) {
                if (-not $ProjectRoot -or -not $AiRulesSource) {
                    Add-DevelopReuseDiagnostic -Diagnostics $Diagnostics -Code 'BINDING_LOCATION_MISSING' -Inputs @('ProjectRoot','AiRulesSource' | Where-Object {-not (Get-Variable $_ -ValueOnly)})
                    return $null
                }
                $stand = Get-DevelopE2EStandStateSha256 -ProjectRoot $ProjectRoot
                $files = [ordered]@{}
                foreach ($relative in @('.agent-1c/project.json','.agent-1c/release-e2e.json','.dev.env')) {
                    $physical = Join-Path $ProjectRoot $relative.Replace('/','\')
                    if (-not (Test-Path -LiteralPath $physical -PathType Leaf)) {
                        Add-DevelopReuseDiagnostic -Diagnostics $Diagnostics -Code 'STAND_INPUT_MISSING' -Inputs @($relative); return $null
                    }
                    $files[$relative] = if ($relative -eq '.dev.env') { Get-DeliveryStableDotEnvSha256 -Path $physical } elseif ($relative -eq '.agent-1c/release-e2e.json') {
                        $configInput = Get-Content -LiteralPath $physical -Raw -Encoding UTF8 | ConvertFrom-Json
                        # Capture independently validates every admission before the
                        # gate. Its receipt chain changes with installed workflow
                        # commits, but does not change the immutable capsule input.
                        if ($configInput.PSObject.Properties['qualificationFixtures']) {
                            foreach ($descriptor in $configInput.qualificationFixtures.PSObject.Properties) {
                                $descriptor.Value.PSObject.Properties.Remove('workflowUpdateAdmission')
                            }
                        }
                        Get-DevelopE2ECanonicalJsonSha256 -Value $configInput
                    } else { (Get-FileHash -LiteralPath $physical -Algorithm SHA256).Hash.ToLowerInvariant() }
                }
                # UI policy affects installed behavior but is not in the older semantic dotenv projection.
                $ui = @([IO.File]::ReadAllLines((Join-Path $ProjectRoot '.dev.env'), [Text.Encoding]::UTF8) | Where-Object { $_ -match '^\s*(?:AGENT_1C_)?UI_TESTING\s*=' })
                $processValues = [ordered]@{}
                foreach ($name in @((Get-DeliveryPlanSemanticDotEnvNames) + @('UI_TESTING','ITL_VANESSA_MCP_CLIENT_SOURCE_BUILD_CFE') | Sort-Object -Unique)) {
                    foreach ($key in @($name, "AGENT_1C_$name")) {
                        $processValues[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
                    }
                }
                $artifacts = [ordered]@{}
                if ($null -ne $ArtifactBinding) {
                    $artifacts = Get-SourceE2EArtifactBindingHashes -RepositoryRoot $RepositoryRoot -Binding $ArtifactBinding
                } else {
                    foreach ($name in @('ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE','VANESSA_MCP_CLIENT_CFE_PATH','ITL_ONDEMAND_MCP_SOURCE_BUILD_EXE')) {
                        $physical = [Environment]::GetEnvironmentVariable($name,'Process')
                        if (-not $physical -or -not (Test-Path -LiteralPath $physical -PathType Leaf)) {
                            Add-DevelopReuseDiagnostic -Diagnostics $Diagnostics -Code 'ARTIFACT_BINDING_MISSING' -Inputs @($name); return $null
                        }
                        $artifacts[$name] = (Get-FileHash -LiteralPath $physical -Algorithm SHA256).Hash.ToLowerInvariant()
                    }
                }
                $runtime = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                if (-not (Test-Path -LiteralPath $runtime -PathType Leaf)) {
                    Add-DevelopReuseDiagnostic -Diagnostics $Diagnostics -Code 'HOST_RUNTIME_MISSING' -Inputs @('WindowsPowerShell'); return $null
                }
                $platformLine = @([IO.File]::ReadAllLines((Join-Path $ProjectRoot '.dev.env'), [Text.Encoding]::UTF8) | Where-Object { $_ -match '^\s*PLATFORM_PATH\s*=' }) | Select-Object -Last 1
                if (-not $platformLine) {
                    Add-DevelopReuseDiagnostic -Diagnostics $Diagnostics -Code 'STAND_INPUT_MISSING' -Inputs @('PLATFORM_PATH'); return $null
                }
                $platform = ($platformLine.Substring($platformLine.IndexOf('=') + 1)).Trim().Trim('"',"'")
                if (Test-Path -LiteralPath $platform -PathType Container) { $platform = Join-Path $platform '1cv8.exe' }
                if (-not (Test-Path -LiteralPath $platform -PathType Leaf)) {
                    Add-DevelopReuseDiagnostic -Diagnostics $Diagnostics -Code 'HOST_RUNTIME_MISSING' -Inputs @('PLATFORM_PATH'); return $null
                }
                $go = Get-Command go.exe -ErrorAction SilentlyContinue
                if (-not $go -or -not (Test-Path -LiteralPath $go.Source -PathType Leaf)) {
                    Add-DevelopReuseDiagnostic -Diagnostics $Diagnostics -Code 'HOST_RUNTIME_MISSING' -Inputs @('go.exe'); return $null
                }
                $ExternalBinding = [ordered]@{
                    complete=$true; standStateSha256=$stand; root=[IO.Path]::GetFullPath($ProjectRoot).ToLowerInvariant()
                    files=$files; uiPolicySha256=Get-DevelopE2ECanonicalJsonSha256 -Value $ui
                    processEnvironmentSha256=Get-DevelopE2ECanonicalJsonSha256 -Value $processValues
                    osKernelSha256=(Get-FileHash -LiteralPath (Join-Path $env:SystemRoot 'System32\kernel32.dll') -Algorithm SHA256).Hash.ToLowerInvariant(); freshProjectsRoot='C:\itlj'
                    client=Get-SourceE2EClientIdentity -ProjectRoot $ProjectRoot -AgentTarget $AgentTarget
                    rulesCommit=(Invoke-RepositoryGit -RepositoryRoot $AiRulesSource -Arguments @('rev-parse','HEAD')).stdout.Trim()
                    rulesTree=(Invoke-RepositoryGit -RepositoryRoot $AiRulesSource -Arguments @('rev-parse','HEAD^{tree}')).stdout.Trim()
                    artifacts=$artifacts; nativeRuntimeSha256=(Get-FileHash -LiteralPath $runtime -Algorithm SHA256).Hash.ToLowerInvariant()
                    platformSha256=(Get-FileHash -LiteralPath $platform -Algorithm SHA256).Hash.ToLowerInvariant()
                    goSha256=(Get-FileHash -LiteralPath $go.Source -Algorithm SHA256).Hash.ToLowerInvariant()
                }
                $config = Get-Content -LiteralPath (Join-Path $ProjectRoot '.agent-1c/release-e2e.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                $positiveRoot = Get-DevelopPositiveStandRoot -ProjectRoot $ProjectRoot -Config $config
                if ($positiveRoot) {
                    $positiveIdentity = Get-DevelopStandInputIdentity -ProjectRoot $positiveRoot -ExternalBinding $null
                    if ($null -eq $positiveIdentity) { return $null }
                    $ExternalBinding['positiveStandInputIdentity'] = [string]$positiveIdentity.fingerprint
                }
            }
            if (-not $ExternalBinding.complete) { return $null }
            # Version the normalization contract; legacy raw-byte identities require
            # one fresh qualification rather than an unauthenticated cache rewrite.
            $body = [ordered]@{ schemaVersion=2; journey=$Journey; contract=$projection; inputs=$inputs; external=$ExternalBinding }
            $result = [pscustomobject]@{ schemaVersion=2; fingerprint=Get-DevelopE2ECanonicalJsonSha256 -Value $body; inventory=$body }
            if ($positiveIdentity) { $result | Add-Member -NotePropertyName positiveInputIdentity -NotePropertyValue $positiveIdentity }
            return $result
        }
        return Get-DevelopStandInputIdentity -ProjectRoot $ProjectRoot -ExternalBinding $ExternalBinding
    } catch {
        Write-Verbose "Develop E2E input identity unavailable: $($_.Exception.GetType().Name); $($_.FullyQualifiedErrorId)"
        Add-DevelopReuseDiagnostic -Diagnostics $Diagnostics -Code 'INPUT_IDENTITY_UNAVAILABLE' -Inputs @($_.Exception.GetType().Name)
        return $null
    }
}

function Test-DevelopE2ENewerJourneyFailure {
    param([string]$RepositoryRoot, [object]$Report, [string]$CurrentCommit, [string]$CurrentTree, [object]$InputIdentity = $null)
    $common = Get-RepositoryCommonGitDirectory -RepositoryRoot $RepositoryRoot
    $runRoot = Join-Path $common 'itl/runs'
    if (-not (Test-Path -LiteralPath $runRoot -PathType Container)) { return $false }
    foreach ($runFile in @(Get-ChildItem -LiteralPath $runRoot -File -Filter '*-develop-*.json')) {
        try {
            $run = Get-Content -LiteralPath $runFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $journey = [string]$Report.journey
            if ([string]$run.status -ne 'failed' -or [datetime]$run.finishedAt -le [datetime]$Report.finishedAt -or
                @($run.stages | Where-Object { [string]$_.name -eq "develop-e2e-$journey" -and [string]$_.status -eq 'failed' }).Count -eq 0) { continue }
            if (-not (Get-Command Get-WorkflowContinuationEndpoint -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'release-qualification.ps1') }
            if (-not (Get-WorkflowContinuationEndpoint -RepositoryRoot $RepositoryRoot -QualifiedCommit ([string]$run.commit) -CurrentCommit $CurrentCommit -CurrentTree $CurrentTree)) { continue }
            # Older failed journeys lack external facts. They cannot authorize a
            # replay of a pass; only a newer actual execution can resolve them.
            if ($null -eq $InputIdentity -or -not $run.PSObject.Properties['journeyInputIdentities']) { return $true }
            $property = $run.journeyInputIdentities.PSObject.Properties[$journey]
            if (-not $property -or -not $property.Value) { return $true }
            $failedInput = $property.Value
            if ((Get-DevelopE2ECanonicalJsonSha256 -Value $failedInput.inventory) -cne [string]$failedInput.fingerprint) { return $true }
            if ([string]$failedInput.fingerprint -ceq [string]$InputIdentity.fingerprint -or
                (Test-DevelopE2EEquivalentInput -RepositoryRoot $RepositoryRoot -Recorded $failedInput -Current $InputIdentity -QualifiedCommit ([string]$run.commit))) { return $true }
        } catch { return $true }
    }
    return $false
}

function Get-DevelopE2EOwnerInputContinuation {
    param([string]$RepositoryRoot, [string]$QualifiedCommit, [string]$CurrentCommit, [string]$CurrentTree,
        [object]$StaticProof = $null, [switch]$AllowPendingStatic)
    # Called only after exact complete journey input identity and cached report
    # integrity have matched. Keep this rule local to Develop route proof.
    $endpoint = Get-WorkflowContinuationEndpoint -RepositoryRoot $RepositoryRoot -QualifiedCommit $QualifiedCommit -CurrentCommit $CurrentCommit -CurrentTree $CurrentTree
    if (-not $endpoint) { return $null }
    $paths = @(Get-RepositoryGitPathList -RepositoryRoot $RepositoryRoot -Arguments @('diff','--name-only','-z',$QualifiedCommit,$CurrentCommit,'--'))
    $catalog = Get-QualityContractCatalog -RepositoryRoot $RepositoryRoot
    $selection = Resolve-QualityContractsForPaths -Catalog $catalog -Paths $paths
    foreach ($path in @($selection.unknownPaths)) {
        $approvedScope = $false
        foreach ($scope in $catalog.continuationScopes.PSObject.Properties) {
            foreach ($pattern in @($scope.Value)) {
                if (Test-WorkflowContinuationPattern -Path $path -Pattern ([string]$pattern)) { $approvedScope = $true; break }
            }
            if ($approvedScope) { break }
        }
        if (-not $approvedScope) { return $null }
    }
    $targeted = Get-ExactTargetedRunProof -RepositoryRoot $RepositoryRoot -Commit ([string]$endpoint.targetedCommit) -Tree ([string]$endpoint.targetedTree)
    if (-not $targeted) {
        if ($StaticProof -and (Test-WorkflowCurrentStaticProof -Proof $StaticProof -Commit $CurrentCommit -Tree $CurrentTree)) {
            return [pscustomobject]@{
                qualifiedCommit=$QualifiedCommit; currentCommit=$CurrentCommit; currentTree=$CurrentTree
                proofKind='owner-input-static'; paths=$paths; scopes=@('owner-input-exact'); staticProof=$StaticProof
            }
        }
        # Discovery only: the caller must run the current candidate's complete
        # static gate before it can consume this route. Never persist a probe.
        if ($AllowPendingStatic) { return [pscustomobject]@{ proofKind='pending-current-static' } }
        return $null
    }
    return [pscustomobject]@{
        qualifiedCommit=$QualifiedCommit; currentCommit=$CurrentCommit; currentTree=$CurrentTree
        proofKind=[string]$endpoint.kind; targetedCommit=[string]$endpoint.targetedCommit; targetedTree=[string]$endpoint.targetedTree
        sourceDeliveryBase=[string]$endpoint.sourceDeliveryBase; qualifiedQueueHead=[string]$endpoint.qualifiedQueueHead; currentQueueHead=[string]$endpoint.currentQueueHead
        paths=$paths; scopes=@('owner-input-exact'); targetedRunPath=[string]$targeted.path
        targetedRunSha256=[string]$targeted.sha256; targetedFinishedAt=[string]$targeted.run.finishedAt
    }
}

function Get-DevelopE2EAncestorQualification {
    param([string]$RepositoryRoot, [string]$Tree, [string]$Journey, [string]$IdentitySha256, [string]$StandStateSha256, [object]$InputIdentity,
        [object]$StaticProof = $null, [switch]$AllowPendingStatic,
        [AllowNull()][Collections.Generic.List[object]]$Diagnostics=$null)
    if ($null -eq $InputIdentity -or [string]$InputIdentity.fingerprint -cnotmatch '^[a-f0-9]{64}$' -or
        (Get-DevelopE2ECanonicalJsonSha256 -Value $InputIdentity.inventory) -cne [string]$InputIdentity.fingerprint -or
        -not $InputIdentity.inventory.external.complete -or [string]$InputIdentity.inventory.journey -cne $Journey) { return $null }
    if (-not (Get-Command Get-WorkflowContinuationProof -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'release-qualification.ps1') }
    $current = (Invoke-RepositoryGit -RepositoryRoot $RepositoryRoot -Arguments @('rev-parse','HEAD')).stdout.Trim()
    $common = Get-RepositoryCommonGitDirectory -RepositoryRoot $RepositoryRoot
    $root = Join-Path $common 'itl/develop-e2e-qualifications'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        Add-DevelopReuseDiagnostic -Diagnostics $Diagnostics -Code 'NO_PRIOR_JOURNEY_PROOF'
        return $null
    }
    $seenJourney=$false
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter manifest.json | Sort-Object LastWriteTimeUtc -Descending)) {
        $qualifiedCommit=''
        try {
            $manifest = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$manifest.identity.journey -ne $Journey) { continue }
            $seenJourney=$true
            if ([int]$manifest.schemaVersion -ne 2 -or [string]$manifest.kind -ne 'itl-develop-e2e-qualification-cache' -or
                (Get-DevelopE2ECanonicalJsonSha256 -Value $manifest.inputIdentity.inventory) -cne [string]$manifest.inputIdentity.fingerprint) {
                Add-DevelopReuseDiagnostic -Diagnostics $Diagnostics -Code 'MANIFEST_INVALID'; continue
            }
            $reportPath = Join-Path $file.DirectoryName 'route-report.json'
            if ((Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$manifest.identity.reportSha256) {
                Add-DevelopReuseDiagnostic -Diagnostics $Diagnostics -Code 'REPORT_SHA_MISMATCH'; continue
            }
            $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $qualifiedCommit=[string]$report.repository.commit
            if ([string]$manifest.inputIdentity.fingerprint -cne [string]$InputIdentity.fingerprint -and
                -not (Test-DevelopE2EEquivalentInput -RepositoryRoot $RepositoryRoot -Recorded $manifest.inputIdentity -Current $InputIdentity -QualifiedCommit $qualifiedCommit)) {
                Add-DevelopReuseDiagnostic -Diagnostics $Diagnostics -Code 'INPUTS_NOT_EQUIVALENT' -Commit $qualifiedCommit -Inputs @(Get-DevelopInputDifferenceNames -Recorded $manifest.inputIdentity -Current $InputIdentity)
                continue
            }
            $qualifiedTree = (Invoke-RepositoryGit -RepositoryRoot $RepositoryRoot -Arguments @('rev-parse',"$([string]$report.repository.commit)^{tree}")).stdout.Trim()
            if ($qualifiedTree -cne [string]$report.repository.tree -or $qualifiedTree -cne [string]$manifest.identity.tree) {
                Add-DevelopReuseDiagnostic -Diagnostics $Diagnostics -Code 'PROOF_TREE_MISMATCH' -Commit $qualifiedCommit; continue
            }
            # The complete owner fingerprint above binds current source and
            # environment. Keep the historical envelope identity: its raw stand
            # configuration also included admission receipts, which may advance.
            if (-not (Test-DevelopE2ERouteReport -Path $reportPath -Tree ([string]$report.repository.tree) -Journey $Journey -IdentitySha256 ([string]$report.identitySha256) -StandStateSha256 $StandStateSha256)) {
                Add-DevelopReuseDiagnostic -Diagnostics $Diagnostics -Code 'ROUTE_OR_STAND_INVALID' -Commit $qualifiedCommit; continue
            }
            $continuation = Get-WorkflowContinuationProof -RepositoryRoot $RepositoryRoot -QualifiedCommit ([string]$report.repository.commit) -CurrentCommit $current -CurrentTree $Tree
            if (-not $continuation -and [int]$InputIdentity.inventory.contract.schemaVersion -eq 2) {
                $continuation = Get-DevelopE2EOwnerInputContinuation -RepositoryRoot $RepositoryRoot -QualifiedCommit ([string]$report.repository.commit) -CurrentCommit $current -CurrentTree $Tree -StaticProof $StaticProof -AllowPendingStatic:$AllowPendingStatic
            }
            if (-not $continuation) {
                Add-DevelopReuseDiagnostic -Diagnostics $Diagnostics -Code 'LINEAGE_OR_CURRENT_STATIC_UNPROVEN' -Commit $qualifiedCommit; continue
            }
            if (Test-DevelopE2ENewerJourneyFailure -RepositoryRoot $RepositoryRoot -Report $report -CurrentCommit $current -CurrentTree $Tree -InputIdentity $InputIdentity) {
                Add-DevelopReuseDiagnostic -Diagnostics $Diagnostics -Code 'NEWER_APPLICABLE_FAILURE' -Commit $qualifiedCommit; continue
            }
            return [pscustomobject]@{ reportPath=$reportPath; report=$report; sha256=[string]$manifest.identity.reportSha256; continuation=$continuation; inputIdentity=$InputIdentity }
        } catch { Add-DevelopReuseDiagnostic -Diagnostics $Diagnostics -Code 'PROOF_UNREADABLE_OR_INVALID' -Commit $qualifiedCommit; continue }
    }
    if(-not $seenJourney) { Add-DevelopReuseDiagnostic -Diagnostics $Diagnostics -Code 'NO_PRIOR_JOURNEY_PROOF' }
    return $null
}

function Get-DevelopE2EChangedPaths {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [string]$BaseRef = "",
        [string[]]$ChangedPath = @()
    )

    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($path in @($ChangedPath)) {
        if ($path) { $paths.Add(([string]$path).Replace('\', '/')) | Out-Null }
    }
    if ($BaseRef) {
        foreach ($path in @(Get-RepositoryGitPathList -RepositoryRoot $RepositoryRoot -Arguments @("diff", "--name-only", "--diff-filter=ACDMRT", "-z", "$BaseRef...HEAD", "--"))) {
            $paths.Add(([string]$path).Replace('\', '/')) | Out-Null
        }
    }
    return @($paths | Sort-Object -Unique)
}

function Resolve-DevelopE2EJourneyPlan {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [string]$BaseRef = "",
        [string[]]$ChangedPath = @(),
        [object]$Catalog = $null
    )

    $root = [IO.Path]::GetFullPath($RepositoryRoot)
    if ($null -eq $Catalog) { $Catalog = Get-QualityContractCatalog -RepositoryRoot $root }
    [void](Test-QualityContractCatalog -RepositoryRoot $root -Catalog $Catalog)
    return Resolve-DevelopE2EJourneyPlanCore -RepositoryRoot $root -BaseRef $BaseRef -ChangedPath $ChangedPath -Catalog $Catalog
}

function Resolve-DevelopE2EJourneyPlanCore {
    # Internal selection over the catalog already validated by its calling owner.
    param([string]$RepositoryRoot,[string]$BaseRef='', [string[]]$ChangedPath=@(),[object]$Catalog)
    $root=[IO.Path]::GetFullPath($RepositoryRoot)
    $paths = @(Get-DevelopE2EChangedPaths -RepositoryRoot $root -BaseRef $BaseRef -ChangedPath $ChangedPath)
    if ($paths.Count -eq 0) {
        return [pscustomobject][ordered]@{
            schemaVersion = 1
            kind = "itl-develop-e2e-journey-plan"
            reason = "empty-range-fail-closed"
            paths = @()
            contracts = @()
            journeys = @($Catalog.developJourneys.names | ForEach-Object { [string]$_ })
            unknownPaths = @()
            matchedFullPaths = @()
        }
    }

    $selection = Resolve-QualityContractsForPaths -Catalog $Catalog -Paths $paths
    $contractIds = @($selection.contracts | ForEach-Object { [string]$_.id } | Sort-Object -Unique)
    $unknownPaths = @($selection.unknownPaths | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    $fullPathSet = @($Catalog.developJourneys.fullPaths | ForEach-Object { ([string]$_).Replace('\', '/') })
    $matchedFullPaths = @($paths | Where-Object { $_ -in $fullPathSet } | Sort-Object -Unique)
    $journeys = New-Object System.Collections.Generic.List[string]
    $reason = ""

    if ($unknownPaths.Count -gt 0) {
        throw "QUALITY_OWNER_MISSING: $($unknownPaths -join ', ')"
    } elseif (@($paths | Where-Object { $_ -like "tests/pester/*.Tests.ps1" }).Count -eq $paths.Count) {
        $reason = "direct-tests-only"
    } else {
        foreach ($name in @($Catalog.developJourneys.names)) {
            $routeContracts = @($Catalog.developJourneys.routes.$name.contracts | ForEach-Object { [string]$_ })
            # Pester contracts still select static tests; their files are never
            # executed by the native journey. Mixed diffs keep runtime routing.
            $routePaths=@($paths | Where-Object { $_ -notlike 'tests/pester/*.Tests.ps1' -and
                -not (Test-DevelopJourneyUnaffectedPath -RepositoryRoot $root -Path $_ -BaseRef $BaseRef -Journey $name) })
            $routeIds=if($routePaths.Count){@((Resolve-QualityContractsForPaths -Catalog $Catalog -Paths $routePaths).contracts | ForEach-Object {[string]$_.id})}else{@()}
            if (@($routePaths | Where-Object {$_ -in $fullPathSet}).Count -gt 0 -or
                @($routeIds | Where-Object { $_ -in $routeContracts }).Count -gt 0) { $journeys.Add([string]$name) | Out-Null }
        }
        $reason = if ($matchedFullPaths.Count) { 'develop-orchestration-full-path' } elseif ($journeys.Count -gt 0) { "quality-contract-route" } else { "no-develop-journey-route" }
    }

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        kind = "itl-develop-e2e-journey-plan"
        reason = $reason
        paths = $paths
        contracts = $contractIds
        journeys = @($journeys)
        unknownPaths = $unknownPaths
        matchedFullPaths = $matchedFullPaths
    }
}

function Get-DevelopE2ECanonicalJsonSha256 {
    param([Parameter(Mandatory = $true)][object]$Value)

    # Pipeline enumeration loses an empty collection and unwraps a singleton.
    $json = ConvertTo-Json -InputObject $Value -Depth 16 -Compress
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Get-DevelopE2EStandRepositories {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $root = [IO.Path]::GetFullPath($ProjectRoot)
    $configPath = Join-Path $root ".agent-1c\release-e2e.json"
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw "Develop E2E stand config is missing: $configPath" }
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $developRoot = [IO.Path]::GetFullPath([string]$config.developWorktreePath)
    $repositories = @(
        [pscustomobject]@{ path = $root; role = "master" },
        [pscustomobject]@{ path = $developRoot; role = "develop" }
    )
    $positiveRoot = Get-DevelopPositiveStandRoot -ProjectRoot $root -Config $config
    if ($positiveRoot) {
        $positive = Get-Content -LiteralPath (Join-Path $positiveRoot '.agent-1c/release-e2e.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $repositories += @([pscustomobject]@{path=$positiveRoot;role='positiveMaster'},
            [pscustomobject]@{path=[IO.Path]::GetFullPath([string]$positive.developWorktreePath);role='positiveDevelop'})
    }
    return $repositories
}

function Get-DevelopE2EStandContentState {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [string]$MasterCommit = "HEAD",
        [string]$DevelopCommit = "HEAD",
        [switch]$RequireClean
    )

    $state = [ordered]@{ schemaVersion = 2; repositories = @() }
    foreach ($entry in @(Get-DevelopE2EStandRepositories -ProjectRoot $ProjectRoot)) {
        $path = [string]$entry.path
        $commit = if ([string]$entry.role -eq "master") { $MasterCommit } elseif ([string]$entry.role -eq 'develop') { $DevelopCommit } else { 'HEAD' }
        $resolvedCommit = (& git -C $path rev-parse $commit 2>$null).Trim()
        if ($LASTEXITCODE -ne 0 -or $resolvedCommit -notmatch '^[a-f0-9]{40}$') { throw "Develop E2E cannot resolve $($entry.role) stand commit '$commit': $path" }
        $tracked = @(& git -C $path status --porcelain --untracked-files=no 2>$null)
        if ($LASTEXITCODE -ne 0) { throw "Develop E2E cannot inspect $($entry.role) stand state: $path" }
        $trackedClean = $tracked.Count -eq 0
        if ($RequireClean -and -not $trackedClean) { throw "Develop E2E $($entry.role) stand has tracked changes: $path" }
        $content = [ordered]@{}
        foreach ($repoPath in @("src/cf", "src/cfe", "tests/features")) {
            $treeEntry = (@(& git -C $path ls-tree -d $resolvedCommit -- $repoPath 2>$null) -join [Environment]::NewLine).Trim()
            if ($LASTEXITCODE -ne 0) { throw "Develop E2E cannot inspect $($entry.role) stand content '$repoPath' at '$resolvedCommit': $path" }
            $objectId = ""
            if ($treeEntry) {
                if ($treeEntry -notmatch '^040000\s+tree\s+([a-f0-9]{40})\t') {
                    throw "Develop E2E received an invalid $($entry.role) stand tree entry for '$repoPath' at '$resolvedCommit': $path"
                }
                $objectId = [string]$Matches[1]
            }
            $content[$repoPath] = $objectId
        }
        $state.repositories += [ordered]@{
            role = [string]$entry.role
            path = $path.ToLowerInvariant()
            trackedClean = $trackedClean
            content = $content
        }
    }
    return $state
}

function Get-DevelopE2EStandStateSha256 {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    return Get-DevelopE2ECanonicalJsonSha256 -Value (Get-DevelopE2EStandContentState -ProjectRoot $ProjectRoot)
}

function Test-DevelopE2ELegacyStandContinuation {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RecordedSha256
    )

    if ($RecordedSha256 -notmatch '^[a-f0-9]{64}$') { return $false }
    try {
        $repositories = @(Get-DevelopE2EStandRepositories -ProjectRoot $ProjectRoot)
        $currentState = Get-DevelopE2EStandContentState -ProjectRoot $ProjectRoot -RequireClean
        $currentSha256 = Get-DevelopE2ECanonicalJsonSha256 -Value $currentState
        $masterHeads = @(& git -C ([string]$repositories[0].path) reflog --format=%H -n 64 2>$null | Where-Object { $_ -match '^[a-f0-9]{40}$' } | Select-Object -Unique)
        $developHeads = @(& git -C ([string]$repositories[1].path) reflog --format=%H -n 128 2>$null | Where-Object { $_ -match '^[a-f0-9]{40}$' } | Select-Object -Unique)
        foreach ($masterHead in $masterHeads) {
            foreach ($developHead in $developHeads) {
                $legacyState = [ordered]@{ schemaVersion = 1; repositories = @(
                    [ordered]@{ role = "master"; path = ([string]$repositories[0].path).ToLowerInvariant(); head = [string]$masterHead; trackedClean = $true },
                    [ordered]@{ role = "develop"; path = ([string]$repositories[1].path).ToLowerInvariant(); head = [string]$developHead; trackedClean = $true }
                ) }
                if ((Get-DevelopE2ECanonicalJsonSha256 -Value $legacyState) -ne $RecordedSha256) { continue }
                $recordedState = Get-DevelopE2EStandContentState -ProjectRoot $ProjectRoot -MasterCommit ([string]$masterHead) -DevelopCommit ([string]$developHead)
                return (Get-DevelopE2ECanonicalJsonSha256 -Value $recordedState) -eq $currentSha256
            }
        }
    } catch {
        return $false
    }
    return $false
}

function New-DevelopE2ERouteReport {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][ValidateSet("upgrade", "fresh")][string]$Journey,
        [Parameter(Mandatory = $true)][string]$IdentitySha256,
        [Parameter(Mandatory = $true)][string]$StandStateSha256,
        [Parameter(Mandatory = $true)][object]$JourneyResult
    )

    $commit = (& git -C $RepositoryRoot rev-parse HEAD 2>$null).Trim()
    $tree = (& git -C $RepositoryRoot rev-parse 'HEAD^{tree}' 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[a-f0-9]{40}$' -or $tree -notmatch '^[a-f0-9]{40}$') {
        throw "Cannot resolve candidate identity for Develop E2E route report."
    }
    if ($IdentitySha256 -notmatch '^[a-f0-9]{64}$') { throw "Invalid Develop E2E identity SHA256: $IdentitySha256" }
    if ($StandStateSha256 -notmatch '^[a-f0-9]{64}$') { throw "Invalid Develop E2E stand-state SHA256: $StandStateSha256" }
    if ($Journey -notin @($Plan.journeys | ForEach-Object { [string]$_ }) -or [string]$JourneyResult.name -ne $Journey -or [string]$JourneyResult.status -ne "passed") {
        throw "Develop E2E route report requires one passed result for requested journey '$Journey'."
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        kind = "itl-develop-e2e-route-report"
        status = "passed"
        repository = [ordered]@{ commit = $commit; tree = $tree }
        identitySha256 = $IdentitySha256
        standStateSha256 = $StandStateSha256
        journey = $Journey
        plan = $Plan
        planSha256 = Get-DevelopE2ECanonicalJsonSha256 -Value $Plan
        result = $JourneyResult
        finishedAt = [DateTime]::UtcNow.ToString("o")
    }
}

function Test-DevelopE2ERouteReport {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Tree,
        [Parameter(Mandatory = $true)][ValidateSet("upgrade", "fresh")][string]$Journey,
        [Parameter(Mandatory = $true)][string]$IdentitySha256,
        [Parameter(Mandatory = $true)][string]$StandStateSha256,
        [string]$ProjectRoot = ""
    )

    if ($Tree -notmatch '^[a-f0-9]{40}$' -or $IdentitySha256 -notmatch '^[a-f0-9]{64}$' -or $StandStateSha256 -notmatch '^[a-f0-9]{64}$' -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        if (-not $ProjectRoot) {
            $projectRootVariable = Get-Variable -Name E2EProjectRoot -Scope Script -ErrorAction SilentlyContinue
            if ($projectRootVariable -and [string]$projectRootVariable.Value) { $ProjectRoot = [string]$projectRootVariable.Value }
        }
        $report = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        $standMatches = [string]$report.standStateSha256 -eq $StandStateSha256 -or
            ($ProjectRoot -and (Test-DevelopE2ELegacyStandContinuation -ProjectRoot $ProjectRoot -RecordedSha256 ([string]$report.standStateSha256)))
        if ([int]$report.schemaVersion -ne 1 -or [string]$report.kind -ne "itl-develop-e2e-route-report" -or
            [string]$report.status -ne "passed" -or [string]$report.repository.tree -ne $Tree -or
            [string]$report.identitySha256 -ne $IdentitySha256 -or -not $standMatches -or [string]$report.journey -ne $Journey -or
            [string]$report.plan.kind -ne "itl-develop-e2e-journey-plan" -or
            [string]$report.planSha256 -ne (Get-DevelopE2ECanonicalJsonSha256 -Value $report.plan)) { return $false }
        return $Journey -in @($report.plan.journeys | ForEach-Object { [string]$_ }) -and
            [string]$report.result.name -eq $Journey -and [string]$report.result.status -eq "passed"
    } catch { return $false }
}

function Get-DevelopE2EQualificationCachePath {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Tree,
        [Parameter(Mandatory = $true)][ValidateSet("upgrade", "fresh")][string]$Journey,
        [Parameter(Mandatory = $true)][string]$IdentitySha256
    )

    if ($Tree -notmatch '^[a-f0-9]{40}$') { throw "Invalid Develop E2E qualification tree: $Tree" }
    if ($IdentitySha256 -notmatch '^[a-f0-9]{64}$') { throw "Invalid Develop E2E identity SHA256: $IdentitySha256" }
    $commonDirectory = Get-RepositoryCommonGitDirectory -RepositoryRoot $RepositoryRoot
    return Join-Path $commonDirectory ("itl\develop-e2e-qualifications\$Tree\$IdentitySha256\$Journey")
}

function Save-DevelopE2EQualification {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$ReportPath,
        [Parameter(Mandatory = $true)][string]$Tree,
        [Parameter(Mandatory = $true)][ValidateSet("upgrade", "fresh")][string]$Journey,
        [Parameter(Mandatory = $true)][string]$IdentitySha256,
        [Parameter(Mandatory = $true)][string]$StandStateSha256,
        [object]$InputIdentity = $null
    )

    if (-not (Test-DevelopE2ERouteReport -Path $ReportPath -Tree $Tree -Journey $Journey -IdentitySha256 $IdentitySha256 -StandStateSha256 $StandStateSha256)) {
        throw "Develop E2E route report is incomplete, corrupt, or does not match tree/identity/journey."
    }
    $report = Get-Content -LiteralPath $ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $target = Get-DevelopE2EQualificationCachePath -RepositoryRoot $RepositoryRoot -Tree $Tree -Journey $Journey -IdentitySha256 $IdentitySha256
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    $token = [guid]::NewGuid().ToString("N")
    $temporaryReport = Join-Path $target ("route-report.json.$token.tmp")
    $temporaryManifest = Join-Path $target ("manifest.json.$token.tmp")
    try {
        Copy-Item -LiteralPath $ReportPath -Destination $temporaryReport -Force
        $reportSha256 = (Get-FileHash -LiteralPath $temporaryReport -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifest = [ordered]@{
            schemaVersion = $(if ($null -eq $InputIdentity) { 1 } else { 2 })
            kind = "itl-develop-e2e-qualification-cache"
            identity = [ordered]@{
                tree = $Tree
                identitySha256 = $IdentitySha256
                standStateSha256 = $StandStateSha256
                journey = $Journey
                reportKind = [string]$report.kind
                reportSha256 = $reportSha256
                planSha256 = [string]$report.planSha256
            }
            savedAt = [DateTime]::UtcNow.ToString("o")
        }
        if ($null -ne $InputIdentity) { $manifest['inputIdentity'] = $InputIdentity }
        [IO.File]::WriteAllText($temporaryManifest, (($manifest | ConvertTo-Json -Depth 20) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryReport -Destination (Join-Path $target "route-report.json") -Force
        Move-Item -LiteralPath $temporaryManifest -Destination (Join-Path $target "manifest.json") -Force
    } finally {
        Remove-Item -LiteralPath $temporaryReport, $temporaryManifest -Force -ErrorAction SilentlyContinue
    }
    return $target
}

function Restore-DevelopE2EQualification {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$Tree,
        [Parameter(Mandatory = $true)][ValidateSet("upgrade", "fresh")][string]$Journey,
        [Parameter(Mandatory = $true)][string]$IdentitySha256,
        [Parameter(Mandatory = $true)][string]$StandStateSha256
    )

    $source = Get-DevelopE2EQualificationCachePath -RepositoryRoot $RepositoryRoot -Tree $Tree -Journey $Journey -IdentitySha256 $IdentitySha256
    $manifestPath = Join-Path $source "manifest.json"
    $reportPath = Join-Path $source "route-report.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or -not (Test-Path -LiteralPath $reportPath -PathType Leaf)) { return $false }
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([int]$manifest.schemaVersion -notin @(1,2) -or [string]$manifest.kind -ne "itl-develop-e2e-qualification-cache" -or
            [string]$manifest.identity.tree -ne $Tree -or [string]$manifest.identity.reportKind -ne "itl-develop-e2e-route-report" -or
            [string]$manifest.identity.identitySha256 -ne $IdentitySha256 -or [string]$manifest.identity.journey -ne $Journey -or
            [string]$manifest.identity.standStateSha256 -ne $StandStateSha256 -or
            (Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne ([string]$manifest.identity.reportSha256).ToLowerInvariant() -or
            -not (Test-DevelopE2ERouteReport -Path $reportPath -Tree $Tree -Journey $Journey -IdentitySha256 $IdentitySha256 -StandStateSha256 $StandStateSha256)) { return $false }
        $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$manifest.identity.planSha256 -ne [string]$report.planSha256) { return $false }
        $current = (Invoke-RepositoryGit -RepositoryRoot $RepositoryRoot -Arguments @('rev-parse','HEAD')).stdout.Trim()
        if (Test-DevelopE2ENewerJourneyFailure -RepositoryRoot $RepositoryRoot -Report $report -CurrentCommit $current -CurrentTree $Tree) { return $false }

        $parent = Split-Path -Parent $OutputPath
        if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        $temporary = $OutputPath + "." + [guid]::NewGuid().ToString("N") + ".tmp"
        try {
            Copy-Item -LiteralPath $reportPath -Destination $temporary -Force
            Move-Item -LiteralPath $temporary -Destination $OutputPath -Force
        } finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        return $true
    } catch { return $false }
}

function Write-DevelopQualification {
    param([string]$Commit, [string]$Tree, [string]$ReportPath, [string]$IdentitySha256, [object]$JourneyRecords, [object]$Plan)
    if (-not (Test-Path -LiteralPath $qualificationFullPath -PathType Leaf)) { throw "Develop qualification requires reusable Full evidence." }
    $root = Split-Path -Parent $developQualificationFullPath
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $canonicalReport = Join-Path $root "develop-e2e-summary.json"
    # A caller may already write the combined report in the qualification root.
    # Preserve those exact bytes instead of asking Copy-Item to replace itself.
    if (-not [IO.Path]::GetFullPath($ReportPath).Equals([IO.Path]::GetFullPath($canonicalReport), [StringComparison]::OrdinalIgnoreCase)) {
        Copy-Item -LiteralPath $ReportPath -Destination $canonicalReport -Force
    }
    $qualification = [ordered]@{
        schemaVersion = 4
        kind = "itl-workflow-develop-qualification"
        status = "passed"
        reusable = $true
        repository = [ordered]@{ commit = $Commit; tree = $Tree; evidenceCommit = $Commit; worktreeClean = $true }
        fullQualificationSha256 = (Get-FileHash -LiteralPath $qualificationFullPath -Algorithm SHA256).Hash.ToLowerInvariant()
        e2e = [ordered]@{ path = Get-RelativeRepositoryPath -Path $canonicalReport -Root $repoRoot; sha256 = (Get-FileHash -LiteralPath $canonicalReport -Algorithm SHA256).Hash.ToLowerInvariant() }
        identitySha256 = $IdentitySha256
        plan = $Plan
        journeys = $JourneyRecords
        finishedAt = [DateTime]::UtcNow.ToString("o")
    }
    [IO.File]::WriteAllText($developQualificationFullPath, (($qualification | ConvertTo-Json -Depth 20) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    return $qualification
}
