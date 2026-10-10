# Stateless structural-log parsing and comparison. The load owner proves the
# native completion, snapshot/source/target binding and hashes supplied here.
function Get-ItlPlatformDiagnosticsSha256 {
    param([byte[]]$Bytes)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function ConvertTo-ItlPlatformStructuralDiagnostics {
    param([AllowEmptyString()][string]$Text)
    $categories = @(
        'Возможно ошибочное свойство', 'Возможно ошибочный метод', 'Возможно ошибочный параметр',
        'Отсутствует обработчик', 'Неразрешимые ссылки на объекты метаданных',
        'Неразрешимые ссылки на картинки', 'Неразрешимые ссылки на типы',
        'Неразрешимые ссылки на элементы стиля'
    )
    $categoryPattern = (@($categories | ForEach-Object { [regex]::Escape($_) }) -join '|')
    $known = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $compiler = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $unresolved = [Collections.Generic.List[object]]::new()
    $informational = [Collections.Generic.List[string]]::new()
    $repositoryStatus = [Collections.Generic.List[string]]::new()
    $successPatterns = @(
        '(?i)\bошибок\s+не\s+обнаружено\b', '(?i)\bпредупреждений\s+не\s+обнаружено\b',
        '(?i)\b(?:ошибок|предупреждений)\s*:\s*0(?![0-9])\b',
        '(?i)\b(?:errors?|warnings?)\s*(?::|=)\s*0(?![0-9])\b',
        '(?i)\b(?:0\s+errors?|0\s+warnings?|no\s+errors?|no\s+warnings?|errors?\s+were\s+not\s+found)\b'
    )
    $lines = @($Text.TrimStart([char]0xFEFF) -split '\r\n|\n|\r')
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        $lineNumber = $index + 1
        $identity = $line.Trim()
        if (-not $identity) { continue }
        if ($identity -ceq 'Соединение с хранилищем конфигурации не установлено') {
            $repositoryStatus.Add($identity)
            $informational.Add($identity)
            continue
        }
        # Recognize this one complete native compiler diagnostic, never a lone
        # header or a general success-looking line. Preserve both physical rows.
        $header = [regex]::Match($line, '^\{(?<owner>[^{}\s]+)\((?<row>[1-9][0-9]{0,8}),(?<column>[1-9][0-9]{0,8})\)\}: Процедура не может возвращать значение$')
        if ($header.Success -and $index + 1 -lt $lines.Count) {
            $context = [regex]::Match($lines[$index + 1], '^[ \t]+(?i:Возврат)[ \t]+[^\r\n]+<<\?>>;[ \t]+\(Проверка: (?<mode>Внешнее соединение|Сервер|Тонкий клиент)\)$')
            if ($context.Success) {
                $pairIdentity = $line + "`n" + $lines[$index + 1]
                if ($compiler.ContainsKey($pairIdentity)) {
                    $compiler[$pairIdentity].count++
                    $compiler[$pairIdentity].lineNumbers += $lineNumber
                } else {
                    $compiler.Add($pairIdentity, [pscustomobject][ordered]@{
                        identity=$pairIdentity; line=$pairIdentity; header=$line; context=$lines[$index + 1]
                        rawLines=@($line,$lines[$index + 1]); owner=$header.Groups['owner'].Value
                        row=[int]$header.Groups['row'].Value; column=[int]$header.Groups['column'].Value
                        mode=$context.Groups['mode'].Value; category='Процедура не может возвращать значение'
                        severity='native-compiler-error'; count=1; lineNumbers=@($lineNumber)
                    })
                }
                $index++
                continue
            }
        }
        $remaining = $identity
        foreach ($pattern in $successPatterns) { $remaining = [regex]::Replace($remaining, $pattern, '') }
        $remaining = $remaining.Trim([char[]]" `t.;,:")
        if (-not $remaining -or $remaining -cmatch '^(?:Проверка(?: конфигурации)? завершена|Configuration check completed|Check completed)\.?$') {
            $informational.Add($identity)
            continue
        }
        $match = [regex]::Match($remaining, '^(?<owner>\S+)\s+(?<category>' + $categoryPattern + ')(?=\s|:|$)(?<payload>.*)$')
        if (-not $match.Success) {
            $unresolved.Add([pscustomobject][ordered]@{ line=$identity; lineNumber=$lineNumber; reason='unrecognized-nonempty-text' })
            continue
        }
        $owner = $match.Groups['owner'].Value
        $category = $match.Groups['category'].Value
        $payload = $match.Groups['payload'].Value.Trim()
        # Some unresolved-reference categories contain the entire finding in
        # their category and occurrence suffix; they do not need a colon.
        if (-not $payload) {
            $unresolved.Add([pscustomobject][ordered]@{ line=$identity; lineNumber=$lineNumber; reason='missing-diagnostic-payload' })
            continue
        }
        if ($known.ContainsKey($identity)) { $known[$identity].count++ }
        else {
            $known.Add($identity, [pscustomobject][ordered]@{
                identity=$identity; line=$identity; owner=$owner; category=$category
                payload=$payload; severity='native-unknown'; count=1
            })
        }
    }
    $knownCount = 0
    foreach ($finding in $known.Values) { $knownCount += $finding.count }
    $compilerCount = 0
    foreach ($finding in $compiler.Values) { $compilerCount += $finding.count }
    return [pscustomobject][ordered]@{
        schemaVersion=1; kind='itl-platform-structural-diagnostics'
        rawSha256=(Get-ItlPlatformDiagnosticsSha256 -Bytes ([Text.UTF8Encoding]::new($false,$true).GetBytes($Text)))
        rawText=$Text
        knownDiagnostics=@($known.Values | Sort-Object -Property identity -CaseSensitive)
        compilerDiagnostics=@($compiler.Values | Sort-Object -Property identity -CaseSensitive)
        compilerDiagnosticCount=$compilerCount
        unresolvedDiagnostics=@($unresolved.ToArray())
        informationalLines=@($informational.ToArray())
        repositoryStatusLines=@($repositoryStatus.ToArray())
        knownDiagnosticCount=$knownCount
        unresolvedDiagnosticCount=$unresolved.Count
    }
}

