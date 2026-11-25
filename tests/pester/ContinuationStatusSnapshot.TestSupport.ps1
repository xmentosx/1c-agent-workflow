function Copy-TestContinuationStatusSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    # The live parent replaces status.json while the child observes it. Retry
    # only transient transport failures; never substitute an old/empty snapshot.
    for ($attempt = 1; $attempt -le 40; $attempt++) {
        try {
            Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force -ErrorAction Stop
            return
        } catch {
            $cause = $_.Exception
            $transient = $false
            while ($null -ne $cause) {
                if ($cause -is [Management.Automation.ItemNotFoundException] -or
                    ($cause -is [IO.IOException] -and ($cause.HResult -band 0xffff) -in @(2,32,33))) {
                    $transient = $true
                }
                $cause = $cause.InnerException
            }
            if (-not $transient -or $attempt -eq 40) { throw }
            Start-Sleep -Milliseconds 50
        }
    }
}
