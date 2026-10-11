# -UpdateAll from the CLI. Workstream C owns this.

function Invoke-LcaUpdateAll {
    <#
    Updates every outdated DETECTED agent in display scope through
    Update-CodingAgent (ShouldProcess: -DryRun maps to -WhatIf, -AskConfirm to -Confirm).
    Returns the ListCodingAgents.UpdateResult objects.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Scan,
        [switch]$Force,
        [switch]$DryRun,
        [switch]$AskConfirm
    )
    $outdated = @(Select-LcaAgentInScope -Context $Context -Agent $Scan.Agents -Tier 'detected' | Where-Object { $_.UpdateStatus -eq 'outdated' })
    if (-not $outdated.Count) { return @() }
    @($outdated | Update-CodingAgent -Force:$Force -WhatIf:$DryRun -Confirm:$AskConfirm -PassThru)
}
