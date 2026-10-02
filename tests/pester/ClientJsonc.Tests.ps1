BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    . (Join-Path $repoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.jsonc.ps1')
}

Describe 'Lossless client JSONC text operations' {
    It 'exposes semantic last-wins values and exact UTF-16 syntax and trivia spans' {
        $text = [string][char]0xFEFF + "{`r`n`t// Кириллица с пробелом`r`n`t""mcp"": {""x"": 1, /* second */ ""x"": 2,},`r`n`t""list"": [true, null, -1.5e2,],`r`n}`r`n"
        $document = Read-ItlJsoncDocument -Text $text
        $document.Text | Should -BeExactly $text
        $document.Format.HasBom | Should -BeTrue
        $document.Format.NewLine | Should -BeExactly "`r`n"
        $document.Value['mcp']['x'] | Should -Be 2
        $document.Value['list'].Count | Should -Be 3
        $document.Value['list'][0] | Should -BeTrue
        $document.Value['list'][1] | Should -BeNullOrEmpty
        $document.Value['list'][2] | Should -Be -150
        (($document.Tokens | ForEach-Object { $_.Text }) -join '') | Should -BeExactly $text
        foreach ($token in $document.Tokens) {
            $text.Substring($token.Start, $token.End - $token.Start) | Should -BeExactly $token.Text
        }
        $node = $document.Root.Members[0].Value
        $node.Members.Count | Should -Be 2
        $text.Substring($node.Start, $node.End - $node.Start) | Should -BeExactly '{"x": 1, /* second */ "x": 2,}'
    }

    It 'keeps commas comment markers URLs escaped quotes and Unicode escapes inside strings literal' {
        $text = '{"url":"https://example.invalid/a//b?x=,}&y=,]","text":"/*literal*/ //literal quote \" slash \\","unicode":"\u041f\u0443\u0442\u044c с пробелом","array":["a,]","b,}",],}'
        $document = Read-ItlJsoncDocument -Text $text
        $document.Value['url'] | Should -BeExactly 'https://example.invalid/a//b?x=,}&y=,]'
        $document.Value['text'] | Should -BeExactly '/*literal*/ //literal quote " slash \'
        $document.Value['unicode'] | Should -BeExactly 'Путь с пробелом'
        $document.Value['array'][0] | Should -BeExactly 'a,]'
        (Set-ItlJsoncObjectProperty -Text $text -PropertyPath @('unicode') -Value 'Путь с пробелом') | Should -BeExactly $text
    }

    It 'replaces only the selected value while preserving BOM CRLF and all surrounding foreign bytes' {
        $text = [string][char]0xFEFF + "{`r`n  // user comment`r`n  ""mcp"": { /* before */ ""owned"" : /* value comment */ ""old-value"" /* after */, ""foreign"": {""url"":""https://host/a,}""}, },`r`n  ""permission"": {""*"":""ask""},`r`n}`r`n"
        $expected = $text.Replace('"old-value"', '"new-value"')
        $changed = Set-ItlJsoncObjectProperty -Text $text -PropertyPath @('mcp', 'owned') -Value 'new-value'
        $changed | Should -BeExactly $expected
        (Set-ItlJsoncObjectProperty -Text $changed -PropertyPath @('mcp', 'owned') -Value 'new-value') | Should -BeExactly $changed
        (Read-ItlJsoncDocument -Text $changed).Value['mcp']['foreign']['url'] | Should -BeExactly 'https://host/a,}'
    }

    It 'preserves commented object formatting on a semantic no-op with reordered input keys' {
        $text = '{"mcp":{"owned": {"args":["один с пробелом", /* argument */ "два"], "enabled":true,},},}'
        $value = [ordered]@{ enabled = $true; args = @('один с пробелом', 'два') }
        (Set-ItlJsoncObjectProperty -Text $text -PropertyPath @('mcp', 'owned') -Value $value) | Should -BeExactly $text
    }

    It 'creates missing object ancestors without replacing neighboring config or comments' {
        $text = "{`r`n  // retain`r`n  ""permission"": ""ask"" // end of foreign value`r`n}`r`n"
        $value = [ordered]@{ command = @('C:\Путь с пробелом\tool.exe', '--stdio'); enabled = $true }
        $changed = Set-ItlJsoncObjectProperty -Text $text -PropertyPath @('mcp', 'owned', 'local') -Value $value
        $document = Read-ItlJsoncDocument -Text $changed
        $document.Value['mcp']['owned']['local']['command'][0] | Should -BeExactly 'C:\Путь с пробелом\tool.exe'
        $document.Value['permission'] | Should -BeExactly 'ask'
        $changed.Contains('// retain') | Should -BeTrue
        $changed.Contains('"permission": "ask", // end of foreign value') | Should -BeTrue
        $changed.EndsWith("}`r`n") | Should -BeTrue
        (Set-ItlJsoncObjectProperty -Text $changed -PropertyPath @('mcp', 'owned', 'local') -Value $value) | Should -BeExactly $changed
    }

    It 'inserts into compact adjacent braces without swapping the new property and separator' {
        $text = '{"mcp":{"foreign":{"enabled":true}}}'
        $changed = Set-ItlJsoncObjectProperty -Text $text -PropertyPath @('mcp', 'owned') -Value @{ enabled = $false }
        $document = Read-ItlJsoncDocument -Text $changed
        $document.Value['mcp']['foreign']['enabled'] | Should -BeTrue
        $document.Value['mcp']['owned']['enabled'] | Should -BeFalse
        $changed.StartsWith('{"mcp":{"foreign":{"enabled":true},') | Should -BeTrue
    }

    It 'retains the existing trailing comma style and neighboring comments during insertion' {
        $text = "{`r`n`t""mcp"": {`r`n`t`t""foreign"": true, // tail`r`n`t},`r`n}`r`n"
        $changed = Set-ItlJsoncObjectProperty -Text $text -PropertyPath @('mcp', 'owned') -Value $null
        $changed | Should -BeExactly ($text.Replace("`t},", "`t`t""owned"": null,`r`n`t},"))
        (Read-ItlJsoncDocument -Text $changed).Value['mcp'].ContainsKey('owned') | Should -BeTrue
    }

    It 'inserts into an empty commented object and escapes arbitrary property names' {
        $text = '{"mcp": { /* not a property */ }}'
        $name = 'Путь с пробелом " \'
        $changed = Set-ItlJsoncObjectProperty -Text $text -PropertyPath @('mcp', $name, '') -Value 7
        (Read-ItlJsoncDocument -Text $changed).Value['mcp'][$name][''] | Should -Be 7
        $changed.Contains('/* not a property */') | Should -BeTrue
    }

    It 'accepts legal <Case> JSON values without PowerShell binding changing their type' -ForEach @(
        @{ Case = 'empty string'; InputValue = ''; Expected = '{"owned": ""}' },
        @{ Case = 'empty array'; InputValue = @(); Expected = '{"owned": []}' },
        @{ Case = 'false'; InputValue = $false; Expected = '{"owned": false}' },
        @{ Case = 'zero'; InputValue = 0; Expected = '{"owned": 0}' }
    ) {
        $changed = Set-ItlJsoncObjectProperty -Text '{}' -PropertyPath @('owned') -Value $InputValue
        $changed | Should -BeExactly $Expected
        (Set-ItlJsoncObjectProperty -Text $changed -PropertyPath @('owned') -Value $InputValue) | Should -BeExactly $changed
    }

    It 'removes <Case> without consuming adjacent comments or foreign properties' -ForEach @(
        @{ Case = 'first'; Text = '{"target":0,/* next */"keep":1}'; Expected = '{/* next */"keep":1}' },
        @{ Case = 'last'; Text = '{"keep":1,/* prev */"target":0/* after */}'; Expected = '{"keep":1/* prev *//* after */}' },
        @{ Case = 'middle'; Text = '{"a":1,/* left */"target":0,/* right */"z":2}'; Expected = '{"a":1,/* left *//* right */"z":2}' },
        @{ Case = 'trailing'; Text = '{"keep":1,"target":0,/* close */}'; Expected = '{"keep":1,/* close */}' },
        @{ Case = 'only'; Text = "{//lead`r`n""target"":0,/* tail */}"; Expected = "{//lead`r`n/* tail */}" }
    ) {
        $changed = Remove-ItlJsoncObjectProperty -Text $Text -PropertyPath @('target')
        $changed | Should -BeExactly $Expected
        (Remove-ItlJsoncObjectProperty -Text $changed -PropertyPath @('target')) | Should -BeExactly $changed
        (Read-ItlJsoncDocument -Text $changed).Value.ContainsKey('target') | Should -BeFalse
    }

    It 'removes a nested server without touching external MCP or permissions' {
        $text = [string][char]0xFEFF + "{`r`n ""mcp"": {""external"": {""url"":""https://host/api//v1""}, /* user */ ""owned"": {""args"":[]}},`r`n ""permission"": ""ask""`r`n}`r`n"
        $changed = Remove-ItlJsoncObjectProperty -Text $text -PropertyPath @('mcp', 'owned')
        $changed | Should -BeExactly ($text.Replace(', /* user */ "owned": {"args":[]}', ' /* user */ '))
        (Read-ItlJsoncDocument -Text $changed).Value['mcp']['external']['url'] | Should -BeExactly 'https://host/api//v1'
    }

    It 'reads unrelated duplicates with last-wins semantics and edits a distinct property' {
        $text = '{"foreign":1,/* retained */"foreign":2,"mcp":{}}'
        $changed = Set-ItlJsoncObjectProperty -Text $text -PropertyPath @('mcp', 'owned') -Value $true
        $changed.StartsWith('{"foreign":1,/* retained */"foreign":2,') | Should -BeTrue
        (Read-ItlJsoncDocument -Text $changed).Value['foreign'] | Should -Be 2
        (Read-ItlJsoncDocument -Text $changed).Root.Members.Count | Should -Be 3
    }

    It 'refuses ambiguous <Case> for both editors without changing the input text' -ForEach @(
        @{ Case = 'ancestor'; Text = '{"mcp":{},"mcp":{}}'; Path = @('mcp', 'owned') },
        @{ Case = 'leaf'; Text = '{"mcp":{"owned":1,"owned":2}}'; Path = @('mcp', 'owned') },
        @{ Case = 'escaped name'; Text = '{"mcp":{"owned":1,"\u006fwned":2}}'; Path = @('mcp', 'owned') }
    ) {
        $before = $Text
        { Set-ItlJsoncObjectProperty -Text $Text -PropertyPath $Path -Value 3 } | Should -Throw '*CLIENT_JSONC_AMBIGUOUS_PROPERTY*'
        { Remove-ItlJsoncObjectProperty -Text $Text -PropertyPath $Path } | Should -Throw '*CLIENT_JSONC_AMBIGUOUS_PROPERTY*'
        $Text | Should -BeExactly $before
    }

    It 'treats property names as ordinal and does not coalesce case-distinct keys' {
        $text = '{"mcp":{"Owned":1,"owned":2}}'
        $changed = Set-ItlJsoncObjectProperty -Text $text -PropertyPath @('mcp', 'owned') -Value 3
        $changed | Should -BeExactly '{"mcp":{"Owned":1,"owned":3}}'
        (Remove-ItlJsoncObjectProperty -Text $changed -PropertyPath @('mcp', 'owned')) | Should -BeExactly '{"mcp":{"Owned":1}}'
    }

    It 'does not replace scalar ancestors and makes absent-path removal a no-op' {
        $text = '{"mcp":"user scalar","permission":"ask"}'
        { Set-ItlJsoncObjectProperty -Text $text -PropertyPath @('mcp', 'owned') -Value 1 } | Should -Throw '*CLIENT_JSONC_EXPECTED_OBJECT*'
        (Remove-ItlJsoncObjectProperty -Text $text -PropertyPath @('mcp', 'owned')) | Should -BeExactly $text
        (Remove-ItlJsoncObjectProperty -Text $text -PropertyPath @('missing', 'owned')) | Should -BeExactly $text
    }

    It 'rejects an empty edit path with a typed failure' {
        { Set-ItlJsoncObjectProperty -Text '{}' -PropertyPath @() -Value 1 } | Should -Throw '*CLIENT_JSONC_PROPERTY_PATH_INVALID*'
        { Remove-ItlJsoncObjectProperty -Text '{}' -PropertyPath @() } | Should -Throw '*CLIENT_JSONC_PROPERTY_PATH_INVALID*'
    }

    It 'rejects malformed JSONC <Case> rather than rewriting or globally stripping commas' -ForEach @(
        @{ Case = 'unterminated comment'; Text = '{/* open' },
        @{ Case = 'unterminated string'; Text = '{"a":"open}' },
        @{ Case = 'bad escape'; Text = '{"a":"\q"}' },
        @{ Case = 'bad number'; Text = '{"a":01}' },
        @{ Case = 'missing comma'; Text = '{"a":1 "b":2}' },
        @{ Case = 'repeated comma'; Text = '{"a":1,,}' },
        @{ Case = 'extra root'; Text = '{}[]' },
        @{ Case = 'unquoted key'; Text = '{a:1}' }
    ) {
        { Read-ItlJsoncDocument -Text $Text } | Should -Throw '*CLIENT_JSONC_INVALID*'
        { Set-ItlJsoncObjectProperty -Text $Text -PropertyPath @('owned') -Value 1 } | Should -Throw '*CLIENT_JSONC_INVALID*'
    }

    It 'keeps the byte transport contract in a BOM CRLF fixture with Cyrillic and whitespace' {
        $fixture = Join-Path $TestDrive 'Клиент JSONC с пробелом/opencode.jsonc'
        [IO.Directory]::CreateDirectory((Split-Path -Parent $fixture)) | Out-Null
        $utf8 = [Text.UTF8Encoding]::new($false, $true)
        $original = [string][char]0xFEFF + "{`r`n // Пользовательский комментарий`r`n ""mcp"": {""owned"": false, ""external"": ""https://example/api,}""},`r`n}`r`n"
        [IO.File]::WriteAllBytes($fixture, $utf8.GetBytes($original))
        $before = [IO.File]::ReadAllBytes($fixture)
        $text = $utf8.GetString($before)
        $changed = Set-ItlJsoncObjectProperty -Text $text -PropertyPath @('mcp', 'owned') -Value $true
        $expected = $original.Replace('"owned": false', '"owned": true')
        [Convert]::ToBase64String($utf8.GetBytes($changed)) | Should -BeExactly ([Convert]::ToBase64String($utf8.GetBytes($expected)))
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture)) | Should -BeExactly ([Convert]::ToBase64String($before))
    }
}
