# -FailOn outdated,stale,conflict,new for CI. Workstream C owns this.

function Test-LcaFailOn {
    <#
    Returns the -FailOn conditions that are present in the scan (display
    scope), e.g. @('outdated', 'new'). Empty when none matched.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Scan,
        [AllowEmptyCollection()][string[]]$FailOn = @()
    )
    $inScope = @(Select-LcaAgentInScope -Context $Context -Agent $Scan.Agents -Tier 'detected')
    $hit = New-Object System.Collections.Generic.List[string]
    foreach ($c in @($FailOn)) {
        $match = switch ($c) {
            'outdated' { @($inScope | Where-Object { $_.UpdateStatus -eq 'outdated' }).Count -gt 0 }
            'stale' { @($inScope | Where-Object { $_.Usage -eq 'stale' }).Count -gt 0 }
            'conflict' { @($inScope | Where-Object { @($_.Shadows).Count -gt 0 }).Count -gt 0 }
            'new' { @($Scan.Changes.New).Count -gt 0 }
            default { $false }
        }
        if ($match -and -not $hit.Contains($c)) { $hit.Add($c) }
    }
    $hit.ToArray()
}
