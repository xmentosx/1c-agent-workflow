BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    . (Join-Path $repoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.platform-diagnostics.ps1')
    function New-StructuralLog {
        param([string]$Text,[switch]$Bom)
        $root = Join-Path $TestDrive 'Диагностика платформы с пробелом'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $path = Join-Path $root ([guid]::NewGuid().ToString('N') + '.log')
        [IO.File]::WriteAllText($path,$Text,[Text.UTF8Encoding]::new([bool]$Bom))
        return Get-ItlPlatformStructuralDiagnostics -LogPath $path
    }
    function New-StructuralOwnerProof {
        param([string]$Owner)
        return [pscustomobject]@{owner=$Owner;beforeSha256=('a' * 64);afterSha256=('a' * 64)}
    }
    $sampleOwner = 'ОбщийМодуль.Логика.Модуль'
    $sampleLine = $sampleOwner + ' Возможно ошибочный метод: "ОтсутствующийМетод"'
    $compilerOwner = 'ОбщийМодуль.упо_ФИ_УправлениеДоступомКлиентСервер.Модуль'
    $repositoryNotice = 'Соединение с хранилищем конфигурации не установлено'
    function New-NativeCompilerPair {
        param([string]$Mode='Сервер',[string]$Owner=$compilerOwner)
        return ('{' + $Owner + '(6,24)}: Процедура не может возвращать значение' + "`r`n`t" + 'ВОзврат ТекстСообщения<<?>>; (Проверка: ' + $Mode + ')' + "`r`n")
    }
}

