# Detection entry point: every source -> scored ListCodingAgents.Agent rows.
# Returns ALL rows that reached a tier (detected / possible), regardless of
# kind. Display scope (-IncludeEditors etc.) is applied by consumers, never
# here, so history always sees the unfiltered set.

function Find-LcaAgent {
    <#
    Runs every detection source and returns Agent rows with Tier 'detected'
    or 'possible' (plus 'excluded' rows for the -Explain target only).
    Side data for later phases goes to $Context.Data:
      npm           command -> npm package metadata
      wingetScanned $true when the winget list was read
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param([Parameter(Mandatory = $true)]$Context)
    $model = Get-LcaScoringModel -Catalog $Context.Catalog
    $rows = New-Object System.Collections.Generic.List[object]
    $have = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    $explain = $Context.Options.Explain
    $detectedAt = [int]$model.Thresholds.detected

    $npm = Measure-LcaPhase -Context $Context -Name 'npm-metadata' -ScriptBlock { Get-LcaNpmPackageMap -Context $Context }
    $Context.Data['npm'] = $npm

    $candidates = Measure-LcaPhase -Context $Context -Name 'path-scan' -ScriptBlock { Get-LcaPathCandidate -Context $Context }
    foreach ($c in @($candidates)) {
        $name = $c.Command; $path = $c.Path
        # Skip hidden/backup/old launcher basenames (e.g. .jcode-launcher-old-...).
        if ($name.StartsWith('.')) { continue }

        $text = $name; $deps = @(); $publisher = ''
        $version = $null; $verSrc = $null; $package = $null; $pkgDir = $null
        $ch = Get-LcaInstallChannel -Path $path
        $channel = $ch.Channel; $method = $ch.Method
        $kind = Get-LcaAgentKind -Path $path -Name $name
        $sources = @('path')

        if ($npm.ContainsKey($name)) {
            $m = $npm[$name]
            $text = $m.Text; $deps = $m.Deps; $channel = 'npm'; $method = 'npm'
            if ($m.Version) { $version = $m.Version; $verSrc = 'package' }
            $package = $m.Package; $pkgDir = $m.Dir
            $sources += 'npm'
        }

        $pe = Get-LcaPeText -Path $path
        if ($pe.Text) { $text = (@($text, $pe.Text) -join ' ').Trim() }
        if ($pe.Publisher) { $publisher = $pe.Publisher }
        if (-not $version -and $pe.Version -match '(\d+(\.\d+)+)') { $version = $Matches[1]; $verSrc = 'pe' }

        $s = Get-LcaAgentScore -Text $text -Deps $deps -Publisher $publisher -Name $name -Path $path -Model $model
        $score = $s.Score; $evidence = $s.Evidence; $why = $s.Why
        if ($Context.Extra.Contains($name) -and $score -lt $detectedAt) {
            $score = [int]$model.Weights.extraOverride
            $evidence = @(New-LcaEvidence -Signal 'override-extra' -Label 'agents-extra.txt override' -Weight $score -Source 'agents-extra.txt')
            $why = 'agents-extra.txt override'
        }
        # exclude wins over extra - it is the user's last word on a false positive
        if ($Context.Exclude.Contains($name)) {
            $score = [int]$model.Weights.excluded
            $evidence = @(New-LcaEvidence -Signal 'override-exclude' -Label 'agents-exclude.txt override' -Weight $score -Source 'agents-exclude.txt')
            $why = 'agents-exclude.txt override'
        }
        $tier = Get-LcaTier -Score $score -Model $model
        if ($tier -eq 'excluded' -and -not ($explain -and $explain -eq $name)) { continue }

        if ($tier -ne 'excluded') { [void]$have.Add($name) }
        $rows.Add((New-LcaAgent -Property @{
                    Name = $name; Command = $name; Source = $path; Path = $path
                    Channel = $channel; Method = $method; Kind = $kind
                    Score = $score; Tier = $tier; Evidence = @($evidence); Why = $why
                    Version = $version; VersionSource = $verSrc; Package = $package; PackageDir = $pkgDir
                    Sources = $sources; Shadows = @($c.Shadows)
                }))
    }

    # winget packages (catches agents that aren't on PATH, e.g. Codex).
    # wingetScanned drives the partial-scan handling: a run that never looked
    # at winget must not claim winget-only agents disappeared.
    $Context.Data['wingetScanned'] = $false
    if (-not $Context.Options.SkipWinget) {
        $wg = Measure-LcaPhase -Context $Context -Name 'winget' -ScriptBlock { Get-LcaWingetPackage }
        if ($wg.Scanned) {
            $Context.Data['wingetScanned'] = $true
            foreach ($p in @($wg.Packages)) {
                $pkgName = $p.Name; $id = $p.Id
                $publisher = ($id -split '\.')[0]
                $key = (($pkgName -split '\s+')[0]).ToLowerInvariant()
                if ($have.Contains($key)) { continue }    # already found on PATH
                # match agents-exclude.txt on the display name or its first word,
                # since winget rows are keyed on "Codex"-style names, not basenames
                if ($Context.Exclude.Contains($key) -or $Context.Exclude.Contains($pkgName.ToLowerInvariant())) { continue }
                $s = Get-LcaAgentScore -Text ("$pkgName $id") -Deps @() -Publisher $publisher -Name $pkgName -Path $id -Model $model
                $tier = Get-LcaTier -Score $s.Score -Model $model
                if ($tier -eq 'excluded') { continue }
                $ver = $null
                if ($p.Version -match '^(\d+(\.\d+)+)') { $ver = $Matches[1] }
                elseif ($id -match '_(\d+(\.\d+)+)_') { $ver = $Matches[1] }
                [void]$have.Add($key)
                $rows.Add((New-LcaAgent -Property @{
                            Name = $pkgName; Command = $null; Source = $id
                            Channel = 'winget'; Method = 'winget'; Kind = 'cli'
                            Score = $s.Score; Tier = $tier; Evidence = @($s.Evidence); Why = $s.Why
                            Version = $ver; VersionSource = $(if ($ver) { 'winget' } else { $null }); Package = $id
                            Sources = @('winget')
                        }))
            }
        }
    }
    $rows.ToArray()
}
