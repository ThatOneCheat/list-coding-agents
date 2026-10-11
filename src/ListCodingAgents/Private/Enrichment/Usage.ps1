# Usage intel from an agent's config folders (ported from v1 Get-ConfigDirs /
# Get-McpCountFromRaw / Get-AgentIntel). Presence-only: credential FILE names
# and KEY names are matched, values are never read out or stored.

function Get-LcaConfigDirCandidate {
    <#
    Likely config locations for a command, by the generic v1 rule (a folder
    or file named after the command): ~/.<n>, ~/.config/<n>, ~/.<n>.json,
    %APPDATA%\<n>, %LOCALAPPDATA%\<n>; "-cli"/"-code" suffixes are stripped too.
    Returns only paths that exist.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()][AllowEmptyString()][string]$Name)
    if (-not $Name) { return @() }
    $homeDir = Get-LcaKnownFolder -Name 'Home'
    $appData = Get-LcaKnownFolder -Name 'AppData'
    $localAppData = Get-LcaKnownFolder -Name 'LocalAppData'
    $bases = @($Name)
    if ($Name -match '-(cli|code)$') { $bases += ($Name -replace '-(cli|code)$', '') }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($b in $bases) {
        $cands = @()
        if ($homeDir) {
            $cands += (Join-Path -Path $homeDir -ChildPath ".$b")
            $cands += (Join-Path -Path (Join-Path -Path $homeDir -ChildPath '.config') -ChildPath $b)
            $cands += (Join-Path -Path $homeDir -ChildPath ".$b.json")
        }
        if ($appData) { $cands += (Join-Path -Path $appData -ChildPath $b) }
        if ($localAppData) { $cands += (Join-Path -Path $localAppData -ChildPath $b) }
        foreach ($c in $cands) {
            if ((Test-Path -LiteralPath $c) -and -not $out.Contains($c)) { $out.Add($c) }
        }
    }
    $out.ToArray()
}

function Get-LcaMcpCount {
    <#
    Counts entries directly inside every "mcpServers": { ... } block (also
    "mcp_servers" / "mcp" json keys and toml [mcp_servers.x] sections)
    without fully parsing the file - config files can be multi-MB.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([AllowNull()][AllowEmptyString()][string]$Raw)
    if (-not $Raw) { return 0 }
    $total = 0
    foreach ($pat in @('"mcpServers"\s*:\s*\{', '"mcp_servers"\s*:\s*\{', '"mcp"\s*:\s*\{')) {
        $found = 0
        foreach ($m in [regex]::Matches($Raw, $pat)) {
            $i = $m.Index + $m.Length
            $depth = 1; $inStr = $false; $esc = $false; $keys = 0; $expectKey = $true
            $limit = [math]::Min($Raw.Length, $i + 262144)
            for ($p = $i; $p -lt $limit -and $depth -gt 0; $p++) {
                $ch = $Raw[$p]
                if ($esc) { $esc = $false; continue }
                if ($ch -eq '\') { if ($inStr) { $esc = $true }; continue }
                if ($ch -eq '"') {
                    if ($inStr) { $inStr = $false }
                    else { $inStr = $true; if ($depth -eq 1 -and $expectKey) { $keys++; $expectKey = $false } }
                    continue
                }
                if ($inStr) { continue }
                if ($ch -eq '{' -or $ch -eq '[') { $depth++ }
                elseif ($ch -eq '}' -or $ch -eq ']') { $depth-- }
                elseif ($ch -eq ',' -and $depth -eq 1) { $expectKey = $true }
            }
            $found += $keys
        }
        if ($found) { $total += $found; break }   # one key style per file is enough
    }
    $total += ([regex]::Matches($Raw, '(?m)^\s*\[mcp_servers\.[^\]\.]+')).Count
    $total
}

function Get-LcaUsageIntel {
    <#
    One walk over the config dirs: newest write (last used), session-ish
    files touched in the last 30 days, MCP servers configured, and a
    credentials hint (probably logged in). Returns
    { LastUsed, Sessions30d, McpCount, LoggedIn, DataDirs }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)]$Context, [AllowEmptyCollection()][string[]]$Dirs = @())
    $res = [pscustomobject]@{ LastUsed = $null; Sessions30d = 0; McpCount = 0; LoggedIn = $false; DataDirs = @($Dirs) }
    if (-not $Dirs -or $Dirs.Count -eq 0) { return $res }
    $lastUtc = [datetime]::MinValue
    $cut = $Context.Now.UtcDateTime.AddDays(-30)
    $sessRx = '(?i)\.jsonl$|[\\/](history|sessions?|logs?|chats?|threads?|projects|transcripts?)([\\/]|$)'
    $credRx = '(?i)credential|oauth|token|\bauth\b|auth\.json|\.creds'
    $credKey = '(?i)"(api[-_]?key|access[-_]?token|refresh[-_]?token|oauth[a-z_]*|bearer)"\s*:'
    foreach ($dCfg in $Dirs) {
        $item = $null
        try { $item = Get-Item -LiteralPath $dCfg -Force -ErrorAction Stop } catch {
            Add-LcaDiagnostic -Source 'usage' -Level 'info' -Message "cannot read $dCfg" -ErrorRecord $_
            continue
        }
        if ($item.LastWriteTimeUtc -gt $lastUtc) { $lastUtc = $item.LastWriteTimeUtc }
        if (-not $item.PSIsContainer) {
            # a single config file, e.g. ~/.claude.json
            if ($item.Length -lt 15MB) {
                try {
                    $raw = [System.IO.File]::ReadAllText($item.FullName)
                    $res.McpCount += Get-LcaMcpCount -Raw $raw
                    if (-not $res.LoggedIn -and $item.Length -lt 2MB -and $raw -match $credKey) { $res.LoggedIn = $true }
                } catch {
                    Add-LcaDiagnostic -Source 'usage' -Level 'info' -Message "cannot read config file $($item.FullName)" -ErrorRecord $_ -NoExceptionText
                }
            }
            continue
        }
        $files = @(Get-ChildItem -LiteralPath $dCfg -Recurse -Depth 3 -File -Force -ErrorAction SilentlyContinue | Select-Object -First 6000)
        foreach ($f in $files) {
            if ($f.LastWriteTimeUtc -gt $lastUtc) { $lastUtc = $f.LastWriteTimeUtc }
            if ($f.LastWriteTimeUtc -ge $cut -and $f.FullName -match $sessRx) { $res.Sessions30d++ }
            if (-not $res.LoggedIn -and $f.Name -match $credRx) { $res.LoggedIn = $true }
        }
        # config-ish files: direct children only (settings.json, config.toml, mcp.json ...)
        foreach ($f in $files) {
            if ($f.DirectoryName -ne $item.FullName) { continue }
            if ($f.Extension -notmatch '(?i)^\.(json|toml)$' -or $f.Length -ge 15MB) { continue }
            try {
                $raw = [System.IO.File]::ReadAllText($f.FullName)
                $res.McpCount += Get-LcaMcpCount -Raw $raw
                if (-not $res.LoggedIn -and $f.Length -lt 2MB -and $raw -match $credKey) { $res.LoggedIn = $true }
            } catch {
                Add-LcaDiagnostic -Source 'usage' -Level 'info' -Message "cannot read config file $($f.FullName)" -ErrorRecord $_ -NoExceptionText
            }
        }
    }
    if ($lastUtc -gt [datetime]::MinValue) {
        $res.LastUsed = (New-Object System.DateTimeOffset ([datetime]::SpecifyKind($lastUtc, [System.DateTimeKind]::Utc))).ToLocalTime()
    }
    $res
}
