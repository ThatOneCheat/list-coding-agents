# -Explain <name>: the full scoring breakdown for one command or package,
# including why it was excluded. Workstream A owns the content.

function Get-LcaExplanation {
    <#
    Returns { Name, Found, Lines } where Lines is the human-readable
    breakdown the CLI prints verbatim. Found is $false when nothing by that
    name was seen by any source.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Scan,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $hits = @($Scan.Agents | Where-Object { $_.Name -eq $Name -or $_.Command -eq $Name -or $_.Id -eq $Name -or $_.Package -eq $Name })
    $lines = New-Object System.Collections.Generic.List[string]
    $t = $Context.Catalog.scoring.thresholds
    $lines.Add(("tiers: detected >= {0}, possible >= {1}" -f $t.detected, $t.possible))
    if (-not $hits.Count) {
        $lines.Add(("{0}: not found by any source (not on PATH, not a known package)" -f $Name))
    }
    foreach ($a in $hits) {
        $lines.Add(("{0}: score {1} -> {2} ({3}, {4})" -f $a.Name, $a.Score, $a.Tier, $a.Kind, $a.Method))
        foreach ($e in @($a.Evidence)) {
            $lines.Add(("  {0,4}  {1} [{2}]" -f $e.Weight, $e.Label, $e.Source))
        }
    }
    [pscustomobject]@{ Name = $Name; Found = [bool]$hits.Count; Lines = $lines.ToArray() }
}