Describe 'Native compiler findings require a current compilation proof' {
    It 'recognizes complete native compiler pairs and only the exact repository notice' {
        $text = $repositoryNotice + "`r`n" + (New-NativeCompilerPair 'Внешнее соединение') + (New-NativeCompilerPair 'Сервер') + (New-NativeCompilerPair 'Тонкий клиент')
        $document = New-StructuralLog $text -Bom
        $document.rawText | Should -BeExactly ([string][char]0xFEFF + $text)
        $document.rawSha256 | Should -BeExactly ((Get-FileHash -LiteralPath $document.logPath).Hash.ToLowerInvariant())
        $document.unresolvedDiagnosticCount | Should -Be 0
        $document.compilerDiagnosticCount | Should -Be 3
        $document.repositoryStatusLines | Should -Contain $repositoryNotice
        $document.informationalLines | Should -HaveCount 1
        @($document.compilerDiagnostics | ForEach-Object mode) | Should -Contain 'Сервер'
        foreach ($finding in $document.compilerDiagnostics) {
            $finding.owner | Should -BeExactly $compilerOwner
            $finding.row | Should -Be 6
            $finding.column | Should -Be 24
            $finding.header | Should -BeExactly ('{' + $compilerOwner + '(6,24)}: Процедура не может возвращать значение')
            $finding.context | Should -BeExactly ("`t" + 'ВОзврат ТекстСообщения<<?>>; (Проверка: ' + $finding.mode + ')')
            $finding.rawLines | Should -HaveCount 2
            $finding.count | Should -Be 1
        }
    }
    It 'keeps default comparison strict when a before compiler error disappeared' {
        $before = New-StructuralLog ($sampleLine + "`r`n" + (New-NativeCompilerPair))
        $after = New-StructuralLog $sampleLine
        $result = Compare-ItlPlatformStructuralDiagnostics -Before $before -After $after -BindingMatched $true -ChangedOwners @($compilerOwner) -UnchangedOwnersProof @(New-StructuralOwnerProof $sampleOwner)
        $result.applyAllowed | Should -BeFalse
        $result.resolvedBeforeCompilerCount | Should -Be 0
        $result.legacyDiagnosticCount | Should -Be 1
        $result.unresolvedDiagnostics[0].reason | Should -BeExactly 'after-compilation-not-proved'
    }
    It 'resolves before compiler findings inside impact scope only after actual current compilation proof' {
        $before = New-StructuralLog ($repositoryNotice + "`r`n" + $sampleLine + "`r`n" + (New-NativeCompilerPair 'Внешнее соединение') + (New-NativeCompilerPair 'Сервер') + (New-NativeCompilerPair 'Тонкий клиент')) -Bom
        $after = New-StructuralLog $sampleLine -Bom
        $result = Compare-ItlPlatformStructuralDiagnostics -Before $before -After $after -BindingMatched $true -CompilationPassedAfter $true -ChangedOwners @('ОбщийМодуль.упо_ФИ_УправлениеДоступомКлиентСервер') -UnchangedOwnersProof @(New-StructuralOwnerProof $sampleOwner)
        $result.applyAllowed | Should -BeTrue
        $result.cleanPassed | Should -BeFalse
        $result.legacyDiagnosticCount | Should -Be 1
        $result.resolvedBeforeCompilerCount | Should -Be 3
        $result.unresolvedDiagnosticCount | Should -Be 0
        $result.resolvedBeforeCompiler | Should -HaveCount 3
        foreach ($finding in $result.resolvedBeforeCompiler) {
            $finding.owner | Should -BeExactly $compilerOwner
            $finding.rawLines | Should -HaveCount 2
            $finding.resolution | Should -BeExactly 'current-compilation-passed-inside-changed-or-impact-scope'
        }
    }
    It 'does not resolve a compiler owner outside the declared changed and impact scope' {
        $before = New-StructuralLog ($sampleLine + "`r`n" + (New-NativeCompilerPair))
        $after = New-StructuralLog $sampleLine
        $result = Compare-ItlPlatformStructuralDiagnostics -Before $before -After $after -BindingMatched $true -CompilationPassedAfter $true -ChangedOwners @('ОбщийМодуль.упо_ФИ_УправлениеДоступомКлиентСервер2') -UnchangedOwnersProof @(New-StructuralOwnerProof $sampleOwner)
        $result.applyAllowed | Should -BeFalse
        $result.resolvedBeforeCompilerCount | Should -Be 0
        $result.unresolvedDiagnostics[0].reason | Should -BeExactly 'before-compiler-outside-changed-or-impact-scope'
    }
    It 'requires both native binding and current compilation for <Case>' -ForEach @(
        @{Case='missing current compilation';Binding=$true;Compilation=$false},
        @{Case='unproved native binding';Binding=$false;Compilation=$true}
    ) {
        $before = New-StructuralLog ($sampleLine + "`r`n" + (New-NativeCompilerPair))
        $after = New-StructuralLog $sampleLine
        $result = Compare-ItlPlatformStructuralDiagnostics -Before $before -After $after -BindingMatched $Binding -CompilationPassedAfter $Compilation -ChangedOwners @($compilerOwner) -UnchangedOwnersProof @(New-StructuralOwnerProof $sampleOwner)
        $result.applyAllowed | Should -BeFalse
        $result.resolvedBeforeCompilerCount | Should -Be 0
    }
    It 'never demotes an after compiler finding to resolved before or unchanged legacy' {
        $document = New-StructuralLog ($sampleLine + "`r`n" + (New-NativeCompilerPair))
        $result = Compare-ItlPlatformStructuralDiagnostics -Before $document -After $document -BindingMatched $true -CompilationPassedAfter $true -ChangedOwners @($compilerOwner) -UnchangedOwnersProof @((New-StructuralOwnerProof $sampleOwner),(New-StructuralOwnerProof $compilerOwner))
        $result.applyAllowed | Should -BeFalse
        $result.resolvedBeforeCompilerCount | Should -Be 0
        $result.legacyDiagnosticCount | Should -Be 1
        @($result.unresolvedDiagnostics | Where-Object source -eq 'after')[0].reason | Should -BeExactly 'current-compiler-diagnostic'
    }
    It 'rejects unknown text and incomplete native compiler pairing for <Case>' -ForEach @(
        @{Case='missing context';Shape='incomplete'},
        @{Case='unsupported runtime mode';Shape='wrong-mode'},
        @{Case='wrong context statement';Shape='wrong-statement'},
        @{Case='context without native indentation';Shape='unindented'},
        @{Case='unknown preceding line';Shape='unknown-first'},
        @{Case='nonexact repository notice';Shape='modified-notice'}
    ) {
        $pair = New-NativeCompilerPair
        switch ($Shape) {
            incomplete { $pair = $pair.Split([char]13)[0] + "`r`n" }
            wrong-mode { $pair = New-NativeCompilerPair 'Веб-клиент' }
            wrong-statement { $pair = $pair.Replace('ВОзврат','Сообщить') }
            unindented { $pair = $pair.Replace("`t",'') }
            unknown-first { $pair = 'Неизвестный итог 101' + "`r`n" + $pair }
            modified-notice { $pair = $repositoryNotice + '. Ошибка доступа' + "`r`n" + $pair }
        }
        $before = New-StructuralLog ($sampleLine + "`r`n" + $pair)
        $after = New-StructuralLog $sampleLine
        $before.unresolvedDiagnosticCount | Should -BeGreaterThan 0
        $result = Compare-ItlPlatformStructuralDiagnostics -Before $before -After $after -BindingMatched $true -CompilationPassedAfter $true -ChangedOwners @($compilerOwner) -UnchangedOwnersProof @(New-StructuralOwnerProof $sampleOwner)
        $result.applyAllowed | Should -BeFalse
        $result.unresolvedDiagnosticCount | Should -BeGreaterThan 0
    }
    It 'retains duplicate compiler occurrences with complete raw header and context' {
        $pair = New-NativeCompilerPair
        $document = New-StructuralLog ($pair + $pair) -Bom
        $document.compilerDiagnosticCount | Should -Be 2
        $document.compilerDiagnostics | Should -HaveCount 1
        $finding = $document.compilerDiagnostics[0]
        $finding.count | Should -Be 2
        $finding.lineNumbers | Should -HaveCount 2
        $finding.rawLines[1] | Should -BeExactly ("`t" + 'ВОзврат ТекстСообщения<<?>>; (Проверка: Сервер)')
    }
    It 'reparses raw compiler findings after callers clear mutable projection arrays' {
        $before = New-StructuralLog $sampleLine
        $after = New-StructuralLog ($sampleLine + "`r`n" + (New-NativeCompilerPair))
        $after.compilerDiagnostics = @(); $after.compilerDiagnosticCount = 0
        $result = Compare-ItlPlatformStructuralDiagnostics -Before $before -After $after -BindingMatched $true -CompilationPassedAfter $true -ChangedOwners @($compilerOwner) -UnchangedOwnersProof @(New-StructuralOwnerProof $sampleOwner)
        $result.applyAllowed | Should -BeFalse
        @($result.unresolvedDiagnostics | Where-Object source -eq 'after')[0].reason | Should -BeExactly 'current-compiler-diagnostic'
    }
}

