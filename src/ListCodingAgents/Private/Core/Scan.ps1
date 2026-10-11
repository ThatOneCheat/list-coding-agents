# Scan orchestrator and fleet health. One function per workstream entry point:
#   Find-LcaAgent        (A Detection)  -> rows
#   Add-LcaEnrichment    (B Enrichment) -> sizes, usage, probes
#   Add-LcaUpdateInfo    (C Updates)    -> update status, update/uninstall commands
#   Read-LcaState / Get-LcaHistoryChange (D State) -> new / gone / trend

function Select-LcaAgentInScope {
    <#
    Display scope: CLIs always; editors with IncludeEditors; extensions with
    IncludeExtensions. Optional -Tier filter. Never used for history.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [AllowEmptyCollection()][object[]]$Agent = @(),
        [ValidateSet('detected', 'possible', 'any')][string]$Tier = 'any'
    )
    $o = $Context.Options
    $out = foreach ($a in @($Agent)) {
        if ($a.Tier -eq 'excluded') { continue }
        if ($Tier -ne 'any' -and $a.Tier -ne $Tier) { continue }
        if ($a.Kind -eq 'editor' -and -not $o.IncludeEditors) { continue }
        if ($a.Kind -eq 'extension' -and -not $o.IncludeExtensions) { continue }
        $a
    }
    @($out)
}

function Get-LcaFleetRank {
    [CmdletBinding()]
    [OutputType([string])]
    param([int]$Count)
    if ($Count -le 2) { return 'MINIMALIST' }
    if ($Count -le 5) { return 'COLLECTOR' }
    if ($Count -le 9) { return 'ENTHUSIAST' }
    if ($Count -le 13) { return 'CERTIFIED HOARDER' }
    'AGENT SINGULARITY'
}

function Get-LcaFleetHealth {
    <#
    Fleet numbers. The headline count, rank, disk total and trend use DETECTED
    CLIs only so they stay comparable between runs whatever the display
    switches; dead weight / conflicts / outdated cover the display scope.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)]$Context, [AllowEmptyCollection()][object[]]$Agent = @())
    $cli = @($Agent | Where-Object { $_.Tier -eq 'detected' -and $_.Kind -eq 'cli' })
    $scopeDetected = @(Select-LcaAgentInScope -Context $Context -Agent $Agent -Tier 'detected')
    $scopeAll = @(Select-LcaAgentInScope -Context $Context -Agent $Agent)
    $scopePossible = @($scopeAll | Where-Object { $_.Tier -eq 'possible' })
    $total = 0.0
    foreach ($a in $cli) { if ($a.InstallSizeMB) { $total += [double]$a.InstallSizeMB } }
    $dead = @($scopeDetected | Where-Object { $_.Usage -eq 'stale' })
    $reclaim = 0.0
    foreach ($a in $dead) { if ($a.InstallSizeMB) { $reclaim += [double]$a.InstallSizeMB } }
    $active = @($cli | Where-Object { $_.LastUsed -and ($Context.Now - $_.LastUsed).TotalDays -le 30 }).Count
    $channels = @($scopeDetected | ForEach-Object { $_.Method } | Select-Object -Unique).Count
    [pscustomobject]@{
        PSTypeName    = 'ListCodingAgents.FleetHealth'
        DetectedCount = $cli.Count
        ScopeDetected = $scopeDetected.Count
        PossibleCount = $scopePossible.Count
        Channels      = $channels
        TotalMB       = [math]::Round($total, 1)
        ReclaimMB     = [math]::Round($reclaim, 1)
        Active30      = $active
        Rank          = (Get-LcaFleetRank -Count $cli.Count)
        DeadWeight    = @($dead | ForEach-Object { $_.Id })
        Conflicts     = @($scopeAll | Where-Object { @($_.Shadows).Count -gt 0 } | ForEach-Object { $_.Id })
        Outdated      = @($scopeAll | Where-Object { $_.UpdateStatus -eq 'outdated' } | ForEach-Object { $_.Id })
    }
}

function Invoke-LcaScan {
    <#
    Runs a full scan and returns a ListCodingAgents.Scan:
    { SchemaVersion, ToolVersion, GeneratedAt, HostName, UserName, Platform,
      PowerShell, Options, Scope, Agents, Changes, Health, History,
      Diagnostics, Timings, Config }
    Agents holds every row that reached a tier, all kinds (display scope is
    applied by the renderers via Select-LcaAgentInScope).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)]$Context)
    Clear-LcaDiagnostic
    $state = Measure-LcaPhase -Context $Context -Name 'state-read' -ScriptBlock { Read-LcaState -Context $Context }
    foreach ($k in $state.Probes.Keys) { $Context.ProbeCache[$k] = $state.Probes[$k] }

    $agents = Measure-LcaPhase -Context $Context -Name 'detect' -ScriptBlock { Find-LcaAgent -Context $Context }
    $agents = @($agents)
    Measure-LcaPhase -Context $Context -Name 'enrich' -ScriptBlock { Add-LcaEnrichment -Context $Context -Agent $agents }
    Measure-LcaPhase -Context $Context -Name 'updates' -ScriptBlock { Add-LcaUpdateInfo -Context $Context -Agent $agents }
    $health = Get-LcaFleetHealth -Context $Context -Agent $agents
    $changes = Measure-LcaPhase -Context $Context -Name 'history' -ScriptBlock {
        Get-LcaHistoryChange -Context $Context -State $state -Agent $agents -TotalMB $health.TotalMB
    }
    $wingetScanned = [bool]$Context.Data['wingetScanned']
    $partialReason = $null
    if (-not $wingetScanned -and $Context.Platform -eq 'windows') {
        $partialReason = 'winget not found'
        if ($Context.Options.SkipWinget) { $partialReason = '-SkipWinget' }
    }
    $edition = 'Desktop'
    if (-not (Test-LcaDesktopEdition)) { $edition = 'Core' }
    [pscustomobject]@{
        PSTypeName    = 'ListCodingAgents.Scan'
        SchemaVersion = $script:LcaSchemaVersion
        ToolVersion   = $script:LcaToolVersion
        GeneratedAt   = $Context.Now
        HostName      = (Get-LcaHostName)
        UserName      = (Get-LcaUserName)
        HomeDir       = (Get-LcaKnownFolder -Name 'Home')
        Platform      = $Context.Platform
        PowerShell    = ('{0} {1}' -f $PSVersionTable.PSVersion, $edition)
        Options       = $Context.Options
        Scope         = [pscustomobject]@{
            IncludeEditors    = [bool]$Context.Options.IncludeEditors
            IncludeExtensions = [bool]$Context.Options.IncludeExtensions
            WingetScanned     = $wingetScanned
            Partial           = [bool]$partialReason
            PartialReason     = $partialReason
        }
        Agents        = $agents
        Changes       = $changes
        Health        = $health
        History       = @($changes.History)
        Diagnostics   = @(Get-LcaDiagnostic)
        Timings       = $Context.Timings
        Config        = $Context.Config
    }
}
