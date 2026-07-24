Describe "Bounded static managed-form element context" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $ScriptPath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\get-form-element-context.ps1"
        $FixtureRoot = Join-Path $RepoRoot "tests\pester\fixtures\form-element-context"
    }

    It "returns exact compact context with outer-to-inner Group Pages Page ancestry" {
        $json = & $ScriptPath -ProjectRoot $FixtureRoot -SourcePath "Form.xml" -ElementName @("MultiField", "UnknownField", "FalseField")
        $json | Should -Not -Match "SECRET-FULL-XML-MARKER"
        $result = $json | ConvertFrom-Json

        $result.schemaVersion | Should -Be 1
        $result.sourcePath | Should -Be "Form.xml"
        @($result.records).Count | Should -Be 3

        $multi = $result.records[0]
        $multi.name | Should -Be "MultiField"
        $multi.status | Should -Be "found"
        $multi.elementType | Should -Be "InputField"
        $multi.dataPath | Should -Be "Object.Filters"
        $multi.extendedEditMultipleValues | Should -BeTrue
        @($multi.ancestors | ForEach-Object { "$($_.kind):$($_.name)" }) | Should -Be @(
            "Group:OuterGroup",
            "Pages:ModePages",
            "Page:FirstPage"
        )
        $multi.ancestorsTruncated | Should -BeFalse

        $result.records[1].extendedEditMultipleValues | Should -BeNullOrEmpty
        $result.records[2].extendedEditMultipleValues | Should -BeFalse
    }

    It "fails closed for missing and duplicate exact source names without returning source values" {
        $json = & $ScriptPath -ProjectRoot $FixtureRoot -SourcePath "Form.xml" -ElementName @("MissingField", "DuplicateField")
        $json | Should -Not -Match "FirstDuplicate|SecondDuplicate|SECRET-FULL-XML-MARKER"
        $result = $json | ConvertFrom-Json

        $result.records[0].status | Should -Be "missing"
        $result.records[0].matchCount | Should -Be 0
        $result.records[1].status | Should -Be "duplicate"
        $result.records[1].matchCount | Should -Be 2
        $result.records[1].dataPath | Should -BeNullOrEmpty
    }

    It "rejects traversal to a Form.xml outside ProjectRoot" {
        $tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-form-context-" + [guid]::NewGuid().ToString("N"))
        $projectRoot = Join-Path $tempBase "project"
        $outsideRoot = Join-Path $tempBase "outside"
        try {
            New-Item -ItemType Directory -Force -Path $projectRoot, $outsideRoot | Out-Null
            Copy-Item -LiteralPath (Join-Path $FixtureRoot "Form.xml") -Destination (Join-Path $outsideRoot "Form.xml")
            { & $ScriptPath -ProjectRoot $projectRoot -SourcePath "..\outside\Form.xml" -ElementName "MultiField" } |
                Should -Throw "*ITL_FORM_CONTEXT_SOURCE_OUTSIDE_PROJECT*"
        } finally {
            Remove-Item -LiteralPath $tempBase -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "rejects duplicate requested names before parsing source" {
        { & $ScriptPath -ProjectRoot $FixtureRoot -SourcePath "Form.xml" -ElementName @("MultiField", "MultiField") } |
            Should -Throw "*ITL_FORM_CONTEXT_NAME_DUPLICATE*"
    }

    It "bounds the number of requested records before parsing source" {
        $names = @(1..33 | ForEach-Object { "Field$_" })
        { & $ScriptPath -ProjectRoot $FixtureRoot -SourcePath "Form.xml" -ElementName $names } |
            Should -Throw "*ITL_FORM_CONTEXT_NAME_COUNT_INVALID*"
    }

}
