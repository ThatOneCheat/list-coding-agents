function Get-CodingAgent {
    <#
    .SYNOPSIS
        Finds the AI coding agents installed on this machine.

    .DESCRIPTION
        Scans PATH, package managers (npm, pnpm, bun, pipx, uv, pip, cargo,
        Homebrew, scoop, choco), winget, the Windows Uninstall registry and
        editor extension folders, scores every candidate against a catalog of
        known agents plus heuristics, and emits one ListCodingAgents.Agent
        object per agent with its version, install footprint, usage and update
        information.

        Get-CodingAgent does not write anything unless -UpdateState is used.

    .PARAMETER Name
        Only return agents whose name, id or command matches one of these
        wildcard patterns.

    .PARAMETER IncludeEditors
        Also return GUI AI editors (Cursor, Windsurf, Kiro, Zed ...).

    .PARAMETER IncludeExtensions
        Also return AI coding extensions installed in VS Code-family editors.

    .PARAMETER All
        Same as -IncludeEditors -IncludeExtensions.

    .PARAMETER IncludePossible
        Also return low-confidence candidates (tier "possible").

    .PARAMETER SkipWinget
        Skip the winget package scan.

    .PARAMETER CheckUpdates
        Ask each package manager whether a newer version exists.

    .PARAMETER NoProbe
        Do not run "<agent> --version" to discover versions.

    .PARAMETER AsScan
        Return the whole scan (agents, history, fleet health, diagnostics)
        as one ListCodingAgents.Scan object instead of agent objects.

    .PARAMETER UpdateState
        Record this scan in the state directory (history, probe cache), as
        the list-coding-agents.ps1 script does.

    .EXAMPLE
        Get-CodingAgent

    .EXAMPLE
        Get-CodingAgent -CheckUpdates | Where-Object UpdateStatus -eq 'outdated'

    .OUTPUTS
        ListCodingAgents.Agent, or ListCodingAgents.Scan with -AsScan.
    #>
    [CmdletBinding()]
    [OutputType('ListCodingAgents.Agent', 'ListCodingAgents.Scan')]
    param(
        [Parameter(Position = 0)][SupportsWildcards()][string[]]$Name,
        [switch]$IncludeEditors,
        [switch]$IncludeExtensions,
        [switch]$All,
        [switch]$IncludePossible,
        [switch]$SkipWinget,
        [switch]$CheckUpdates,
        [switch]$NoProbe,
        [switch]$AsScan,
        [switch]$UpdateState
    )
    Clear-LcaDiagnostic
    $ctx = New-LcaContext -Options @{
        IncludeEditors = $IncludeEditors; IncludeExtensions = $IncludeExtensions; All = $All
        SkipWinget = $SkipWinget; CheckUpdates = $CheckUpdates; NoProbe = $NoProbe
    }
    $scan = Invoke-LcaScan -Context $ctx
    if ($UpdateState) { Save-LcaState -Context $ctx -Scan $scan }
    if ($AsScan) {
        $scan | Add-Member -NotePropertyName 'Context' -NotePropertyValue $ctx -Force
        return $scan
    }
    $tier = 'detected'
    if ($IncludePossible) { $tier = 'any' }
    foreach ($a in @(Select-LcaAgentInScope -Context $ctx -Agent $scan.Agents -Tier $tier)) {
        if ($Name) {
            $hit = $false
            foreach ($n in $Name) {
                if ($a.Name -like $n -or $a.Id -like $n -or ($a.Command -and $a.Command -like $n)) { $hit = $true; break }
            }
            if (-not $hit) { continue }
        }
        $a
    }
}
