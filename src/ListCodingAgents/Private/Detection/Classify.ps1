# Install channel, kind and version-info text for a PATH candidate
# (ported from v1 Get-Method / Get-Kind / Get-PeText). Paths are normalised
# to '/' before matching so the same rules work on every platform.

function Get-LcaInstallChannel {
    <#
    Returns { Channel, Method } for a command path. Channel is the machine id,
    Method the display label v1 used.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()][AllowEmptyString()][string]$Path)
    $mk = { param($c, $m) [pscustomobject]@{ Channel = $c; Method = $m } }
    if (-not $Path) { return (& $mk 'unknown' 'unknown') }
    $p = ConvertTo-LcaSignaturePath -Path $Path
    if ($p -match '(?i)/AppData/Roaming/npm/|/node_modules/') { return (& $mk 'npm' 'npm') }
    if ($p -match '(?i)/WindowsApps/|/WinGet/') { return (& $mk 'winget' 'winget') }
    if ($p -match '(?i)/Python/.*/Scripts/|/uv/|/pipx/') { return (& $mk 'pip' 'pip / uv') }
    if ($p -match '(?i)/scoop/') { return (& $mk 'scoop' 'scoop') }
    if ($p -match '(?i)/\.cargo/bin/') { return (& $mk 'cargo' 'cargo') }
    if ($p -match '(?i)/\.bun/bin/') { return (& $mk 'bun' 'bun') }
    # v1 had a separate '\.local\bin\|\Programs\' branch with the same result.
    & $mk 'standalone' 'standalone installer'
}

function Get-LcaAgentKind {
    <# 'editor' for GUI editor launchers, else 'cli' (v1 Get-Kind). #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Path, [AllowNull()][AllowEmptyString()][string]$Name)
    $p = ConvertTo-LcaSignaturePath -Path $Path
    if ($p -match '(?i)/Programs/(cursor|windsurf|kiro|trae|trae-cn)/' -or
        $Name -match '^(cursor|windsurf|kiro|trae|trae-cn)$') { return 'editor' }
    'cli'
}

function Get-LcaPeText {
    <#
    Version-info text of an .exe: { Text, Publisher, Version }. Node/Bun
    runtime wrappers are noise for classification and their version is not
    the agent's version, so they contribute nothing.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()][AllowEmptyString()][string]$Path)
    $empty = [pscustomobject]@{ Text = ''; Publisher = ''; Version = '' }
    if (-not $Path -or $Path -notmatch '(?i)\.exe$') { return $empty }
    $vi = Get-LcaFileVersionInfo -Path $Path
    if (-not $vi) { return $empty }
    if ($vi.CompanyName -match '(?i)^(Node\.js|Oven)$' -or $vi.ProductName -match '(?i)^(Node\.js|Bun)$') { return $empty }
    $ver = $vi.ProductVersion
    if (-not $ver) { $ver = $vi.FileVersion }
    [pscustomobject]@{
        Text      = (@($vi.ProductName, $vi.FileDescription) -join ' ').Trim()
        Publisher = [string]$vi.CompanyName
        Version   = [string]$ver
    }
}
