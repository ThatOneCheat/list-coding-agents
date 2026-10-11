# winget package list (ported from v1: split on 2+ spaces). Workstream A
# replaces the parser with column offsets / Microsoft.WinGet.Client.

function Get-LcaWingetPackage {
    <#
    Returns { Scanned, Packages } where Packages holds
    { Name, Id, Version, Available } per installed winget package. Scanned is
    $false when winget is missing or failed, so callers can tell "not
    scanned" from "scanned, nothing found".
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $res = [pscustomobject]@{ Scanned = $false; Packages = @() }
    $winget = Find-LcaExecutable -Name 'winget'
    if (-not $winget) { return $res }
    $r = Invoke-LcaProcess -FilePath $winget -ArgumentList @('list', '--disable-interactivity') -TimeoutSec 120
    if ($r.Failed -and -not $r.StdOut) {
        Add-LcaDiagnostic -Source 'winget' -Message ("winget list failed: {0}" -f $r.Error)
        return $res
    }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($line in ($r.StdOut -split "`r?`n")) {
        if ($line -notmatch '[A-Za-z]') { continue }   # progress bars / blank lines
        $parts = @($line -split '\s{2,}' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($parts.Count -lt 2) { continue }
        $pkgName = $parts[0]; $id = $parts[1]
        if ($pkgName -eq 'Name' -or $id -eq 'Id') { continue }
        if ($pkgName -match '^(The following|No installed|-{2,})') { continue }
        $ver = ''
        if ($parts.Count -ge 3) { $ver = $parts[2] }
        $out.Add([pscustomobject]@{ Name = $pkgName; Id = $id; Version = $ver; Available = $null })
    }
    $res.Scanned = $true
    $res.Packages = $out.ToArray()
    $res
}
