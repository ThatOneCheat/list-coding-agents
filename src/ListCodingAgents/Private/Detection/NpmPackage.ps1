# npm global packages: command -> rich metadata (ported from v1 Get-NpmMeta).

function Read-LcaPackageJsonMeta {
    <#
    Reads one package.json and returns
    { Package, Version, Dir, Text, Deps, Commands } or $null when the package
    has no bin.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][string]$Dir, [string]$Source = 'npm')
    $pj = Join-Path -Path $Dir -ChildPath 'package.json'
    if (-not (Test-Path -LiteralPath $pj -PathType Leaf)) { return $null }
    try {
        $j = ConvertFrom-LcaJson -Text (Read-LcaTextFile -Path $pj)
    } catch {
        Add-LcaDiagnostic -Source $Source -Level 'info' -Message "unreadable package.json in $Dir" -ErrorRecord $_ -NoExceptionText
        return $null
    }
    $bin = Get-LcaProperty -InputObject $j -Name 'bin'
    if (-not $bin) { return $null }
    $pkgName = [string](Get-LcaProperty -InputObject $j -Name 'name' -Default '')
    $cmds = @()
    if ($bin -is [string]) {
        $fallback = if ($pkgName) { ($pkgName -split '/')[-1] } else { Split-Path -Path $Dir -Leaf }
        $cmds = @($fallback)
    } else {
        $cmds = @($bin.PSObject.Properties | ForEach-Object { $_.Name })
    }
    $deps = New-Object System.Collections.Generic.List[string]
    foreach ($section in @('dependencies', 'optionalDependencies', 'peerDependencies')) {
        $block = Get-LcaProperty -InputObject $j -Name $section
        if ($block) {
            foreach ($p in $block.PSObject.Properties) { $deps.Add([string]$p.Name) }
        }
    }
    $kw = @()
    $kwRaw = Get-LcaProperty -InputObject $j -Name 'keywords'
    if ($kwRaw) { $kw = @($kwRaw | ForEach-Object { [string]$_ }) }
    $desc = [string](Get-LcaProperty -InputObject $j -Name 'description' -Default '')
    [pscustomobject]@{
        Package  = $pkgName
        Version  = [string](Get-LcaProperty -InputObject $j -Name 'version' -Default '')
        Dir      = $Dir
        Text     = ((@($pkgName, $desc) + $kw) -join ' ')
        Deps     = $deps.ToArray()
        Commands = @($cmds | Where-Object { $_ })
    }
}

function Get-LcaNpmPackageMap {
    <#
    Map of lowercase command name -> package metadata for every globally
    installed npm package with a bin. Empty when npm is missing or fails.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory = $true)]$Context)
    $map = @{}
    $npm = Find-LcaExecutable -Name 'npm'
    if (-not $npm) { return $map }
    $r = Invoke-LcaProcess -FilePath $npm -ArgumentList @('root', '-g') -TimeoutSec 30
    if ($r.Failed) {
        Add-LcaDiagnostic -Source 'npm' -Message ("npm root -g failed: {0}" -f $r.Error)
        return $map
    }
    $root = (($r.StdOut -split "`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
    if ($root) { $root = $root.Trim() }
    if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) {
        Add-LcaDiagnostic -Source 'npm' -Level 'info' -Message 'npm global root not found'
        return $map
    }
    $Context.Data['npmRoot'] = $root
    $pkgDirs = New-Object System.Collections.Generic.List[string]
    foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -like '@*') {
            foreach ($sub in @(Get-ChildItem -LiteralPath $d.FullName -Directory -ErrorAction SilentlyContinue)) { $pkgDirs.Add($sub.FullName) }
        } else {
            $pkgDirs.Add($d.FullName)
        }
    }
    foreach ($dir in $pkgDirs) {
        $meta = Read-LcaPackageJsonMeta -Dir $dir -Source 'npm'
        if (-not $meta) { continue }
        foreach ($c in $meta.Commands) { $map[$c.ToLowerInvariant()] = $meta }
    }
    $map
}
