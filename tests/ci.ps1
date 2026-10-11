# What the GitHub Actions workflow runs, on both PowerShell editions.
# Pester tests first, then a real (read-only) scan of the runner.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]'5.5' })) {
    Install-PackageProvider NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    Install-Module Pester -MinimumVersion 5.5 -Force -Scope CurrentUser -SkipPublisherCheck
}
Import-Module Pester -MinimumVersion 5.5
Write-Host "PowerShell $($PSVersionTable.PSVersion), Pester $((Get-Module Pester).Version)"

$c = New-PesterConfiguration
$c.Run.Path = (Join-Path $repo 'tests')
$c.Run.PassThru = $true
$c.Output.Verbosity = 'Detailed'
$r = Invoke-Pester -Configuration $c
if ($r.FailedCount) { throw "$($r.FailedCount) test(s) failed" }

# smoke scan: no html, no winget (slow on runners), json out
$ErrorActionPreference = 'Continue'
& (Join-Path $repo 'list-coding-agents.ps1') -NoHtml -SkipWinget -Json -ShowReasons
$jsonPath = Join-Path $repo 'coding-agents.json'
if (-not (Test-Path $jsonPath)) { throw 'no coding-agents.json written' }
$null = Get-Content $jsonPath -Raw | ConvertFrom-Json
Write-Host 'json parses ok'
