# Terminal report (ported from v1). Workstream D replaces this with a
# width-aware, colour/NO_COLOR-aware renderer with an ASCII fallback.

function Write-LcaConsoleLine {
    <# The single place that writes coloured text to the console. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Console renderer: this is human-facing terminal output, not pipeline data.')]
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text = '', [string]$Color)
    if ($Color) { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text }
}

function Write-LcaConsoleReport {
    <# Prints the scan the way v1 did. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)]$Scan)
    $now = $Context.Now
    $o = $Context.Options
    $h = $Scan.Health
    $agents = @($Scan.Agents)
    $detected = @(Select-LcaAgentInScope -Context $Context -Agent $agents -Tier 'detected')
    $possible = @(Select-LcaAgentInScope -Context $Context -Agent $agents -Tier 'possible')
    $stale = @($detected | Where-Object { $_.Usage -eq 'stale' })
    $conflicted = @(@($detected) + @($possible) | Where-Object { @($_.Shadows).Count -gt 0 })
    $updates = @($detected | Where-Object { $_.UpdateStatus -eq 'outdated' })

    Write-LcaConsoleLine
    $disk = Format-LcaSize -Mb $h.TotalMB
    Write-LcaConsoleLine ("Auto-detected coding agents ({0} detected, {1} possible, {2} on disk)" -f $detected.Count, $possible.Count, $disk) 'Cyan'
    $reclaimLabel = Format-LcaSize -Mb $h.ReclaimMB
    if (-not $reclaimLabel -or $h.ReclaimMB -le 0) { $reclaimLabel = 'none' }
    Write-LcaConsoleLine ("fleet rank: {0} (lv {1}) | {2}/{1} used this month | dead weight: {3}" -f $h.Rank, $h.DetectedCount, $h.Active30, $reclaimLabel) 'Magenta'
    if (-not $o.IncludeEditors) { Write-LcaConsoleLine '(GUI editors hidden - use -IncludeEditors)' 'DarkGray' }
    if ($Scan.Scope.Partial) {
        $carried = "$(@($Scan.Changes.Unscanned).Count) carried over from last full scan"
        if (-not $Scan.Changes.WriteState) { $carried = 'baseline left untouched' }
        Write-LcaConsoleLine ("(partial scan: {0} - winget packages not checked, {1})" -f $Scan.Scope.PartialReason, $carried) 'DarkGray'
    }
    $prevDate = $Scan.Changes.PreviousDate
    if (@($Scan.Changes.New).Count) { Write-LcaConsoleLine ("+ new since last scan ({0}): {1}" -f $prevDate, ($Scan.Changes.New -join ', ')) 'Green' }
    if (@($Scan.Changes.Gone).Count) { Write-LcaConsoleLine ("- gone since last scan ({0}): {1}" -f $prevDate, ($Scan.Changes.Gone -join ', ')) 'DarkGray' }

    foreach ($grp in @($detected | Group-Object -Property Method | Sort-Object -Property @{ Expression = { Get-LcaChannelOrder -Channel $_.Name } })) {
        Write-LcaConsoleLine
        Write-LcaConsoleLine ("== Installed via {0} ({1}) ==" -f $grp.Name, $grp.Count) 'Yellow'
        $cols = @(
            @{ n = 'Agent'; e = { $_.Name } },
            @{ n = 'Version'; e = { $_.Version } },
            @{ n = 'Size'; e = { Format-LcaSize -Mb $_.InstallSizeMB } },
            @{ n = 'Used'; e = { Format-LcaAge -Date $_.LastUsed -Now $now } },
            @{ n = '30d'; e = { if ($_.Sessions30d) { "$($_.Sessions30d)x" } } },
            @{ n = 'MCP'; e = { if ($_.McpCount) { $_.McpCount } } },
            @{ n = 'Auth'; e = { if ($_.LoggedIn) { 'yes' } } },
            @{ n = 'Source'; e = { $_.Source } }
        )
        if ($o.ShowReasons) { $cols += @{ n = 'Why'; e = { $_.Why } } }
        $table = $grp.Group | Sort-Object -Property Name | Format-Table -Property $cols -AutoSize | Out-String -Width 4096
        Write-LcaConsoleLine $table.TrimEnd()
    }

    if ($conflicted.Count) {
        Write-LcaConsoleLine
        Write-LcaConsoleLine '== PATH conflicts (same command, multiple installs) ==' 'Yellow'
        foreach ($r in $conflicted | Sort-Object -Property Name) {
            Write-LcaConsoleLine ("  {0}: wins -> {1}" -f $r.Name, $r.Source) 'White'
            foreach ($sPath in $r.Shadows) { Write-LcaConsoleLine ("  {0}  shadowed -> {1}" -f (' ' * $r.Name.Length), $sPath) 'DarkGray' }
        }
    }

    if ($stale.Count) {
        Write-LcaConsoleLine
        Write-LcaConsoleLine ("== dead weight (untouched > {0}d) - reclaim ~{1} ==" -f $Context.Config.StaleDays, $reclaimLabel) 'Yellow'
        foreach ($r in $stale | Sort-Object -Property @{ Expression = { $_.InstallSizeMB } } -Descending) {
            $ageTxt = 'never seen used'
            if ($r.LastUsed) { $ageTxt = "last used $(Format-LcaAge -Date $r.LastUsed -Now $now)" }
            $szTxt = Format-LcaSize -Mb $r.InstallSizeMB
            if (-not $szTxt) { $szTxt = '?' }
            $cmd = ''
            if ($r.UninstallCommand) { $cmd = $r.UninstallCommand.Display }
            Write-LcaConsoleLine ("  {0,-18} {1,-9} {2,-18} {3}" -f $r.Name, $szTxt, $ageTxt, $cmd) 'White'
        }
    }

    if ($possible.Count) {
        Write-LcaConsoleLine
        Write-LcaConsoleLine '== Possible (weak signal - review) ==' 'DarkYellow'
        $table = $possible | Sort-Object -Property Name | Format-Table -Property @{ n = 'Agent'; e = { $_.Name } }, @{ n = 'Source'; e = { $_.Source } }, @{ n = 'Why'; e = { $_.Why } } -AutoSize | Out-String -Width 4096
        Write-LcaConsoleLine $table.TrimEnd()
    }

    if ($o.CheckUpdates) {
        Write-LcaConsoleLine
        if ($updates.Count) {
            Write-LcaConsoleLine "== Updates available ($($updates.Count)) ==" 'Yellow'
            foreach ($r in $updates | Sort-Object -Property Name) {
                Write-LcaConsoleLine ("  {0,-18} {1,-12} ->  {2,-12} {3}" -f $r.Name, $r.Version, $r.Latest, $r.UpdateCommand.Display) 'White'
            }
        } else {
            Write-LcaConsoleLine '== Everything is up to date ==' 'Green'
        }
    } else {
        Write-LcaConsoleLine '(tip: -CheckUpdates shows which agents are outdated + the update command, -UpdateAll runs them)' 'DarkGray'
    }
    Write-LcaConsoleLine
}
