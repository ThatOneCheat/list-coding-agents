# Provider seam: the only network access (opt-in update checks: npm / PyPI /
# crates.io registry fallbacks, GitHub latest-release checks) and the
# Microsoft.WinGet.Client module. Nothing here runs unless a caller asks.

function Invoke-LcaHttpJson {
    <#
    GETs a JSON document with a timeout. Never throws; returns
    { Ok, Data, StatusCode, Error }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [int]$TimeoutSec = 15,
        [hashtable]$Headers = @{}
    )
    $res = [pscustomobject]@{ Ok = $false; Data = $null; StatusCode = $null; Error = $null }
    if ($Uri -notmatch '^https://') {
        $res.Error = 'only https URLs are allowed'
        return $res
    }
    $h = @{ 'User-Agent' = ('list-coding-agents/' + $script:LcaToolVersion); 'Accept' = 'application/json' }
    foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] }
    try {
        if (Test-LcaDesktopEdition) {
            # Windows PowerShell 5.1 does not offer TLS 1.2 by default on older systems.
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        }
        $params = @{ Uri = $Uri; Headers = $h; TimeoutSec = $TimeoutSec; Method = 'Get'; ErrorAction = 'Stop' }
        if (Test-LcaDesktopEdition) { $params['UseBasicParsing'] = $true }
        $res.Data = Invoke-RestMethod @params
        $res.Ok = $true
        $res.StatusCode = 200
    } catch {
        $res.Error = $_.Exception.Message
        $resp = $null
        try { $resp = $_.Exception.Response } catch { Write-Debug 'no response on exception' }
        if ($resp) {
            try { $res.StatusCode = [int]$resp.StatusCode } catch { Write-Debug 'no status code' }
        }
    }
    $res
}

function Get-LcaWinGetModulePackage {
    <#
    Installed packages from the Microsoft.WinGet.Client module
    (Get-WinGetPackage) when that module is available - structured data, no
    column parsing, no truncated ids. Returns $null when the module is not
    installed (callers then fall back to parsing `winget list`), else
    { Name, Id, Version, Available, Source } per package.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param()
    if (-not (Test-LcaWindows)) { return $null }
    $cmd = Get-Command -Name 'Get-WinGetPackage' -ErrorAction Ignore
    if (-not $cmd) { return $null }
    try {
        $pkgs = @(& $cmd -ErrorAction Stop)
    } catch {
        Write-Verbose "Get-WinGetPackage failed: $($_.Exception.Message)"
        return $null
    }
    $out = foreach ($p in $pkgs) {
        $props = @($p.PSObject.Properties | ForEach-Object { $_.Name })
        $avail = $null
        if ($props -contains 'IsUpdateAvailable' -and $p.IsUpdateAvailable -and $props -contains 'AvailableVersions' -and $p.AvailableVersions) {
            $avail = [string](@($p.AvailableVersions)[0])
        }
        $src = $null
        if ($props -contains 'Source') { $src = [string]$p.Source }
        $ver = $null
        if ($props -contains 'InstalledVersion') { $ver = [string]$p.InstalledVersion }
        [pscustomobject]@{ Name = [string]$p.Name; Id = [string]$p.Id; Version = $ver; Available = $avail; Source = $src }
    }
    @($out)
}
