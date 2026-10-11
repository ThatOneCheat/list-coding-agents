# Candidate commands from PATH (ported from v1 Get-PathCandidates, now
# through the provider seam so PATH is split on the platform separator).

function Get-LcaPathCandidate {
    <#
    Every runnable file on PATH outside the OS directories, one entry per
    command name: { Command, Path, Shadows }. The first PATH entry wins; the
    same name in a LATER directory is recorded in Shadows (a PATH conflict).
    Windows: extensions from PATHEXT plus .PS1, %WINDIR% skipped except
    WindowsApps (winget shims live there). Elsewhere: files with an execute
    bit.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param([Parameter(Mandatory = $true)]$Context)
    $win = $Context.Platform -eq 'windows'
    $exts = @()
    if ($win) {
        $pathext = Get-LcaEnvironmentVariable -Name 'PATHEXT'
        if (-not $pathext) { $pathext = '.COM;.EXE;.BAT;.CMD' }
        $exts = @(@($pathext.Split(';') | Where-Object { $_ } | ForEach-Object { $_.ToUpperInvariant() }) + @('.PS1') | Select-Object -Unique)
    }
    $winDir = Get-LcaKnownFolder -Name 'WinDir'
    $seen = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::OrdinalIgnoreCase)

    foreach ($dir in Get-LcaPathEntry) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        # Skip pure Windows system dirs (keep WindowsApps for winget shims).
        if ($win -and $winDir -and $dir.StartsWith($winDir, [StringComparison]::OrdinalIgnoreCase) -and
            $dir -notmatch '(?i)\\WindowsApps$') { continue }
        $files = @()
        try { $files = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction Stop) } catch {
            Add-LcaDiagnostic -Source 'path' -Level 'info' -Message "cannot list PATH entry $dir" -ErrorRecord $_
            continue
        }
        foreach ($f in $files) {
            if ($win) {
                if ($exts -notcontains $f.Extension.ToUpperInvariant()) { continue }
                $name = $f.BaseName.ToLowerInvariant()
            } else {
                if (-not (Test-LcaUnixExecutable -Path $f.FullName)) { continue }
                $name = $f.Name.ToLowerInvariant()
            }
            if (-not $name) { continue }
            if (-not $seen.Contains($name)) {
                $seen[$name] = [pscustomobject]@{ Command = $name; Path = $f.FullName; Shadows = @() }
            } else {
                $first = $seen[$name]
                if ($first.Path -ne $f.FullName -and ((Split-Path -Path $first.Path -Parent) -ne (Split-Path -Path $f.FullName -Parent))) {
                    # same command name in a later PATH dir - it is shadowed
                    $first.Shadows = @($first.Shadows) + @($f.FullName)
                }
            }
        }
    }
    @($seen.Values)
}