Describe 'Operation-local platform structural diagnostics' {
    It 'retains all 631 native-category occurrences and exact UTF8 BOM CRLF raw input' {
        $cases = @(
            @{owner='ОбщийМодуль.Свойства.Модуль';category='Возможно ошибочное свойство';count=261},
            @{owner='ОбщийМодуль.Методы.Модуль';category='Возможно ошибочный метод';count=95},
            @{owner='ОбщийМодуль.Параметры.Модуль';category='Возможно ошибочный параметр';count=42},
            @{owner='Справочник.Объект.Форма.ФормаЭлемента.Форма';category='Отсутствует обработчик';count=216},
            @{owner='РегистрСведений.Ссылки';category='Неразрешимые ссылки на объекты метаданных';count=11},
            @{owner='ОбщаяКартинка.Рисунок';category='Неразрешимые ссылки на картинки';count=2},
            @{owner='ОпределяемыйТип.Тип';category='Неразрешимые ссылки на типы';count=2},
            @{owner='Стиль.Основной.Стиль';category='Неразрешимые ссылки на элементы стиля';count=2}
        )
        $lines = [Collections.Generic.List[string]]::new()
        foreach ($case in $cases) {
            for($i=0;$i -lt $case.count;$i++) { $lines.Add($case.owner + ' ' + $case.category + ' (1)') }
        }
        $text = ($lines -join "`r`n") + "`r`n"
        $before = New-StructuralLog -Text $text -Bom
        $after = New-StructuralLog -Text $text -Bom
        $before.rawText | Should -BeExactly ([string][char]0xFEFF + $text)
        $before.rawSha256 | Should -BeExactly ((Get-FileHash -LiteralPath $before.logPath).Hash.ToLowerInvariant())
        $before.knownDiagnosticCount | Should -Be 631
        @($before.knownDiagnostics) | Should -HaveCount 8
        $before.unresolvedDiagnosticCount | Should -Be 0
        @($before.knownDiagnostics | Where-Object severity -cne 'native-unknown') | Should -HaveCount 0
        foreach ($case in $cases) {
            @($before.knownDiagnostics | Where-Object category -ceq $case.category)[0].count | Should -Be $case.count
        }
        $proofs = @($cases | ForEach-Object { New-StructuralOwnerProof $_.owner })
        $result = Compare-ItlPlatformStructuralDiagnostics -Before $before -After $after -BindingMatched $true -ChangedOwners @('ОбщийМодуль.Измененный.Модуль') -UnchangedOwnersProof $proofs
        $result.applyAllowed | Should -BeTrue
        $result.cleanPassed | Should -BeFalse
        $result.status | Should -BeExactly 'accepted-with-preexisting-findings'
        $result.legacyDiagnosticCount | Should -Be 631
        $result.newDiagnosticCount | Should -Be 0
        $result.unresolvedDiagnosticCount | Should -Be 0
    }

    It 'preserves a known finding and unknown warning beside success fragments' {
        $text = "Ошибок: 0; предупреждений: 0`r`nПроверка завершена.`r`nОшибок не обнаружено. $sampleLine`r`nNo warnings; WARNING: неизвестная диагностика`r`n"
        $document = New-StructuralLog $text
        $document.rawText | Should -BeExactly $text
        $document.knownDiagnosticCount | Should -Be 1
        $document.knownDiagnostics[0].line | Should -BeExactly ('Ошибок не обнаружено. ' + $sampleLine)
        $document.unresolvedDiagnosticCount | Should -Be 1
        $document.unresolvedDiagnostics[0].line | Should -BeExactly 'No warnings; WARNING: неизвестная диагностика'
        @($document.informationalLines) | Should -HaveCount 2
        $result = Compare-ItlPlatformStructuralDiagnostics -Before $document -After $document -BindingMatched $true -ChangedOwners @() -UnchangedOwnersProof @(New-StructuralOwnerProof $sampleOwner)
        $result.applyAllowed | Should -BeFalse
        $result.cleanPassed | Should -BeFalse
        $result.status | Should -BeExactly 'unresolved'
    }

    It 'does not hide positive counts leading zeros or an unknown success-looking suffix' {
        $document = New-StructuralLog "Ошибок: 0; предупреждений: 01`r`nNo errors; another result cannot be established`r`nПроверка завершена. Ошибка: отказ`r`n"
        $document.knownDiagnosticCount | Should -Be 0
        $document.unresolvedDiagnosticCount | Should -Be 3
        @($document.informationalLines) | Should -HaveCount 0
    }

    It 'rejects invalid UTF8 without changing the log bytes' {
        $path = Join-Path $TestDrive 'Неверный UTF8 с пробелом.log'
        $bytes = [byte[]]@(0xFF,0xFE,0xFF)
        [IO.File]::WriteAllBytes($path,$bytes)
        { Get-ItlPlatformStructuralDiagnostics -LogPath $path } | Should -Throw '*PLATFORM_DIAGNOSTICS_UTF8_INVALID*'
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) | Should -BeExactly ([Convert]::ToBase64String($bytes))
    }

    It 'does not accept matching diagnostics when the baseline binding is unproved' {
        $document = New-StructuralLog $sampleLine
        $result = Compare-ItlPlatformStructuralDiagnostics -Before $document -After $document -BindingMatched $false -ChangedOwners @() -UnchangedOwnersProof @(New-StructuralOwnerProof $sampleOwner)
        $result.applyAllowed | Should -BeFalse
        $result.legacyDiagnosticCount | Should -Be 0
        $result.issues | Should -Contain 'baseline-binding-unproved'
    }

    It 'gives changed and affected owners priority over a matching unchanged hash' {
        $document = New-StructuralLog $sampleLine
        $result = Compare-ItlPlatformStructuralDiagnostics -Before $document -After $document -BindingMatched $true -ChangedOwners @($sampleOwner) -UnchangedOwnersProof @(New-StructuralOwnerProof $sampleOwner)
        $result.applyAllowed | Should -BeFalse
        $result.legacyDiagnosticCount | Should -Be 0
        $result.unresolvedDiagnostics[0].reason | Should -BeExactly 'inside-changed-or-impact-scope'
    }

    It 'matches hashed source-object parents while preserving the full native owner' {
        $moduleOwner='ОбщийМодуль.Логика.Модуль'
        $formOwner='Обработка.Editor.Форма.Main.Форма'
        $document=New-StructuralLog ($moduleOwner + ' Возможно ошибочный метод: "Missing"' + "`r`n" + $formOwner + ' Отсутствует обработчик: Missing "Missing"') -Bom
        $proofs=@((New-StructuralOwnerProof 'ОбщийМодуль.Логика'),(New-StructuralOwnerProof 'Обработка.Editor'),(New-StructuralOwnerProof 'Обработка.Editor.Форма.Main'))
        $result=Compare-ItlPlatformStructuralDiagnostics -Before $document -After $document -BindingMatched $true -ChangedOwners @() -UnchangedOwnersProof $proofs
        $result.applyAllowed | Should -BeTrue
        $result.legacyDiagnosticCount | Should -Be 2
        $moduleFinding=@($result.legacyDiagnostics | Where-Object {$_.owner -ceq $moduleOwner})[0]
        $formFinding=@($result.legacyDiagnostics | Where-Object {$_.owner -ceq $formOwner})[0]
        $moduleFinding.proofOwner | Should -BeExactly 'ОбщийМодуль.Логика'
        $formFinding.proofOwner | Should -BeExactly 'Обработка.Editor.Форма.Main'
        $formFinding.identity | Should -BeExactly ($formOwner + ' Отсутствует обработчик: Missing "Missing"')
        $changed=Compare-ItlPlatformStructuralDiagnostics -Before $document -After $document -BindingMatched $true -ChangedOwners @('Обработка.Editor') -UnchangedOwnersProof $proofs
        $changed.applyAllowed | Should -BeFalse
        $changed.unresolvedDiagnosticCount | Should -Be 1
        $changed.unresolvedDiagnostics[0].owner | Should -BeExactly $formOwner
        $changed.unresolvedDiagnostics[0].reason | Should -BeExactly 'inside-changed-or-impact-scope'
    }

    It 'does not confuse source-object name prefixes with a dotted owner boundary' {
        $owner='Обработка.X2.Форма.Main.Форма'
        $document=New-StructuralLog ($owner + ' Отсутствует обработчик: Missing "Missing"')
        $missing=Compare-ItlPlatformStructuralDiagnostics -Before $document -After $document -BindingMatched $true -ChangedOwners @() -UnchangedOwnersProof @(New-StructuralOwnerProof 'Обработка.X')
        $missing.applyAllowed | Should -BeFalse
        $missing.unresolvedDiagnostics[0].reason | Should -BeExactly 'unchanged-owner-hash-unproved'
        $separate=Compare-ItlPlatformStructuralDiagnostics -Before $document -After $document -BindingMatched $true -ChangedOwners @('Обработка.X') -UnchangedOwnersProof @(New-StructuralOwnerProof 'Обработка.X2')
        $separate.applyAllowed | Should -BeTrue
        $separate.legacyDiagnostics[0].owner | Should -BeExactly $owner
        $separate.legacyDiagnostics[0].proofOwner | Should -BeExactly 'Обработка.X2'
    }

    It 'requires exact unchanged-owner hashes for <Case>' -ForEach @(
        @{Case='missing proof';ProofKind='missing'},
        @{Case='changed bytes';ProofKind='changed'},
        @{Case='invalid hash';ProofKind='invalid'},
        @{Case='duplicate owner';ProofKind='duplicate'},
        @{Case='different owner case';ProofKind='case'}
    ) {
        $document = New-StructuralLog $sampleLine
        $proof = New-StructuralOwnerProof $sampleOwner
        $proofs = @($proof)
        switch ($ProofKind) {
            missing { $proofs=@() }
            changed { $proof.afterSha256='b' * 64 }
            invalid { $proof.beforeSha256='not-a-sha' }
            duplicate { $proofs=@($proof,(New-StructuralOwnerProof $sampleOwner)) }
            case { $proof.owner=$sampleOwner.ToUpperInvariant() }
        }
        $result = Compare-ItlPlatformStructuralDiagnostics -Before $document -After $document -BindingMatched $true -ChangedOwners @() -UnchangedOwnersProof $proofs
        $result.applyAllowed | Should -BeFalse
        $result.cleanPassed | Should -BeFalse
        $result.legacyDiagnosticCount | Should -Be 0
    }

    It 'rejects a same-count replacement and a newly added finding' {
        $before = New-StructuralLog $sampleLine
        $replacement = New-StructuralLog ($sampleLine.Replace('ОтсутствующийМетод','ДругойМетод'))
        $proofs = @(New-StructuralOwnerProof $sampleOwner)
        $swapped = Compare-ItlPlatformStructuralDiagnostics -Before $before -After $replacement -BindingMatched $true -ChangedOwners @() -UnchangedOwnersProof $proofs
        $swapped.applyAllowed | Should -BeFalse
        $swapped.newDiagnosticCount | Should -Be 1
        $swapped.legacyDiagnosticCount | Should -Be 0
        $added = New-StructuralLog ($sampleLine + "`r`n" + $replacement.rawText)
        $result = Compare-ItlPlatformStructuralDiagnostics -Before $before -After $added -BindingMatched $true -ChangedOwners @() -UnchangedOwnersProof $proofs
        $result.applyAllowed | Should -BeFalse
        $result.legacyDiagnosticCount | Should -Be 1
        $result.newDiagnosticCount | Should -Be 1
    }

    It 'rejects strengthened duplicate counts and changed remaining multiplicity' {
        $before = New-StructuralLog $sampleLine
        $after = New-StructuralLog ($sampleLine + "`r`n" + $sampleLine)
        $proofs = @(New-StructuralOwnerProof $sampleOwner)
        $increased = Compare-ItlPlatformStructuralDiagnostics -Before $before -After $after -BindingMatched $true -ChangedOwners @() -UnchangedOwnersProof $proofs
        $increased.applyAllowed | Should -BeFalse
        $increased.unresolvedDiagnosticCount | Should -Be 2
        $increased.unresolvedDiagnostics[0].reason | Should -BeExactly 'diagnostic-occurrence-count-changed'
        $reduced = Compare-ItlPlatformStructuralDiagnostics -Before $after -After $before -BindingMatched $true -ChangedOwners @() -UnchangedOwnersProof $proofs
        $reduced.applyAllowed | Should -BeFalse
        $reduced.unresolvedDiagnosticCount | Should -Be 1
    }

    It 'does not use a baseline with unexplained text as complete legacy evidence' {
        $before = New-StructuralLog ($sampleLine + "`r`n" + 'Неизвестный итог 101')
        $after = New-StructuralLog $sampleLine
        $result = Compare-ItlPlatformStructuralDiagnostics -Before $before -After $after -BindingMatched $true -ChangedOwners @() -UnchangedOwnersProof @(New-StructuralOwnerProof $sampleOwner)
        $result.applyAllowed | Should -BeFalse
        $result.unresolvedDiagnostics[0].source | Should -BeExactly 'before'
    }

    It 'reparses raw text rather than trusting altered projection counts or arrays' {
        $before = New-StructuralLog $sampleLine
        $after = New-StructuralLog ($sampleLine + "`r`n" + 'Unknown warning')
        $after.unresolvedDiagnostics=@()
        $after.unresolvedDiagnosticCount=0
        $result = Compare-ItlPlatformStructuralDiagnostics -Before $before -After $after -BindingMatched $true -ChangedOwners @() -UnchangedOwnersProof @(New-StructuralOwnerProof $sampleOwner)
        $result.applyAllowed | Should -BeFalse
        $result.unresolvedDiagnosticCount | Should -Be 1
        $after.rawText=$sampleLine
        $mismatch = Compare-ItlPlatformStructuralDiagnostics -Before $before -After $after -BindingMatched $true -ChangedOwners @() -UnchangedOwnersProof @(New-StructuralOwnerProof $sampleOwner)
        $mismatch.applyAllowed | Should -BeFalse
        $mismatch.issues | Should -Contain 'after-raw-hash-mismatch'
    }

    It 'preserves plain JSON roundtrip structs and does not claim native clean passage' {
        $document = New-StructuralLog $sampleLine -Bom
        $roundtrip = $document | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $proof = New-StructuralOwnerProof $sampleOwner
        $result = Compare-ItlPlatformStructuralDiagnostics -Before $document -After $roundtrip -BindingMatched $true -ChangedOwners @() -UnchangedOwnersProof @($proof)
        $result.applyAllowed | Should -BeTrue
        $result.cleanPassed | Should -BeFalse
        $result.schemaVersion | Should -Be 1
        $result.beforeRawSha256 | Should -BeExactly $result.afterRawSha256
        $clean = New-StructuralLog "Ошибок: 0; предупреждений: 0`r`n"
        $notApplicable = Compare-ItlPlatformStructuralDiagnostics -Before $document -After $clean -BindingMatched $true -ChangedOwners @() -UnchangedOwnersProof @($proof)
        $notApplicable.applyAllowed | Should -BeFalse
        $notApplicable.cleanPassed | Should -BeFalse
        $notApplicable.status | Should -BeExactly 'not-applicable-clean'
    }
}
