function Get-SourceHostTestPython {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$RepositoryRoot,
        [Parameter(Mandatory=$true)][ValidateSet('Native','Linux','CodeChecker','BookStack','Mantis','Sppr','ChatGpt','OnDemandGo')][string]$Component
    )
    # Source verification owns these disposable, checkout-local environments.
    # Installed host runtimes and their lifecycle remain owned by the installer.
    $root=[IO.Path]::GetFullPath($RepositoryRoot)
    $runtimeRoot=Join-Path $root 'build/host-test-runtime'
    New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
    $configPath=Join-Path $runtimeRoot ($Component.ToLowerInvariant()+'.'+[guid]::NewGuid().ToString('N')+'.config.json')
    $config=@{schemaVersion=1;stateRoot=(Join-Path $runtimeRoot ($Component.ToLowerInvariant()+'-state'))}
    if($env:ITL_SOURCE_TEST_PYTHON){$config.pythonPath=$env:ITL_SOURCE_TEST_PYTHON}
    if($Component -eq 'Sppr' -and $env:SPPR_TEST_PYTHON){$config.pythonPath=$env:SPPR_TEST_PYTHON}
    try {
    [IO.File]::WriteAllText($configPath,($config | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    & {
        . (Join-Path $root 'vibecoding1c-mcp-host/install-vibecoding1c-mcp-host.ps1') -Action status -ConfigPath $configPath *> $null
        # Reuse the installer owner's component-local preparation lease. Test
        # bodies run after release; other components retain independent leases.
        $lease=Enter-McpHostMaintenanceLock -Config $config -Operation ('source-test-'+$Component) -WaitSeconds 180
        if(-not $lease.acquired){throw "Source $Component preparation is still active. Wait for it to finish and repeat the same component test; its environment was not changed."}
        try {
        $bootstrap=Resolve-PythonExecutable -Config $config
        $probeCode='import json,sys; print(json.dumps(dict(executable=sys.executable,version=list(sys.version_info[:3]),prefix=sys.prefix,base_prefix=sys.base_prefix)))'
        $probe=Invoke-ProcessWithTimeout -FilePath $bootstrap -Arguments @('-I','-S','-B','-X','utf8','-c',$probeCode) -TimeoutSec 30
        if($probe.exitCode -ne 0){throw "Source Python bootstrap probe failed: $($probe.lines -join '; '). Configure ITL_SOURCE_TEST_PYTHON with a working absolute interpreter and repeat the same component test."}
        $base=($probe.lines -join "`n") | ConvertFrom-Json
        if([int]$base.version[0] -ne 3){throw 'Source host tests require Python 3. Configure ITL_SOURCE_TEST_PYTHON and repeat the same component test.'}
        $requirements=if($Component -eq 'Sppr'){Join-Path $root 'vibecoding1c-mcp-host/sppr-mcp/requirements.txt'}elseif($Component -eq 'BookStack'){Join-Path $root 'vibecoding1c-mcp-host/bookstack-product-docs-mcp/requirements.txt'}else{''}
        $requiredPackages=@(if($Component -eq 'BookStack'){'snowballstemmer';'httpx';'numpy'})
        $dependencyHash=if($requirements){(Get-FileHash -LiteralPath $requirements -Algorithm SHA256).Hash.ToLowerInvariant()}else{'stdlib-only'}
        $identity=[ordered]@{component=$Component;bootstrap=[string]$base.executable;bootstrapSha256=(Get-FileHash -LiteralPath $base.executable -Algorithm SHA256).Hash.ToLowerInvariant();version=@($base.version);requirementsSha256=$dependencyHash;requiredPackages=@($requiredPackages)}
        $identityJson=$identity | ConvertTo-Json -Compress
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$key=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identityJson))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
        $generation=Join-Path $runtimeRoot ($Component.ToLowerInvariant()+'-'+$key.Substring(0,20))
        $python=Join-Path $generation 'Scripts/python.exe'
        $external=$Component -eq 'Sppr' -and [bool]$env:SPPR_TEST_PYTHON
        if($external){$python=[IO.Path]::GetFullPath($env:SPPR_TEST_PYTHON)}
        if(-not (Test-Path -LiteralPath $python -PathType Leaf)){
            if($external){throw "Configured SPPR_TEST_PYTHON '$python' is missing. Restore that isolated environment or remove the override and repeat the SPPR component test."}
            $arguments=@('-I','-S','-B','-X','utf8','-m','venv')
            if(-not $requirements){$arguments+='--without-pip'}
            $arguments+=$generation
            $created=Invoke-ProcessWithTimeout -FilePath ([string]$base.executable) -Arguments $arguments -TimeoutSec 180
            if($created.exitCode -ne 0){throw "Source $Component venv preparation failed: $($created.lines -join '; '). Restore bootstrap venv support and repeat the same component test; other environments were not changed."}
        }
        if($Component -eq 'BookStack'){
            # Source tests fake the model/MCP SDK but exercise these real imports.
            # Constraints stay authoritative in the component requirements file.
            $selected=@(Get-Content -LiteralPath $requirements -Encoding UTF8 | Where-Object {$_ -match '^(snowballstemmer|httpx|numpy)([<>=!~]|$)'})
            if($selected.Count -ne $requiredPackages.Count){throw 'BookStack source-test dependencies differ from the production requirements. Review its real imports and repeat this component preparation.'}
            $requirements=Join-Path $generation 'source-requirements.txt'
            [IO.File]::WriteAllText($requirements,($selected -join "`n"),[Text.UTF8Encoding]::new($false))
        }
        $receipt=Join-Path $generation 'prepared.json'
        if($requirements -and -not $external -and -not (Test-Path -LiteralPath $receipt -PathType Leaf)){
            $installed=Invoke-ProcessWithTimeout -FilePath $python -Arguments @('-I','-X','utf8','-m','pip','install','--disable-pip-version-check','-r',$requirements) -TimeoutSec 600
            if($installed.exitCode -ne 0){throw "Source $Component dependencies could not be prepared: $($installed.lines -join '; '). Restore package connectivity and repeat the same component test; its incomplete venv is retained."}
        }
        $verified=Invoke-ProcessWithTimeout -FilePath $python -Arguments @('-I','-B','-X','utf8','-c',$probeCode) -TimeoutSec 30
        if($verified.exitCode -ne 0){throw "Source $Component isolated Python probe failed. Restore its venv and repeat the same component test."}
        $actual=($verified.lines -join "`n") | ConvertFrom-Json
        if([string]$actual.prefix -ceq [string]$actual.base_prefix){throw "Source $Component test runtime '$python' is not isolated. Use a venv; installed/global Python was not modified."}
        if($requirements){
            $validateRequirements={
                $check=Invoke-ProcessWithTimeout -FilePath $python -Arguments @('-I','-X','utf8','-m','pip','check') -TimeoutSec 30
                if($check.exitCode -ne 0){throw "Source $Component dependency check failed: $($check.lines -join '; '). Repair this component environment and repeat its test."}
                $versionsCode='import sys,importlib.metadata as m; from pip._vendor.packaging.requirements import Requirement; rows=[Requirement(s.strip()) for s in open(sys.argv[1],encoding="utf-8-sig") if s.strip() and not s.lstrip().startswith("#")]; bad=[str(r)+" installed="+m.version(r.name) for r in rows if (not r.marker or r.marker.evaluate()) and not r.specifier.contains(m.version(r.name),prereleases=True)]; assert not bad, "; ".join(bad)'
                $versions=Invoke-ProcessWithTimeout -FilePath $python -Arguments @('-I','-X','utf8','-c',$versionsCode,$requirements) -TimeoutSec 30
                if($versions.exitCode -ne 0){throw "Source $Component package versions differ from its requirements: $($versions.lines -join '; '). Repair this component environment and repeat its test."}
                $importCode=if($Component -eq 'Sppr'){'import fastmcp,mcp,numpy,tzdata'}else{'import snowballstemmer,httpx,numpy'}
                $imports=Invoke-ProcessWithTimeout -FilePath $python -Arguments @('-I','-X','utf8','-c',$importCode) -TimeoutSec 30
                if($imports.exitCode -ne 0){throw "Source $Component imports failed: $($imports.lines -join '; '). Repair this component environment and repeat its test."}
            }
            try { & $validateRequirements } catch {
                if($external){throw}
                $repair=Invoke-ProcessWithTimeout -FilePath $python -Arguments @('-I','-X','utf8','-m','pip','install','--disable-pip-version-check','-r',$requirements) -TimeoutSec 600
                if($repair.exitCode -ne 0){throw "Source $Component dependency repair failed: $($repair.lines -join '; '). Restore package connectivity and repeat this component test; its own venv is retained."}
                & $validateRequirements
            }
        }
        if(-not $external){[IO.File]::WriteAllText($receipt,$identityJson,[Text.UTF8Encoding]::new($false))}
        return [IO.Path]::GetFullPath($python)
        } finally {Exit-McpHostMaintenanceLock -Lease $lease}
    }
    } finally {[IO.File]::Delete($configPath)}
}
