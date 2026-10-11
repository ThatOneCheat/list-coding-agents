# Update / uninstall information (ported from v1). Workstream C replaces the
# string version compare, the second winget call and the uninstall rules.

function Add-LcaUninstallInfo {
    <# v1 rules, expressed as argument arrays instead of re-parsed strings. #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Agent = @())
    foreach ($r in @($Agent)) {
        if ($r.Tier -eq 'excluded') { continue }
        if ($r.Channel -eq 'npm' -and $r.Package) {
            $r.UninstallCommand = New-LcaCommand -Exe 'npm' -Arguments @('rm', '-g', $r.Package)
        } elseif ($r.Channel -eq 'winget' -and -not $r.Command) {
            $r.UninstallCommand = New-LcaCommand -Exe 'winget' -Arguments @('uninstall', '--id', $r.Source)
        } elseif ($r.Channel -eq 'winget') {
            $r.UninstallCommand = New-LcaCommand -Exe 'winget' -Arguments @('uninstall', $r.Name)
        } elseif ($r.Source -match '(?i)\.(exe|cmd|bat|ps1)$') {
            $r.UninstallCommand = New-LcaCommand -Exe 'Remove-Item' -Arguments @($r.Source)
        }
    }
}

function Add-LcaUpdateInfo {
    <#
    Sets UninstallCommand on every row and, with Options.CheckUpdates, Latest /
    UpdateCommand / UpdateStatus from npm and winget.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [AllowEmptyCollection()][object[]]$Agent = @()
    )
    Add-LcaUninstallInfo -Agent $Agent
    if (-not $Context.Options.CheckUpdates) { return }
    $detected = @($Agent | Where-Object { $_.Tier -eq 'detected' })
    $npm = Find-LcaExecutable -Name 'npm'
    if ($npm) {
        $r = Invoke-LcaProcess -FilePath $npm -ArgumentList @('outdated', '-g', '--json') -TimeoutSec 60
        # npm outdated exits 1 when something is outdated; the JSON is still valid
        $raw = $r.StdOut.Trim()
        if ($raw) {
            try {
                $out = ConvertFrom-LcaJson -Text $raw
                foreach ($p in $out.PSObject.Properties) {
                    $latest = Get-LcaProperty -InputObject $p.Value -Name 'latest'
                    foreach ($a in $detected) {
                        if ($a.Package -eq $p.Name -and $latest -and $latest -ne $a.Version) {
                            $a.Latest = [string]$latest
                            $a.UpdateCommand = New-LcaCommand -Exe 'npm' -Arguments @('i', '-g', ($a.Package + '@latest'))
                            $a.UpdateStatus = 'outdated'
                            $a.UpdateReason = $null
                        }
                    }
                }
            } catch {
                Add-LcaDiagnostic -Source 'npm' -Message 'npm outdated returned unreadable JSON' -ErrorRecord $_ -NoExceptionText
            }
        }
    }
    $winget = Find-LcaExecutable -Name 'winget'
    if ($winget) {
        $r = Invoke-LcaProcess -FilePath $winget -ArgumentList @('upgrade', '--disable-interactivity') -TimeoutSec 120
        $wg = @{}
        foreach ($line in ($r.StdOut -split "`r?`n")) {
            if ($line -notmatch '[A-Za-z]') { continue }
            $parts = $line -split '\s{2,}'
            if ($parts.Count -ge 4 -and $parts[1].Trim() -match '\.' -and $parts[1].Trim() -ne 'Id') {
                $wg[$parts[1].Trim()] = $parts[3].Trim()
            }
        }
        foreach ($a in @($detected | Where-Object { $_.Channel -eq 'winget' -and -not $_.Latest })) {
            foreach ($k in $wg.Keys) {
                if ($a.Source -match [regex]::Escape($k) -or $k -match [regex]::Escape($a.Name)) {
                    $a.Latest = $wg[$k]
                    $a.UpdateCommand = New-LcaCommand -Exe 'winget' -Arguments @('upgrade', '--id', $k)
                    $a.UpdateStatus = 'outdated'
                    $a.UpdateReason = $null
                    break
                }
            }
        }
    }
}
