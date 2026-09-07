[CmdletBinding()]
param([string]$InstallationRoot, [string]$NodePath=$env:CODEX_MCP_NODE_PATH,
      [string]$PipePath=$env:CODEX_APP_TOOLS_PIPE_PATH, [string]$ContextThreadId=$env:CODEX_THREAD_ID)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
if (-not $InstallationRoot) {
    $roots=@(Get-AppxPackage 'OpenAI.Codex' | Select-Object -ExpandProperty InstallLocation)
    if ($roots.Count -ne 1) { throw 'DESKTOP_INSTALLATION_AMBIGUOUS: supply InstallationRoot' }
    $InstallationRoot=$roots[0]
}
$bridge=Join-Path $InstallationRoot 'app/resources/plugins/openai-bundled/plugins/codex-app-tools/server.mjs'
if (-not (Test-Path -LiteralPath $bridge -PathType Leaf)) { throw 'DESKTOP_BRIDGE_UNAVAILABLE' }
if (-not $NodePath) {
    $nodes=@(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'OpenAI/Codex/runtimes/cua_node') -Directory |
        ForEach-Object { Join-Path $_.FullName 'bin/node.exe' } | Where-Object { Test-Path -LiteralPath $_ })
    if ($nodes.Count -ne 1) { throw 'DESKTOP_NODE_AMBIGUOUS: supply NodePath' }
    $NodePath=$nodes[0]
}
if (-not (Test-Path -LiteralPath $NodePath -PathType Leaf)) { throw 'DESKTOP_NODE_UNAVAILABLE' }
$livePipes=@([IO.Directory]::GetFiles('\\.\pipe\') | Where-Object { $_ -like '*codex-browser-use-*' })
if (-not $PipePath) {
    if ($livePipes.Count -ne 1) { throw 'DESKTOP_PIPE_AMBIGUOUS: run from target Codex session' }
    $PipePath=$livePipes[0]
}
if ($PipePath -notin $livePipes -or -not $ContextThreadId) { throw 'DESKTOP_LIVE_CONTEXT_REQUIRED' }
@{ command=@($NodePath,$bridge); cwd=$InstallationRoot; env=@{CODEX_APP_TOOLS_PIPE_PATH=$PipePath}; contextThreadId=$ContextThreadId } | ConvertTo-Json -Depth 5 -Compress
