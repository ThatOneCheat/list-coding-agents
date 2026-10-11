# Optional config.json in the config directory:
#   { "staleDays": 60, "probeTimeoutSec": 8, "parallelism": 4,
#     "defaults": { "IncludeEditors": true, "SkipWinget": false, ... } }

$script:LcaConfigDefaultSwitches = @(
    'IncludeEditors', 'IncludeExtensions', 'All', 'SkipWinget', 'CheckUpdates', 'NoProbe', 'NoHtml', 'NoOpen',
    'Json', 'ShowReasons', 'Quiet', 'NoColor', 'Redact'
)

function Get-LcaConfig {
    <#
    Returns { StaleDays, ProbeTimeoutSec, Parallelism, Defaults (hashtable of
    switch name -> bool), Path }. Invalid values are ignored with a warning
    diagnostic; a missing file means defaults.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)]$Context)
    $cfg = [pscustomobject]@{ StaleDays = 60; ProbeTimeoutSec = 8; Parallelism = $null; Defaults = @{}; Path = $null }
    if (-not $Context.ConfigDir) { return $cfg }
    $p = Join-Path -Path $Context.ConfigDir -ChildPath 'config.json'
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $cfg }
    $cfg.Path = $p
    $j = $null
    try { $j = ConvertFrom-LcaJson -Text (Read-LcaTextFile -Path $p) } catch {
        Add-LcaDiagnostic -Source 'config' -Message "config.json is not valid JSON, using defaults ($p)" -ErrorRecord $_ -NoExceptionText
        return $cfg
    }
    $num = {
        param($name, $min, $max)
        $v = Get-LcaProperty -InputObject $j -Name $name
        if ($null -eq $v) { return $null }
        $d = 0.0
        if (-not [double]::TryParse([string]$v, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d) -or $d -lt $min -or $d -gt $max) {
            Add-LcaDiagnostic -Source 'config' -Message ("config.json: {0} must be a number between {1} and {2}; ignored" -f $name, $min, $max)
            return $null
        }
        $d
    }
    $v = & $num 'staleDays' 1 3650; if ($null -ne $v) { $cfg.StaleDays = [int]$v }
    $v = & $num 'probeTimeoutSec' 1 120; if ($null -ne $v) { $cfg.ProbeTimeoutSec = [double]$v }
    $v = & $num 'parallelism' 1 32; if ($null -ne $v) { $cfg.Parallelism = [int]$v }
    $defs = Get-LcaProperty -InputObject $j -Name 'defaults'
    if ($defs) {
        foreach ($prop in $defs.PSObject.Properties) {
            $match = $script:LcaConfigDefaultSwitches | Where-Object { $_ -eq $prop.Name }
            if (-not $match -or $prop.Value -isnot [bool]) {
                Add-LcaDiagnostic -Source 'config' -Message ("config.json: defaults.{0} is not a known switch with a true/false value; ignored" -f $prop.Name)
                continue
            }
            $cfg.Defaults[[string]$match] = [bool]$prop.Value
        }
    }
    $cfg
}