function Get-ItlPlatformStructuralDiagnostics {
    param([Parameter(Mandatory=$true)][string]$LogPath)
    try { $bytes = [IO.File]::ReadAllBytes($LogPath) }
    catch { throw "PLATFORM_DIAGNOSTICS_READ_FAILED: $($_.Exception.Message)" }
    try { $text = [Text.UTF8Encoding]::new($false,$true).GetString($bytes) }
    catch { throw "PLATFORM_DIAGNOSTICS_UTF8_INVALID: $($_.Exception.Message)" }
    $result = ConvertTo-ItlPlatformStructuralDiagnostics -Text $text
    $result | Add-Member -NotePropertyName logPath -NotePropertyValue $LogPath
    return $result
}

function Get-ItlPlatformDiagnosticsValue {
    param([AllowNull()][object]$Value,[string]$Name)
    if ($null -eq $Value) { return $null }
    if ($Value -is [Collections.IDictionary]) {
        if ($Value.Contains($Name)) { return $Value[$Name] }
        return $null
    }
    $property = $Value.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Compare-ItlPlatformStructuralDiagnostics {
    param(
        [Parameter(Mandatory=$true)][object]$Before,
        [Parameter(Mandatory=$true)][object]$After,
        [Parameter(Mandatory=$true)][bool]$BindingMatched,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$ChangedOwners,
        [AllowEmptyCollection()][object[]]$UnchangedOwnersProof=@(),
        [bool]$CompilationPassedAfter=$false
    )
    $issues = [Collections.Generic.List[string]]::new()
    $parsed = @{}
    foreach ($item in @([pscustomobject]@{ name='before'; value=$Before }, [pscustomobject]@{ name='after'; value=$After })) {
        $raw = Get-ItlPlatformDiagnosticsValue $item.value 'rawText'
        $version = Get-ItlPlatformDiagnosticsValue $item.value 'schemaVersion'
        $kind = [string](Get-ItlPlatformDiagnosticsValue $item.value 'kind')
        if ($null -eq $raw -or [string]$version -cne '1' -or $kind -cne 'itl-platform-structural-diagnostics') {
            $issues.Add($item.name + '-document-invalid')
            continue
        }
        # Reparse the preserved raw input: mutable projection arrays or counts
        # cannot turn an incomplete or swapped native log into legacy evidence.
        $document = ConvertTo-ItlPlatformStructuralDiagnostics -Text ([string]$raw)
        if ([string](Get-ItlPlatformDiagnosticsValue $item.value 'rawSha256') -cne $document.rawSha256) {
            $issues.Add($item.name + '-raw-hash-mismatch')
            continue
        }
        $parsed[$item.name] = $document
    }
    if (-not $BindingMatched) { $issues.Add('baseline-binding-unproved') }
    $changed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($owner in @($ChangedOwners)) {
        if ([string]::IsNullOrWhiteSpace($owner)) { $issues.Add('changed-owner-invalid') }
        else { [void]$changed.Add($owner) }
    }
    $proofs = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $invalidProofOwners = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($proof in @($UnchangedOwnersProof)) {
        $owner = [string](Get-ItlPlatformDiagnosticsValue $proof 'owner')
        $beforeSha = [string](Get-ItlPlatformDiagnosticsValue $proof 'beforeSha256')
        $afterSha = [string](Get-ItlPlatformDiagnosticsValue $proof 'afterSha256')
        if ([string]::IsNullOrWhiteSpace($owner)) { $issues.Add('unchanged-owner-proof-invalid'); continue }
        if ($proofs.ContainsKey($owner) -or $invalidProofOwners.Contains($owner)) {
            [void]$invalidProofOwners.Add($owner)
            if ($proofs.ContainsKey($owner)) { [void]$proofs.Remove($owner) }
            $issues.Add('unchanged-owner-proof-duplicate:' + $owner)
            continue
        }
        if ($beforeSha -notmatch '^[a-fA-F0-9]{64}$' -or $afterSha -notmatch '^[a-fA-F0-9]{64}$' -or $beforeSha -ine $afterSha) {
            [void]$invalidProofOwners.Add($owner)
            $issues.Add('unchanged-owner-proof-invalid:' + $owner)
            continue
        }
        $proofs.Add($owner,$proof)
    }
    $legacy = [Collections.Generic.List[object]]::new()
    $new = [Collections.Generic.List[object]]::new()
    $unresolved = [Collections.Generic.List[object]]::new()
    $resolvedCompiler = [Collections.Generic.List[object]]::new()
    if ($parsed.ContainsKey('before') -and $parsed.ContainsKey('after')) {
        foreach ($side in @('before','after')) {
            foreach ($finding in @($parsed[$side].unresolvedDiagnostics)) {
                $unresolved.Add([pscustomobject][ordered]@{ source=$side; line=$finding.line; count=1; reason=$finding.reason })
            }
        }
        foreach ($side in @('before','after')) {
            foreach ($finding in @($parsed[$side].compilerDiagnostics)) {
                $insideScope = $false
                foreach ($scopeOwner in $changed) {
                    if ($finding.owner -ceq $scopeOwner -or $finding.owner.StartsWith($scopeOwner + '.',[StringComparison]::Ordinal)) { $insideScope=$true; break }
                }
                $reason = if ($side -eq 'after') { 'current-compiler-diagnostic' }
                    elseif (-not $BindingMatched) { 'baseline-binding-unproved' }
                    elseif (-not $CompilationPassedAfter) { 'after-compilation-not-proved' }
                    elseif (-not $insideScope) { 'before-compiler-outside-changed-or-impact-scope' }
                    elseif ($parsed.after.compilerDiagnosticCount -gt 0) { 'current-compiler-diagnostics-present' }
                    else { '' }
                $record = [ordered]@{}
                foreach ($property in $finding.PSObject.Properties) { $record[$property.Name] = $property.Value }
                $record['source'] = $side
                if ($reason) {
                    $record['reason'] = $reason
                    $unresolved.Add([pscustomobject]$record)
                } else {
                    $record['resolution'] = 'current-compilation-passed-inside-changed-or-impact-scope'
                    $resolvedCompiler.Add([pscustomobject]$record)
                }
            }
        }
        $beforeMap = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        foreach ($finding in @($parsed.before.knownDiagnostics)) { $beforeMap.Add($finding.identity,$finding) }
        foreach ($finding in @($parsed.after.knownDiagnostics)) {
            $reason = ''
            $insideScope = $false
            foreach ($scopeOwner in $changed) {
                if ($finding.owner -ceq $scopeOwner -or $finding.owner.StartsWith($scopeOwner + '.',[StringComparison]::Ordinal)) { $insideScope=$true; break }
            }
            $proofOwner = ''
            foreach ($candidateOwner in $proofs.Keys) {
                if (($finding.owner -ceq $candidateOwner -or $finding.owner.StartsWith($candidateOwner + '.',[StringComparison]::Ordinal)) -and $candidateOwner.Length -gt $proofOwner.Length) { $proofOwner=$candidateOwner }
            }
            if (-not $BindingMatched) { $reason='baseline-binding-unproved' }
            elseif ($insideScope) { $reason='inside-changed-or-impact-scope' }
            elseif (-not $beforeMap.ContainsKey($finding.identity)) {
                $new.Add($finding)
                continue
            } elseif ($beforeMap[$finding.identity].count -ne $finding.count) { $reason='diagnostic-occurrence-count-changed' }
            elseif (-not $proofOwner) { $reason='unchanged-owner-hash-unproved' }
            if ($reason) {
                $unresolved.Add([pscustomobject][ordered]@{ source='after'; line=$finding.line; owner=$finding.owner; category=$finding.category; severity=$finding.severity; count=$finding.count; reason=$reason })
            } else {
                $legacy.Add([pscustomobject][ordered]@{
                    identity=$finding.identity; line=$finding.line; owner=$finding.owner; category=$finding.category
                    payload=$finding.payload; severity=$finding.severity; count=$finding.count; proofOwner=$proofOwner
                })
            }
        }
    }
    $legacyCount = 0; $newCount = 0; $unresolvedCount = 0; $resolvedCompilerCount = 0
    foreach ($finding in $legacy) { $legacyCount += $finding.count }
    foreach ($finding in $new) { $newCount += $finding.count }
    foreach ($finding in $unresolved) { $unresolvedCount += $finding.count }
    foreach ($finding in $resolvedCompiler) { $resolvedCompilerCount += $finding.count }
    $allowed = $BindingMatched -and $issues.Count -eq 0 -and $legacyCount -gt 0 -and $newCount -eq 0 -and $unresolvedCount -eq 0
    $status = if ($allowed) { 'accepted-with-preexisting-findings' } elseif ($issues.Count -eq 0 -and $newCount -eq 0 -and $unresolvedCount -eq 0 -and $legacyCount -eq 0) { 'not-applicable-clean' } else { 'unresolved' }
    return [pscustomobject][ordered]@{
        schemaVersion=1; kind='itl-platform-structural-comparison'
        applyAllowed=[bool]$allowed; cleanPassed=$false; status=$status
        beforeRawSha256=[string](Get-ItlPlatformDiagnosticsValue $Before 'rawSha256')
        afterRawSha256=[string](Get-ItlPlatformDiagnosticsValue $After 'rawSha256')
        legacyDiagnostics=@($legacy.ToArray()); legacyDiagnosticCount=$legacyCount
        newDiagnostics=@($new.ToArray()); newDiagnosticCount=$newCount
        resolvedBeforeCompiler=@($resolvedCompiler.ToArray()); resolvedBeforeCompilerCount=$resolvedCompilerCount
        unresolvedDiagnostics=@($unresolved.ToArray()); unresolvedDiagnosticCount=$unresolvedCount
        issues=@($issues.ToArray())
    }
}
