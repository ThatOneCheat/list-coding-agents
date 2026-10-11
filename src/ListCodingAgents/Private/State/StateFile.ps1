# Scan state (last-scan.json): previous names, trend history, probe cache.
# Ported from v1, which kept the file next to the script. Workstream D moves
# it to the state directory, adds migration, schemaVersion and corruption
# handling.

function Get-LcaStateFilePath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)]$Context)
    if (-not $Context.ScriptRoot) { return $null }
    Join-Path -Path $Context.ScriptRoot -ChildPath 'last-scan.json'
}

function Read-LcaState {
    <#
    Returns { Path, Exists, Date, Agents, WingetOnly, HasWingetKey, History,
    Probes }. A missing or unreadable file yields an empty state.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)]$Context)
    $st = [pscustomobject]@{
        Path = (Get-LcaStateFilePath -Context $Context); Exists = $false; Date = ''
        Agents = @(); WingetOnly = @(); HasWingetKey = $false; History = @(); Probes = @{}
    }
    if (-not $st.Path -or -not (Test-Path -LiteralPath $st.Path -PathType Leaf)) { return $st }
    try {
        $prev = ConvertFrom-LcaJson -Text (Read-LcaTextFile -Path $st.Path)
        $st.Exists = $true
        $v = Get-LcaProperty -InputObject $prev -Name 'agents'; if ($v) { $st.Agents = @($v) }
        $v = Get-LcaProperty -InputObject $prev -Name 'date'; if ($v) { $st.Date = "$v" }
        $v = Get-LcaProperty -InputObject $prev -Name 'history'; if ($v) { $st.History = @($v) }
        $v = Get-LcaProperty -InputObject $prev -Name 'probes'
        if ($v) { foreach ($pp in $v.PSObject.Properties) { $st.Probes[$pp.Name] = $pp.Value } }
        # Agents only the winget scan can see. Tracked separately so a scan that
        # skipped winget knows which previous names it simply didn't look for.
        if ($prev.PSObject.Properties['wingetOnly']) {
            $st.HasWingetKey = $true
            $v = Get-LcaProperty -InputObject $prev -Name 'wingetOnly'
            if ($v) { $st.WingetOnly = @($v) }
        }
    } catch {
        Add-LcaDiagnostic -Source 'state' -Message "cannot read state file $($st.Path)" -ErrorRecord $_ -NoExceptionText
    }
    $st
}

function Get-LcaHistoryChange {
    <#
    Diffs the current scan against the previous state (v1 semantics) and
    prepares what Save-LcaState persists. Returns
    { PreviousDate, New, Gone, Unscanned, PersistNames, WingetOnly,
      WriteState, History }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$State,
        [AllowEmptyCollection()][object[]]$Agent = @(),
        [double]$TotalMB = 0
    )
    $inScope = @(Select-LcaAgentInScope -Context $Context -Agent $Agent -Tier 'detected')
    $curNames = @($inScope | ForEach-Object { $_.Name })
    $wingetScanned = [bool]$Context.Data['wingetScanned']
    # Without a winget scan, previous winget-only agents are "not checked", not
    # "gone" - reporting them as removed is a lie about state we never observed.
    $unscanned = @()
    if (-not $wingetScanned) { $unscanned = @($State.WingetOnly) }
    $new = @(); $gone = @()
    if ($State.Agents.Count) {
        $new = @($curNames | Where-Object { $State.Agents -notcontains $_ })
        $gone = @($State.Agents | Where-Object { $curNames -notcontains $_ -and $unscanned -notcontains $_ })
    }

    # A run without a winget scan is a PARTIAL scan. Writing its short agent
    # list as the new baseline would make the next full scan report every
    # winget-only agent as "+ new" (and this run report them as "- gone"). So
    # carry the previous winget-only names forward and skip the trend point,
    # whose count/size would be understated and show up as a phantom dip.
    $wingetOnly = @($inScope | Where-Object { -not $_.Command -and $_.Channel -eq 'winget' } | ForEach-Object { $_.Name })
    $persist = $curNames
    $write = $true
    $hist = @($State.History)
    if (-not $wingetScanned) {
        if ($State.Agents.Count -and -not $State.HasWingetKey) {
            # Pre-upgrade state file: no way to tell which previous names were
            # winget-only, so leave the baseline alone rather than corrupt it.
            $write = $false
        } else {
            $wingetOnly = @($State.WingetOnly)
            $persist = @(@($curNames) + @($State.WingetOnly) | Select-Object -Unique)
        }
    } else {
        $entry = [pscustomobject]@{
            d  = $Context.Now.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
            c  = $inScope.Count
            mb = [math]::Round($TotalMB, 1)
        }
        if ($hist.Count -and "$($hist[$hist.Count - 1].d)" -eq $entry.d) { $hist[$hist.Count - 1] = $entry }
        else { $hist = @($hist) + @($entry) }
        if ($hist.Count -gt 60) { $hist = @($hist[($hist.Count - 60)..($hist.Count - 1)]) }
    }
    foreach ($a in $Agent) { if ($new -contains $a.Name) { $a.IsNew = $true } }
    [pscustomobject]@{
        PreviousDate = $State.Date
        New          = $new
        Gone         = $gone
        Unscanned    = $unscanned
        VersionChanges = @()
        PersistNames = $persist
        WingetOnly   = $wingetOnly
        WriteState   = $write
        History      = $hist
    }
}

function Save-LcaState {
    <# Persists names, winget-only names, history and the probe cache. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)]$Scan)
    $path = Get-LcaStateFilePath -Context $Context
    if (-not $path -or -not $Scan.Changes.WriteState) { return }
    try {
        $obj = [ordered]@{
            date       = $Context.Now.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
            agents     = @($Scan.Changes.PersistNames)
            wingetOnly = @($Scan.Changes.WingetOnly)
            history    = @($Scan.Changes.History)
            probes     = $Context.ProbeCache
        }
        Write-LcaTextFile -Path $path -Content (ConvertTo-LcaJson -InputObject $obj)
    } catch {
        Add-LcaDiagnostic -Source 'state' -Message "cannot write state file $path" -ErrorRecord $_
    }
}
