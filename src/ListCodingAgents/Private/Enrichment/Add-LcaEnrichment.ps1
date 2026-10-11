# Enrichment entry point: sizes, usage intel, version probes.

function Add-LcaEnrichment {
    <#
    Fills InstallSizeMB, LastUsed, Sessions30d, McpCount, LoggedIn, DataDirs,
    Usage and (by probing) Version on the given rows. Mutates in place.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [AllowEmptyCollection()][object[]]$Agent = @()
    )
    $staleDays = [int]$Context.Config.StaleDays
    foreach ($r in @($Agent)) {
        if ($r.Tier -eq 'excluded') { continue }
        if ($r.Channel -eq 'npm' -and $r.PackageDir) { $r.InstallSizeMB = Get-LcaSizeMB -Path $r.PackageDir }
        elseif ($r.Source -match '(?i)\.exe$') { $r.InstallSizeMB = Get-LcaSizeMB -Path $r.Source }
        $dirs = @()
        if ($r.Command) { $dirs = @(Get-LcaConfigDirCandidate -Name $r.Command) }
        $intel = Get-LcaUsageIntel -Context $Context -Dirs $dirs
        $r.LastUsed = $intel.LastUsed
        $r.Sessions30d = $intel.Sessions30d
        $r.McpCount = $intel.McpCount
        $r.LoggedIn = $intel.LoggedIn
        $r.DataDirs = @($intel.DataDirs)
        # v1 semantics (defect 3, fixed by workstream B): no evidence = stale.
        $r.Usage = 'stale'
        if ($r.LastUsed -and ($Context.Now - $r.LastUsed).TotalDays -le $staleDays) { $r.Usage = 'active' }
    }
    if ($Context.Options.NoProbe) { return }
    foreach ($r in @($Agent | Where-Object { $_.Tier -eq 'detected' })) {
        if ($r.Version -or $r.Source -notmatch '(?i)\.exe$' -or $r.Channel -eq 'winget') { continue }
        # cache probe results per path+mtime so repeat scans skip the timeouts
        $key = Get-LcaProbeCacheKey -Path $r.Source
        if ($key -and $Context.ProbeCache.ContainsKey($key)) {
            $v = [string]$Context.ProbeCache[$key]
            if ($v -and $v -ne '?') { $r.Version = $v; $r.VersionSource = 'probe-cache' }
            continue
        }
        $v = Get-LcaVersionProbe -Path $r.Source -TimeoutSec ([double]$Context.Config.ProbeTimeoutSec)
        if ($v) { $r.Version = $v; $r.VersionSource = 'probe' }
        if ($key) { $Context.ProbeCache[$key] = $(if ($v) { $v } else { '?' }) }
    }
}
