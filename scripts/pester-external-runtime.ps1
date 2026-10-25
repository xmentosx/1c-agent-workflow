# Read-only external input witnesses for selected Pester files. Unknown disables
# reuse only; it never installs tools, repairs environments or blocks execution.
function Get-PesterExternalSha {
    param([string[]]$Lines)
    $sha=[Security.Cryptography.SHA256]::Create()
    try {([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($Lines -join "`0"))))).Replace('-','').ToLowerInvariant()} finally {$sha.Dispose()}
}
function Invoke-PesterExternalCommand {
    param([string]$Executable,[string[]]$Arguments,[string]$WorkingDirectory,[hashtable]$Environment=@{},[AllowNull()][object]$StandardInput=$null)
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$Executable
    $info.Arguments=(@($Arguments|ForEach-Object {ConvertTo-GitProcessArgument $_}) -join ' ')
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.RedirectStandardInput=$null -ne $StandardInput
    $info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false);$info.StandardErrorEncoding=$info.StandardOutputEncoding
    if($WorkingDirectory){$info.WorkingDirectory=$WorkingDirectory}
    foreach($name in $Environment.Keys){$info.EnvironmentVariables[$name]=[string]$Environment[$name]}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info
    try {
        if(-not $process.Start()){throw 'Runtime observer could not start its selected executable.'}
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if($null -ne $StandardInput){$process.StandardInput.Write([string]$StandardInput);$process.StandardInput.Close()}
        if(-not $process.WaitForExit(15000)){$process.Kill();$process.WaitForExit();throw 'Runtime observation timed out; execute without reuse.'}
        $output=$stdout.GetAwaiter().GetResult();$errorText=$stderr.GetAwaiter().GetResult()
        if($process.ExitCode -ne 0){throw "Runtime observation exited $($process.ExitCode); execute without reuse."}
        return $output
    } finally {$process.Dispose()}
}
function Get-PesterExternalExecutable {
    param([string]$Name,[string]$Override='')
    if($Override){$path=[Environment]::ExpandEnvironmentVariables($Override)}else{
        $command=Get-Command $Name -ErrorAction Stop|Select-Object -First 1
        if($command.CommandType -ne 'Application'){throw 'Selected command is an external wrapper, not a qualified executable; execute without reuse.'}
        $path=$command.Source
    }
    if(-not [IO.Path]::IsPathRooted($path) -or -not [IO.File]::Exists($path)){throw "Runtime executable is unavailable: $Name"}
    if([IO.Path]::GetExtension($path) -ine '.exe'){throw 'Selected command is an external wrapper, not a qualified executable; execute without reuse.'}
    return [IO.Path]::GetFullPath($path)
}
function Add-PesterExternalTree {
    param([string]$Root,[Collections.Generic.List[string]]$Lines,[string[]]$Exclude=@())
    if(-not [IO.Directory]::Exists($Root)){throw "Runtime directory is unavailable: $Root"}
    $prefix=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    $pending=[Collections.Generic.Queue[string]]::new();$pending.Enqueue($prefix)
    $Lines.Add('root='+$prefix)
    while($pending.Count){
        $directory=$pending.Dequeue()
        if(([IO.File]::GetAttributes($directory) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Runtime reparse directory cannot qualify complete bytes.'}
        $entries=[IO.Directory]::GetFileSystemEntries($directory);[Array]::Sort($entries,[StringComparer]::Ordinal)
        foreach($entry in $entries){
            $relative=$entry.Substring($prefix.Length).Replace('\','/')
            $skip=$false
            foreach($excluded in $Exclude){if($relative -eq $excluded -or $relative.StartsWith($excluded+'/',[StringComparison]::OrdinalIgnoreCase)){$skip=$true;break}}
            if($skip){continue}
            $attributes=[IO.File]::GetAttributes($entry)
            if(($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Runtime reparse entry cannot qualify complete bytes.'}
            if(($attributes -band [IO.FileAttributes]::Directory) -ne 0){$pending.Enqueue($entry)}else{
                $Lines.Add($relative+'='+ (Get-PesterShardFileSha256 $entry))
            }
        }
    }
}
function Add-PesterExternalFile {
    param([string]$Path,[Collections.Generic.List[string]]$Lines)
    if(-not [IO.File]::Exists($Path)){throw "Runtime file is unavailable: $Path"}
    if(([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Runtime reparse file cannot qualify complete bytes.'}
    $Lines.Add($Path+'='+(Get-PesterShardFileSha256 $Path))
}
function Add-PesterExternalComponentEnvironment {
    param([string]$RepositoryRoot,[string]$Component,[Collections.Generic.List[string]]$Lines)
    if($Component -notin @('Native','Linux','CodeChecker','Mantis','ChatGpt','OnDemandGo')){throw 'Unknown component environment; execute without reuse.'}
    $runtimeRoot=Join-Path $RepositoryRoot 'build/host-test-runtime'
    if(-not [IO.Directory]::Exists($runtimeRoot)){throw 'Source component venv is not prepared; execute without reuse.'}
    # Observe all generations owned by this component. Selection/generation remains
    # authoritative in host-test-runtime.ps1; the observer never prepares a venv.
    $pattern='^'+[regex]::Escape($Component.ToLowerInvariant())+'-[a-f0-9]{20}$'
    $directories=@([IO.Directory]::GetDirectories($runtimeRoot)|Where-Object {[IO.Path]::GetFileName($_) -cmatch $pattern}|Sort-Object)
    if(-not $directories.Count){throw 'Source component venv is not prepared; execute without reuse.'}
    foreach($directory in $directories){
        $config=Join-Path $directory 'pyvenv.cfg'
        $isolation=@(if([IO.File]::Exists($config)){[regex]::Matches([IO.File]::ReadAllText($config),'(?im)^include-system-site-packages[ \t]*=[ \t]*([^\r\n]*)')})
        if($isolation.Count -ne 1 -or $isolation[0].Groups[1].Value.Trim() -ine 'false'){
            throw 'Component venv system-site isolation is not qualified; execute without reuse.'
        }
        $site=Join-Path $directory 'Lib/site-packages'
        if([IO.Directory]::Exists($site) -and @([IO.Directory]::GetFiles($site,'*.pth')).Count){
            throw 'Component venv custom startup/search paths are not qualified; execute without reuse.'
        }
        foreach($file in @('sitecustomize.py','sitecustomize.pyc','usercustomize.py','usercustomize.pyc')){
            if([IO.File]::Exists((Join-Path $site $file))){throw 'Component venv custom startup/search paths are not qualified; execute without reuse.'}
        }
        Add-PesterExternalTree $directory $Lines
    }
}
function Get-PesterExternalProfile {
    param([string]$RepositoryRoot,[string]$Name,[object]$Definition)
    $lines=[Collections.Generic.List[string]]::new()
    $lines.Add($Name);$lines.Add(($Definition|ConvertTo-Json -Depth 8 -Compress))
    switch([string]$Definition.kind){
        'directory' {
            $root=[Environment]::GetEnvironmentVariable([string]$Definition.environmentVariable,'Process')
            Add-PesterExternalTree -Root $root -Lines $lines
        }
        'windows' {
            Add-Type -AssemblyName System.IO.Compression
            $desktop=Get-PesterExternalExecutable powershell
            $lines.Add('selected-powershell='+$desktop)
            Add-PesterExternalFile $desktop $lines
            foreach($assembly in @([object].Assembly,[IO.Compression.ZipArchive].Assembly,[System.Xml.XmlDocument].Assembly,[Microsoft.CSharp.CSharpCodeProvider].Assembly)){
                Add-PesterExternalFile $assembly.Location $lines
            }
            $framework=[IO.Path]::GetDirectoryName([object].Assembly.Location)
            foreach($file in @('clr.dll','csc.exe','System.dll','System.Core.dll','System.IO.Compression.FileSystem.dll')){Add-PesterExternalFile (Join-Path $framework $file) $lines}
            foreach($file in @('kernel32.dll','ntdll.dll','user32.dll')){Add-PesterExternalFile (Join-Path ([Environment]::SystemDirectory) $file) $lines}
            $lines.Add('os='+[Environment]::OSVersion.VersionString)
        }
        'git' {
            $git=Get-PesterExternalExecutable git
            Add-PesterExternalFile $git $lines
            $exec=(Invoke-PesterExternalCommand $git @('--exec-path')).Trim()
            $install=[IO.Path]::GetFullPath((Join-Path $exec '../../..'))
            foreach($folder in @('mingw64/bin','usr/bin','mingw64/libexec/git-core','etc')){Add-PesterExternalTree (Join-Path $install $folder) $lines}
            foreach($file in @((Join-Path $env:USERPROFILE '.gitconfig'),(Join-Path $env:USERPROFILE '.config/git/config'))){
                if([IO.File]::Exists($file)){Add-PesterExternalFile $file $lines}else{$lines.Add($file+'=<missing>')}
            }
            # Config includes can point outside these files; let Git resolve and
            # hash ordered effective values without exposing credentials in receipts.
            # A worktree config's origin path is bookkeeping, not a setting;
            # equal settings must qualify across candidate worktrees.
            $config=Invoke-PesterExternalCommand $git @('config','--null','--list') $RepositoryRoot
            if($config -match '(?i)(?:^|\x00)(?:includeif\.[^\n]+|core\.(?:hookspath|attributesfile|excludesfile)|init\.templatedir)\n'){
                throw 'Git conditional configuration or external hooks/attribute/template paths are not qualified; execute without reuse.'
            }
            if(@(Get-ChildItem Env:|Where-Object {$_.Name -match '^GIT_' -and $_.Value -and -not ($_.Name -eq 'GIT_PAGER' -and $_.Value -ceq 'cat')}).Count){
                throw 'Git process overrides are not qualified; execute without reuse.'
            }
            $userRoot=if($env:HOME){$env:HOME}else{$env:USERPROFILE}
            $configRoot=if($env:XDG_CONFIG_HOME){$env:XDG_CONFIG_HOME}else{Join-Path $userRoot '.config'}
            $attributes=Join-Path $configRoot 'git/attributes'
            if([IO.File]::Exists($attributes)){throw 'External Git user attributes are not qualified; execute without reuse.'}
            $ignore=Join-Path $configRoot 'git/ignore'
            if([IO.File]::Exists($ignore)){Add-PesterExternalFile $ignore $lines}else{$lines.Add($ignore+'=<missing>')}
            $lines.Add('effective-config='+(Get-PesterExternalSha @($config)))
        }
        'published-ancestor' {
            $git=Get-PesterExternalExecutable git
            $ancestor=(Invoke-PesterExternalCommand $git @('-C',$RepositoryRoot,'merge-base','HEAD','refs/remotes/origin/develop')).Trim()
            $lines.Add('published-ancestor='+$ancestor)
            $lines.Add('published-ignore='+(Get-PesterExternalSha @((Invoke-PesterExternalCommand $git @('-C',$RepositoryRoot,'show',($ancestor+':templates/gitignore.append'))))))
        }
        'inventory' {
            $git=Get-PesterExternalExecutable git
            $lines.Add('inventory='+(Get-PesterExternalSha @(Get-RepositoryGitPathList -RepositoryRoot $RepositoryRoot -Arguments @('ls-files','-z','--cached'))))
        }
        'node' {
            if($env:NODE_OPTIONS -or $env:NODE_PATH){throw 'Node external options/search paths are not qualified.'}
            $node=Get-PesterExternalExecutable node
            Add-PesterExternalFile $node $lines
            foreach($file in [IO.Directory]::GetFiles([IO.Path]::GetDirectoryName($node),'*.dll')){Add-PesterExternalFile $file $lines}
        }
        'onescript' {
            if(@(Get-ChildItem Env:|Where-Object {$_.Name -match '^(OSCRIPT|ONESCRIPT)' -and $_.Value}).Count){throw 'OneScript external configuration is not qualified.'}
            $engine=Get-PesterExternalExecutable oscript
            $engineRoot=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($engine)) '..'))
            $config=Join-Path ([IO.Path]::GetDirectoryName($engine)) 'oscript.cfg'
            if([IO.File]::Exists($config)){
                foreach($row in [IO.File]::ReadAllLines($config)){
                    $library=[regex]::Match($row,'^\s*lib\.(system|additional)\s*=\s*(.*?)\s*$')
                    if($library.Success){foreach($folder in $library.Groups[2].Value.Split(';')){
                        if(-not $folder.Trim()){continue}
                        $resolved=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($engine)) $folder.Trim()))
                        if(-not $resolved.StartsWith($engineRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'OneScript external library root is not qualified.'}
                    }}
                }
            }
            Add-PesterExternalTree $engineRoot $lines
        }
        'python-environment' {
            if($env:PYTHONPATH -or $env:PYTHONHOME){throw 'Python external search paths are not qualified.'}
            $override=if($env:ITL_SOURCE_TEST_PYTHON){$env:ITL_SOURCE_TEST_PYTHON}elseif($env:VIBECODING1C_MCP_PYTHON_PATH){$env:VIBECODING1C_MCP_PYTHON_PATH}else{''}
            $python=Get-PesterExternalExecutable python $override
            if($python -match '[\\/]WindowsApps[\\/]'){throw 'Python store alias is not a runtime identity.'}
            $probe=Invoke-PesterExternalCommand $python @('-I','-S','-B','-X','utf8','-c','import sys,json;print(json.dumps(dict(executable=sys.executable,base=sys.base_prefix,version=list(sys.version_info[:3]))))')
            $actual=$probe|ConvertFrom-Json
            if($actual.version[0] -ne 3 -or [IO.Path]::GetFullPath($actual.executable) -ine $python){throw 'Python bootstrap resolution is not qualified.'}
            foreach($file in @('sitecustomize.py','sitecustomize.pyc','usercustomize.py','usercustomize.pyc')){
                if([IO.File]::Exists((Join-Path $actual.base ('Lib/'+$file)))){throw 'Python custom startup is not qualified; execute without reuse.'}
            }
            $lines.Add('python='+$python);$lines.Add('version='+($actual.version -join '.'))
            foreach($file in [IO.Directory]::GetFiles($actual.base,'*.dll')){Add-PesterExternalFile $file $lines}
            Add-PesterExternalFile $python $lines
            Add-PesterExternalTree (Join-Path $actual.base 'DLLs') $lines
            # The source owner creates isolated venvs with -I -S. Global
            # site-packages are not an execution input; actual venv bytes below are.
            Add-PesterExternalTree (Join-Path $actual.base 'Lib') $lines @('site-packages')
            foreach($file in [IO.Directory]::GetFiles($actual.base,'python*.zip')){Add-PesterExternalFile $file $lines}
            Add-PesterExternalComponentEnvironment $RepositoryRoot ([string]$Definition.component) $lines

        }
        'python-package-dependencies' {
            throw 'Exact package-byte observation costs more than the original package tests; execute their native checks without reuse.'
        }
        'fresh-python-dependencies' {
            throw 'Original workload resolves fresh unpinned Python dependencies; no exact reusable package environment exists.'
        }
        'go' {
            if($env:GOTOOLCHAIN -and $env:GOTOOLCHAIN -notin @('auto','local')){throw 'Explicit Go toolchain selection is not qualified.'}
            $go=Get-PesterExternalExecutable go $env:ITL_SOURCE_TEST_GO
            $module=Join-Path $RepositoryRoot 'tools/itl-ondemand-mcp'
            $probe=Invoke-PesterExternalCommand $go @('env','-json','GOROOT','GOMODCACHE','GOVERSION','GOENV','GOWORK','CGO_ENABLED','GOFLAGS') $module @{GOTOOLCHAIN='local';GOPROXY='off';GOSUMDB='off'}
            $actual=$probe|ConvertFrom-Json
            if($actual.GOWORK -and $actual.GOWORK -ne 'off'){throw 'External Go workspace is not qualified.'}
            if($actual.CGO_ENABLED -ne '0'){throw 'External C compiler identity is not qualified.'}
            $mod=[IO.File]::ReadAllText((Join-Path $module 'go.mod'))
            $required=[regex]::Match($mod,'(?m)^toolchain go([0-9.]+)\s*$')
            if(-not $required.Success -or [version]($actual.GOVERSION -replace '^go','') -lt [version]$required.Groups[1].Value){throw 'Pinned Go toolchain is unavailable locally; observation never downloads it.'}
            Add-PesterExternalFile $go $lines
            if($env:GOFLAGS -or $actual.GOFLAGS){throw 'External Go build flags/overlays are not qualified.'}
            if($actual.GOENV -and $actual.GOENV -ne 'off' -and [IO.File]::Exists($actual.GOENV)){Add-PesterExternalFile $actual.GOENV $lines}
            if(-not $env:GOTOOLCHAIN -and $actual.GOENV -and [IO.File]::Exists($actual.GOENV)){
                $configured=[regex]::Match([IO.File]::ReadAllText($actual.GOENV),'(?m)^GOTOOLCHAIN=(.+)$')
                if($configured.Success -and $configured.Groups[1].Value.Trim() -notin @('auto','local')){throw 'Configured external Go toolchain is not qualified.'}
            }
            $tool=Join-Path $actual.GOROOT 'pkg/tool/windows_amd64'
            Add-PesterExternalTree $tool $lines
            Add-PesterExternalTree (Join-Path $actual.GOROOT 'pkg/include') $lines
            $fields='Dir,ImportPath,Module,GoFiles,CgoFiles,CFiles,CXXFiles,MFiles,HFiles,FFiles,SFiles,SwigFiles,SwigCXXFiles,SysoFiles,EmbedFiles'
            $packages=Invoke-PesterExternalCommand $go @('list','-deps','-test',('-json='+$fields),'./...') $module @{GOTOOLCHAIN='local';GOPROXY='off';GOSUMDB='off'}
            $python=Get-PesterExternalExecutable python $(if($env:ITL_SOURCE_TEST_PYTHON){$env:ITL_SOURCE_TEST_PYTHON}elseif($env:VIBECODING1C_MCP_PYTHON_PATH){$env:VIBECODING1C_MCP_PYTHON_PATH}else{''})
            $decode="import sys,json; s=sys.stdin.read(); d=json.JSONDecoder(); rows=[]`nwhile s.strip():`n s=s.lstrip(); v,n=d.raw_decode(s); rows.append(v); s=s[n:]`nprint(json.dumps(rows))"
            $json=Invoke-PesterExternalCommand -Executable $python -Arguments @('-I','-S','-B','-c',$decode) -StandardInput $packages
            $rows=@($json|ConvertFrom-Json)
            $rootPrefix=[IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
            $files=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach($row in $rows){
                $directory=if($row.PSObject.Properties['Dir']){[string]$row.Dir}else{''}
                foreach($field in @($fields.Split(',')|Where-Object {$_ -notin @('Dir','ImportPath','Module')})){
                    $property=$row.PSObject.Properties[$field]
                    if($property){foreach($file in @($property.Value)){
                        $absolute=if([IO.Path]::IsPathRooted($file)){$file}elseif($directory){Join-Path $directory $file}else{throw 'Go dependency source path is unavailable.'}
                        if(-not $absolute.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)){[void]$files.Add($absolute)}
                    }}
                }
                if($row.PSObject.Properties['Module'] -and $row.Module -and $row.Module.PSObject.Properties['GoMod']){
                    $modFile=[string]$row.Module.GoMod
                    if($modFile -and -not $modFile.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)){[void]$files.Add($modFile)}
                }
            }
            foreach($file in @($files|Sort-Object)){Add-PesterExternalFile $file $lines}
        }
        default {throw "Unknown external runtime profile: $Name"}
    }
    # Environment can alter resolution/execution even at an unchanged path.
    $environmentPattern=switch([string]$Definition.kind){
        'git' {'^GIT_'}
        'published-ancestor' {'^GIT_'}
        'inventory' {'^GIT_'}
        'go' {'^(GO[A-Z_]|ITL_SOURCE_TEST_GO$)'}
        'node' {'^NODE_'}
        'onescript' {'^(OSCRIPT|ONESCRIPT)'}
        'python-environment' {'^(PYTHON|ITL_SOURCE_TEST_PYTHON$|VIBECODING1C_MCP_PYTHON_PATH$)'}
        'windows' {'^(COMPLUS|COR_|CLR_)'}
        default {'^$'}
    }
    # All these Git observations and original fixtures capture stdout through
    # pipes. The tool host's inert cat pager must not split identical proofs.
    $environment=@(Get-ChildItem Env:|Where-Object {$_.Name -match $environmentPattern -and -not ($_.Name -eq 'GIT_PAGER' -and $_.Value -ceq 'cat' -and $Definition.kind -in @('git','published-ancestor','inventory'))}|Sort-Object Name|ForEach-Object {$_.Name+'='+$_.Value})
    $lines.Add('environment='+(Get-PesterExternalSha $environment))
    return Get-PesterExternalSha $lines.ToArray()
}
function Write-PesterExternalRuntimeReceipt {
    param([string]$Path,[object]$Rows)
    if(-not $Path){return}
    $temporary=$Path+'.next'
    [IO.File]::WriteAllText($temporary,($Rows|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    if([IO.File]::Exists($Path)){[IO.File]::Replace($temporary,$Path,($Path+'.previous'),$true)}else{[IO.File]::Move($temporary,$Path)}
}
function Get-PesterExternalRuntimeReceipt {
    param([string]$RepositoryRoot,[object]$Profiles,[string]$ReceiptPath='')
    $rows=[ordered]@{}
    # Publish complete snapshots incrementally. A timed-out profile must not
    # erase already observed identities of unrelated files. Windows is shared
    # by most files and is observed first; unknown rows never admit cache reuse.
    $properties=@($Profiles.PSObject.Properties|Sort-Object @{Expression={if($_.Value -and $_.Value.PSObject.Properties['kind'] -and $_.Value.kind -eq 'windows'){0}else{1}}},Name)
    foreach($property in $properties){$rows[$property.Name]=[pscustomobject]@{status='unknown';sha256='';reason='Observation did not complete within the bounded runtime probe.'}}
    Write-PesterExternalRuntimeReceipt $ReceiptPath ([pscustomobject]$rows)
    foreach($property in $properties){
        try {$rows[$property.Name]=[pscustomobject]@{status='known';sha256=(Get-PesterExternalProfile $RepositoryRoot $property.Name $property.Value);reason=''}}
        catch {$rows[$property.Name]=[pscustomobject]@{status='unknown';sha256='';reason=$_.Exception.Message}}
        Write-PesterExternalRuntimeReceipt $ReceiptPath ([pscustomobject]$rows)
    }
    return [pscustomobject]$rows
}
