$script:ReleaseE2EStageDefinitions = [ordered]@{}

function Register-ReleaseE2EStageDefinition {
    param([string]$Name, [int]$Version, [string[]]$Paths, [string[]]$DependsOn = @(), [string]$ModuleFile = "")
    $script:ReleaseE2EStageDefinitions[$Name] = [ordered]@{
        name = $Name
        version = $Version
        moduleFile = $(if ($ModuleFile) { $ModuleFile } else { "$Name.ps1" })
        paths = @($Paths)
        dependsOn = @($DependsOn)
    }
}
