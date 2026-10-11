# PSScriptAnalyzer settings for src/, build.ps1 and the built bundle.
# Gate: 0 errors and 0 warnings. Every in-code suppression must carry a
# Justification (e.g. Write-Host is allowed in the console renderer only).
@{
    Severity     = @('Error', 'Warning')
    IncludeDefaultRules = $true
    Rules        = @{
        # Windows PowerShell 5.1 and PowerShell 7.4+ must both parse every file.
        # The analyzer misses some 5.1 gaps (?. / ?[], multi-child Join-Path,
        # clean {}, $IsWindows); tests/Compat/Syntax51.Tests.ps1 covers those.
        PSUseCompatibleSyntax   = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.4')
        }
        PSUseCompatibleCommands = @{
            Enable         = $true
            TargetProfiles = @(
                'win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework',
                'win-8_x64_10.0.17763.0_7.0.0_x64_3.1.2_core',
                'ubuntu_x64_18.04_7.0.0_x64_3.1.2_core'
            )
        }
    }
}
