BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $script:RepoRoot 'scripts/source-proof-json.ps1')
}

Describe 'Source delivery proof JSON transport' {
    It 'retains precise date strings and offsets inside nested arrays' {
        $json = '{"at":"2026-10-10T20:33:00.7091234Z","items":[[],null,{"at":"2026-10-10T23:33:00.7091234+03:00"}]}'
        $value = ConvertFrom-DeliveryProofJson -Json $json
        $value.at | Should -BeOfType ([string])
        $value.at | Should -BeExactly '2026-10-10T20:33:00.7091234Z'
        $value.items[2].at | Should -BeExactly '2026-10-10T23:33:00.7091234+03:00'
        @($value.items).Count | Should -Be 3
        @($value.items[0]).Count | Should -Be 0
        $value.items[1] | Should -BeNullOrEmpty
    }

    It 'preserves large integer timings boolean values and Unicode path bytes' {
        $unicode = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('0L/Rg9GC0Yw='))
        $expected = [pscustomobject][ordered]@{
            path = "C:\proof path $unicode\file.json"
            timing = [int64]::MaxValue
            success = $true
            failed = $false
            empty = @()
        }
        $value = $expected | ConvertTo-DeliveryProofJson -Compress | ConvertFrom-DeliveryProofJson
        $value.path | Should -BeExactly $expected.path
        [string]$value.timing | Should -BeExactly ([string][int64]::MaxValue)
        $value.success | Should -BeTrue
        $value.failed | Should -BeFalse
        @($value.empty).Count | Should -Be 0
    }

    It 'writes the established Windows serializer bytes without escaping quotes as u0022' {
        $value = [pscustomobject][ordered]@{ message = "quote' <>& `"quoted`"" }
        $actual = $value | ConvertTo-DeliveryProofJson -Compress
        $actual | Should -BeExactly '{"message":"quote\u0027 \u003c\u003e\u0026 \"quoted\""}'
        ($actual | ConvertFrom-DeliveryProofJson).message | Should -BeExactly $value.message
    }

    It 'reconstructs the known legacy Core bytes while preserving literal escape text' {
        $value = [pscustomobject][ordered]@{ message = "quote' <>& `"quoted`""; literal = '\u0027'; prefixed = "\'" }
        $actual = $value | ConvertTo-DeliveryProofJson -Compress -LegacyCore
        $actual | Should -BeExactly '{"message":"quote'' <>& \"quoted\"","literal":"\\u0027","prefixed":"\\''"}'
        $roundtrip = $actual | ConvertFrom-DeliveryProofJson
        $roundtrip.literal | Should -BeExactly '\u0027'
        $roundtrip.prefixed | Should -BeExactly "\'"
    }

    It 'rejects malformed and trailing JSON instead of producing qualification data' {
        { ConvertFrom-DeliveryProofJson -Json '{"at":' } | Should -Throw
        { ConvertFrom-DeliveryProofJson -Json '{"at":true} trailing' } | Should -Throw
    }

    It 'preserves old Core date semantics through its existing Json.NET reader' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
        $json = '{"at":"2026-10-10T20:33:00.7091234Z","items":[[],null,{"at":"2026-10-10T23:33:00+03:00"}],"large":9223372036854775807}'
        $value = ConvertFrom-DeliveryProofJsonLegacyCore -Json $json
        $value.at | Should -BeOfType ([string])
        $value.at | Should -BeExactly '2026-10-10T20:33:00.7091234Z'
        $value.items[2].at | Should -BeExactly '2026-10-10T23:33:00+03:00'
        @($value.items[0]).Count | Should -Be 0
        $value.items[1] | Should -BeNullOrEmpty
        [string]$value.large | Should -BeExactly '9223372036854775807'
        { ConvertFrom-DeliveryProofJsonLegacyCore -Json '{"at":true} trailing' } | Should -Throw
    }
}
