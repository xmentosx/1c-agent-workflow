. (Join-Path $PSScriptRoot 'SourceDeliveryPlan.TestSupport.ps1')
function New-ScenarioPlanFixture {
        $f=New-IncrementalPlanFixture
        $actual=Get-QualityContractCatalog $RepoRoot
        $f.catalog.developJourneys | Add-Member -NotePropertyName scenarios -NotePropertyValue $actual.developJourneys.scenarios
        $rules=@([pscustomobject]@{path='runtime.ps1';functions=[pscustomobject]@{
            'Change-Update'=@('upgrade.update');'Change-Export'=@('fresh.stale-export');'Change-Mcp'=@('upgrade.update','fresh.install')}})
        $f.catalog.developJourneys | Add-Member -NotePropertyName scenarioInputs -NotePropertyValue $rules
        [IO.File]::WriteAllText((Join-Path $f.root 'runtime.ps1'),"function Change-Update {'v1'}`nfunction Change-Export {'v1'}`nfunction Change-Mcp {'v1'}`n")
        [IO.File]::WriteAllText((Join-Path $f.stand '.agent-1c/project.json'),'{"aiRules":{"tools":["kilocode"]}}')
        [IO.File]::WriteAllText((Join-Path $f.root 'tests/quality-contracts.json'),($f.catalog|ConvertTo-Json -Depth 24))
        & git -C $f.root add --all; & git -C $f.root commit --quiet -m 'scenario baseline'
        $f.base=(& git -C $f.root rev-parse HEAD).Trim()
        $script:Root=$f.root;$script:GateScript=Join-Path $f.root 'scripts/check.ps1'
        $script:E2EProjectRoot=$f.stand;$script:AiRulesSource=$f.rules;$script:AgentTarget='kilocode'
        foreach($relative in @('build/third-party/vanessa-automation/1-r1/archive.zip','build/third-party/client-mcp/client.cfe','tools/itl-ondemand-mcp/build/mcp.exe')) {
            $cache=Join-Path $f.root $relative;[void][IO.Directory]::CreateDirectory((Split-Path $cache));Copy-Item -LiteralPath $f.artifact -Destination $cache
        }
        [IO.File]::AppendAllText((Join-Path $f.root '.git/info/exclude'),"`n/build/`n/tools/itl-ondemand-mcp/build/`n")
        Save-IncrementalJourneyProofs $f
        return $f
    }
    function Set-ScenarioFixtureChange {
        param($Fixture,$Function)
        $path=Join-Path $Fixture.root 'runtime.ps1'
        $text=[IO.File]::ReadAllText($path).Replace("function $Function {'v1'}","function $Function {'v2'}")
        [IO.File]::WriteAllText($path,$text)
        & git -C $Fixture.root add -- runtime.ps1; & git -C $Fixture.root commit --quiet -m $Function
    }
