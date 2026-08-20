<#
.SYNOPSIS
    Auto-detects AI coding-agent CLIs installed on this machine - no
    hand-maintained list of products. New agents are recognised as long as
    they leave any normal trace (npm metadata, embedded version-info, a winget
    publisher, or a recognisable name).

.DESCRIPTION
    Every user-installed command (PATH entries outside C:\Windows) plus every
    winget package is scored against signals that indicate an AI coding agent:

      * npm package description / keywords / dependencies (AI SDKs)
      * embedded Windows version-info (CompanyName / ProductName)
      * winget publisher (e.g. Anthropic.*, OpenAI.*)
      * naming patterns (contains "agent", "ai", a known model name + cli, ...)

    Results are tiered by confidence:
      DETECTED  (score >= 4) - high confidence, grouped by install method
      POSSIBLE  (score 2-3)  - weak signal, listed for you to eyeball

    On top of detection, each agent is enriched with:
      * installed version (npm metadata, exe version-info, or a --version probe)
      * install size on disk
      * usage intel from its config folder (e.g. ~/.claude): last used, how
        many session-ish files were touched in the last 30 days, how many MCP
        servers are configured, and whether credentials exist (logged in)
      * update availability + the exact update command   (-CheckUpdates)

    Fleet health, computed every scan:
      * dead weight  - agents untouched for 60+ days, with the exact
                       uninstall command and total reclaimable disk
      * conflicts    - the same command name appearing in multiple PATH
                       directories (one shadows the other)
      * fleet rank   - a silly but honest hoarding grade

    The script also remembers previous scans (last-scan.json): it reports
    agents that appeared/disappeared, keeps a per-scan history that the HTML
    report draws as a trend line, and caches exe --version probe results so
    repeat scans skip the slow timeouts.

    Honest limitation: a command that is a bare binary with no metadata and a
    non-descriptive name (e.g. "agy") cannot be classified by any heuristic.
    Add such names to agents-extra.txt (one per line) as an escape hatch.

.PARAMETER IncludeEditors
    Also include GUI AI editors (Cursor/Windsurf/Kiro style launchers).
.PARAMETER ShowReasons
    Print the signals that triggered each detection.
.PARAMETER NoHtml
    Skip writing/opening the HTML report.
.PARAMETER CheckUpdates
    Query npm and winget for newer versions and show update commands.
.PARAMETER UpdateAll
    Implies -CheckUpdates, then offers to run every update command for you.
.PARAMETER Json
    Also write the full result set to coding-agents.json.
#>
[CmdletBinding()]
param(
    [switch]$IncludeEditors,
    [switch]$ShowReasons,
    [switch]$NoHtml,
    [switch]$CheckUpdates,
    [switch]$UpdateAll,
    [switch]$Json
)
if ($UpdateAll) { $CheckUpdates = $true }

# ---------------------------------------------------------------------------
# Lexicons (linguistic signals, not a product catalogue). These rarely change:
# they are model/vendor words, so newly-released agents are still detected via
# their metadata even if their brand isn't listed here.
# ---------------------------------------------------------------------------
$AiVendors    = 'anthropic|openai|moonshot|mistral|cohere|sourcegraph|augment(code)?|codeium|anysphere|factory|sst|kilocode|kilo|perplexity|deepseek|xai'
$AiSdkDep     = '(?i)anthropic|(^|/)openai|generative-ai|@google/genai|modelcontextprotocol|langchain|ollama|@ai-sdk|^ai$|mistralai'
$BrandWords   = 'claude|gemini|copilot|codex|aider|cody|goose|opencode|cline|roo[- ]?code|droid|crush|qwen|grok|kimi|antigravity|blackbox|windsurf|cursor|mimo|\bgpt\b|\bllm\b'
$AgentPhrase  = 'coding[- ]?agent|code[- ]?agent|agentic|ai[- ]?coding|ai pair|pair program|autonomous (coding|software|dev)|ai software engineer|terminal.*agent'
$HardExclude  = 'install .*skill|skill for|\bdeploy(ment)?\b|package manager|boilerplate|scaffold|video extension|image extension|redistributable|driver'

# --- scoring ----------------------------------------------------------------
function Get-AgentScore {
    param([string]$Text, [string[]]$Deps, [string]$Publisher, [string]$Name)
    $t = (($Text, ($Deps -join ' '), $Publisher, $Name) -join ' ').ToLower()
    $score = 0; $why = @()

    if ($t -match $HardExclude) { return [pscustomobject]@{ Score = -99; Why = 'excluded (non-agent phrase)' } }

    if ($t -match $AgentPhrase) { $score += 4; $why += 'coding-agent phrase' }
    if ($Publisher -match "(?i)^($AiVendors)" -or $t -match "(?i)\b($AiVendors)\b") { $score += 3; $why += 'AI vendor' }
    if ($Deps | Where-Object { $_ -match $AiSdkDep }) { $score += 3; $why += 'AI SDK dependency' }
    if ($t -match '\bagent\b' -and $t -match 'code|coding|cli|terminal|dev') { $score += 2; $why += 'agent + code' }
    if ($t -match "(?i)($BrandWords)") {
        $score += 1; $why += 'model/brand name'
        if ($t -match 'cli|code|coding|terminal') { $score += 3; $why += 'brand + cli' }
    }
    if ($t -match '(^|[^a-z])ai([^a-z]|$)') { $score += 1; $why += 'ai token' }
    if ($t -match '\bmcp\b|model context protocol') { $score += 1; $why += 'mcp' }

    [pscustomobject]@{ Score = $score; Why = ($why -join ', ') }
}

# --- enrichment helpers ------------------------------------------------------
function Get-SizeMB([string]$Path) {
    # Directory: recursive sum. File: its own length.
    try {
        if (Test-Path -LiteralPath $Path -PathType Container) {
            $sum = 0L
            foreach ($f in Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue) { $sum += $f.Length }
        } else {
            $sum = (Get-Item -LiteralPath $Path -ErrorAction Stop).Length
        }
        if ($sum -gt 0) { return [math]::Round($sum / 1MB, 1) }
    } catch {}
    $null
}

function Format-Size($Mb) {
    if ($null -eq $Mb) { return '' }
    if ($Mb -lt 0.1) { return '<0.1 MB' }
    if ($Mb -ge 1024) { return ('{0:N1} GB' -f ($Mb / 1024)) }
    if ($Mb -ge 10)   { return ('{0:N0} MB' -f $Mb) }
    ('{0:N1} MB' -f $Mb)
}

function Get-ConfigDirs([string]$Name) {
    # Likely config locations for a command. Generic rule (dir named after the
    # command), never a product catalogue.
    if (-not $Name -or $Name -eq '(winget)') { return @() }
    $bases = @($Name)
    if ($Name -match '-(cli|code)$') { $bases += ($Name -replace '-(cli|code)$', '') }
    $out = @()
    foreach ($b in $bases) {
        $cands = @(
            (Join-Path $HOME ".$b"),
            (Join-Path $HOME (Join-Path '.config' $b)),
            (Join-Path $HOME ".$b.json")
        )
        if ($env:APPDATA)      { $cands += (Join-Path $env:APPDATA $b) }
        if ($env:LOCALAPPDATA) { $cands += (Join-Path $env:LOCALAPPDATA $b) }
        foreach ($c in $cands) {
            if ((Test-Path -LiteralPath $c) -and ($out -notcontains $c)) { $out += $c }
        }
    }
    $out
}

function Get-McpCountFromRaw([string]$Raw) {
    # Counts entries directly inside every "mcpServers": { ... } block (also
    # "mcp_servers" / "mcp" json keys and toml [mcp_servers.x] sections)
    # without fully parsing the file - config files can be multi-MB.
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

function Get-AgentIntel([string]$Name) {
    # One walk over the agent's config dirs: newest write (last used), count of
    # session-ish files touched in the last 30 days, MCP servers configured,
    # and a credentials hint (probably logged in). All heuristic, all generic.
    $res = [pscustomobject]@{ LastUsed = $null; Sessions30d = 0; McpCount = 0; Auth = $false }
    $dirs = @(Get-ConfigDirs $Name)
    if (-not $dirs.Count) { return $res }
    $cut     = (Get-Date).AddDays(-30)
    $sessRx  = '(?i)\.jsonl$|[\\/](history|sessions?|logs?|chats?|threads?|projects|transcripts?)([\\/]|$)'
    $credRx  = '(?i)credential|oauth|token|\bauth\b|auth\.json|\.creds'
    $credKey = '(?i)"(api[-_]?key|access[-_]?token|refresh[-_]?token|oauth[a-z_]*|bearer)"\s*:'
    foreach ($dCfg in $dirs) {
        try { $item = Get-Item -LiteralPath $dCfg -Force -ErrorAction Stop } catch { continue }
        if ($item.LastWriteTime -gt $res.LastUsed) { $res.LastUsed = $item.LastWriteTime }
        if (-not $item.PSIsContainer) {
            # a single config file, e.g. ~/.claude.json
            if ($item.Length -lt 15MB) {
                try {
                    $raw = [System.IO.File]::ReadAllText($item.FullName)
                    $res.McpCount += Get-McpCountFromRaw $raw
                    if (-not $res.Auth -and $item.Length -lt 2MB -and $raw -match $credKey) { $res.Auth = $true }
                } catch {}
            }
            continue
        }
        $files = @(Get-ChildItem -LiteralPath $dCfg -Recurse -Depth 3 -File -Force -ErrorAction SilentlyContinue | Select-Object -First 6000)
        foreach ($f in $files) {
            if ($f.LastWriteTime -gt $res.LastUsed) { $res.LastUsed = $f.LastWriteTime }
            if ($f.LastWriteTime -ge $cut -and $f.FullName -match $sessRx) { $res.Sessions30d++ }
            if (-not $res.Auth -and $f.Name -match $credRx) { $res.Auth = $true }
        }
        # config-ish files: direct children only (settings.json, config.toml, mcp.json ...)
        foreach ($f in $files) {
            if ($f.DirectoryName -ne $item.FullName) { continue }
            if ($f.Extension -notmatch '(?i)^\.(json|toml)$' -or $f.Length -ge 15MB) { continue }
            try {
                $raw = [System.IO.File]::ReadAllText($f.FullName)
                $res.McpCount += Get-McpCountFromRaw $raw
                if (-not $res.Auth -and $f.Length -lt 2MB -and $raw -match $credKey) { $res.Auth = $true }
            } catch {}
        }
    }
    $res
}

function Format-Age($Dt) {
    if ($null -eq $Dt) { return '' }
    $days = ((Get-Date) - $Dt).TotalDays
    if ($days -lt 1)   { return 'today' }
    if ($days -lt 2)   { return 'yesterday' }
    if ($days -lt 60)  { return ('{0}d ago'  -f [int][math]::Floor($days)) }
    if ($days -lt 365) { return ('{0}mo ago' -f [int][math]::Floor($days / 30)) }
    ('{0}y ago' -f [int][math]::Floor($days / 365))
}

function Get-ExeVersionProbe([string]$Path) {
    # Bare exes carry no metadata, so ask them directly - inside a job with a
    # timeout so an interactive/hung CLI can't stall the whole scan.
    try {
        $job = Start-Job -ScriptBlock { param($p) & $p --version 2>$null } -ArgumentList $Path
        $out = ''
        if (Wait-Job $job -Timeout 8) { $out = ((Receive-Job $job -ErrorAction SilentlyContinue) -join ' ') }
        Remove-Job $job -Force -ErrorAction SilentlyContinue | Out-Null
        if ($out -match '(\d+\.\d+(\.\d+)*)') { return $Matches[1] }
    } catch {}
    $null
}

# --- npm: command -> rich metadata -----------------------------------------
function Get-NpmMeta {
    $map = @{}
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) { return $map }
    $root = (& npm root -g 2>$null | Out-String).Trim()
    if (-not $root -or -not (Test-Path -LiteralPath $root)) { return $map }
    $dirs = foreach ($d in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue) {
        if ($d.Name -like '@*') { Get-ChildItem -LiteralPath $d.FullName -Directory -ErrorAction SilentlyContinue } else { $d }
    }
    foreach ($d in $dirs) {
        $pj = Join-Path $d.FullName 'package.json'
        if (-not (Test-Path -LiteralPath $pj)) { continue }
        try { $j = Get-Content -LiteralPath $pj -Raw | ConvertFrom-Json } catch { continue }
        if (-not $j.bin) { continue }
        $cmds = if ($j.bin -is [string]) { @(($j.name -split '/')[-1]) } else { @($j.bin.PSObject.Properties.Name) }
        $deps = @(); if ($j.dependencies) { $deps = $j.dependencies.PSObject.Properties.Name }
        $kw   = @(); if ($j.keywords) { $kw = $j.keywords }
        $meta = [pscustomobject]@{
            Package = $j.name; Version = $j.version; Dir = $d.FullName
            Text    = (($j.name, $j.description, ($kw -join ' ')) -join ' ')
            Deps    = $deps
        }
        foreach ($c in $cmds) { $map[$c.ToLower()] = $meta }
    }
    $map
}

# --- candidate commands: PATH (outside Windows) -----------------------------
function Get-PathCandidates {
    $exts = @($env:PATHEXT -split ';' | Where-Object { $_ }) + '.PS1' | ForEach-Object { $_.ToUpperInvariant() } | Select-Object -Unique
    $dirs = $env:PATH -split ';' | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } | Select-Object -Unique
    $seen = @{}
    foreach ($dir in $dirs) {
        try { $files = Get-ChildItem -LiteralPath $dir -File -ErrorAction Stop } catch { continue }
        foreach ($f in $files) {
            if ($env:WINDIR -and $f.FullName.StartsWith($env:WINDIR, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            if ($exts -notcontains $f.Extension.ToUpperInvariant()) { continue }
            $name = $f.BaseName.ToLowerInvariant()
            if (-not $seen.ContainsKey($name)) {
                $seen[$name] = [pscustomobject]@{ Path = $f.FullName; Shadows = @() }
            } elseif ($seen[$name].Path -ne $f.FullName -and ((Split-Path $seen[$name].Path) -ne (Split-Path $f.FullName))) {
                # same command name in a later PATH dir - it is shadowed
                $seen[$name].Shadows += $f.FullName
            }
        }
    }
    $seen.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Command = $_.Key; Path = $_.Value.Path; Shadows = @($_.Value.Shadows) } }
}

$npmMeta = Get-NpmMeta
$extraFile = Join-Path $PSScriptRoot 'agents-extra.txt'
$extra = if (Test-Path -LiteralPath $extraFile) { Get-Content $extraFile | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ -and $_ -notmatch '^#' } } else { @() }

# --- evaluate every PATH candidate -----------------------------------------
$rows = foreach ($c in Get-PathCandidates) {
    $name = $c.Command; $path = $c.Path
    $text = $name; $deps = @(); $publisher = ''; $method = 'standalone installer'; $kind = 'cli'
    $version = ''; $package = ''; $pkgDir = ''

    if ($path -match '(?i)\\AppData\\Roaming\\npm\\' -or $path -match '(?i)\\node_modules\\') { $method = 'npm' }
    elseif ($path -match '(?i)\\WindowsApps\\')                                                { $method = 'winget' }
    elseif ($path -match '(?i)\\Python\\.*\\Scripts\\' -or $path -match '(?i)\\uv\\')          { $method = 'pip / uv' }
    if ($path -match '(?i)\\Programs\\[^\\]+\\.*bin\\')                                         { $kind = 'editor' }

    if ($npmMeta.ContainsKey($name)) {
        $m = $npmMeta[$name]
        $text = $m.Text; $deps = $m.Deps; $method = 'npm'
        $version = $m.Version; $package = $m.Package; $pkgDir = $m.Dir
    }
    if ($path -match '\.exe$') {
        try { $vi = (Get-Item -LiteralPath $path).VersionInfo
              $text = ($text, $vi.ProductName, $vi.FileDescription) -join ' '
              $publisher = "$($vi.CompanyName)"
              if (-not $version -and "$($vi.ProductVersion)" -match '^\s*(\d+(\.\d+)+)') { $version = $Matches[1] }
        } catch {}
    }

    $s = Get-AgentScore -Text $text -Deps $deps -Publisher $publisher -Name $name
    if ($extra -contains $name -and $s.Score -lt 4) { $s = [pscustomobject]@{ Score = 5; Why = 'agents-extra.txt override' } }

    [pscustomobject]@{
        Name=$name; Command=$name; Source=$path; Method=$method; Kind=$kind; Score=$s.Score; Why=$s.Why
        Version=$version; Package=$package; PkgDir=$pkgDir
        SizeMB=$null; LastUsed=$null; Latest=''; UpdateCmd=''
        Sessions30d=0; McpCount=0; Auth=$false; Stale=$false; UninstallCmd=''; Shadows=@($c.Shadows)
    }
}

# --- evaluate winget packages (catches agents that aren't on PATH, e.g. Codex)
if (Get-Command winget -ErrorAction SilentlyContinue) {
    $haveNames = @($rows | ForEach-Object { $_.Name })
    foreach ($line in (winget list --disable-interactivity 2>$null)) {
        if ($line -notmatch '[A-Za-z]') { continue }   # skip progress bars / blank lines
        $parts = $line -split '\s{2,}'
        if ($parts.Count -lt 2) { continue }
        $pkgName = $parts[0].Trim(); $id = $parts[1].Trim()
        if (-not $pkgName -or $pkgName -eq 'Name') { continue }
        $publisher = ($id -split '\.')[0]
        $key = (($pkgName -split '\s')[0]).ToLower()
        if ($haveNames -contains $key) { continue }    # already found on PATH
        $s = Get-AgentScore -Text ("$pkgName $id") -Deps @() -Publisher $publisher -Name $pkgName
        if ($s.Score -ge 2) {
            $ver = ''
            if ($parts.Count -ge 3 -and $parts[2].Trim() -match '^(\d+(\.\d+)+)') { $ver = $Matches[1] }
            elseif ($id -match '_(\d+(\.\d+)+)_') { $ver = $Matches[1] }
            $rows += [pscustomobject]@{
                Name=$pkgName; Command='(winget)'; Source=$id; Method='winget'; Kind='cli'; Score=$s.Score; Why=$s.Why
                Version=$ver; Package=''; PkgDir=''
                SizeMB=$null; LastUsed=$null; Latest=''; UpdateCmd=''
                Sessions30d=0; McpCount=0; Auth=$false; Stale=$false; UninstallCmd=''; Shadows=@()
            }
        }
    }
}

# --- split into tiers -------------------------------------------------------
$detected = @($rows | Where-Object { $_.Score -ge 4 -and ($IncludeEditors -or $_.Kind -ne 'editor') })
$possible = @($rows | Where-Object { $_.Score -ge 2 -and $_.Score -lt 4 -and ($IncludeEditors -or $_.Kind -ne 'editor') })

# --- previous scan: name diff, trend history, exe-probe cache ----------------
$histFile  = Join-Path $PSScriptRoot 'last-scan.json'
$prevNames = @(); $prevDate = ''; $histArr = @(); $probeCache = @{}
if (Test-Path -LiteralPath $histFile) {
    try {
        $prev = Get-Content -LiteralPath $histFile -Raw | ConvertFrom-Json
        if ($prev.agents)  { $prevNames = @($prev.agents) }
        if ($prev.date)    { $prevDate  = "$($prev.date)" }
        if ($prev.history) { $histArr   = @($prev.history) }
        if ($prev.probes)  { foreach ($pp in $prev.probes.PSObject.Properties) { $probeCache[$pp.Name] = $pp.Value } }
    } catch {}
}
$curNames = @($detected | ForEach-Object { $_.Name })
$newNames = @(); $goneNames = @()
if ($prevNames.Count) {
    $newNames  = @($curNames  | Where-Object { $prevNames -notcontains $_ })
    $goneNames = @($prevNames | Where-Object { $curNames  -notcontains $_ })
}

# --- enrich the agents that made a tier (sizes, usage intel, version probes) -
Write-Host ""
Write-Host "enriching: sizes + usage intel + mcp configs + versions..." -ForegroundColor DarkGray
foreach ($r in ($detected + $possible)) {
    if ($r.Method -eq 'npm' -and $r.PkgDir) { $r.SizeMB = Get-SizeMB $r.PkgDir }
    elseif ($r.Source -match '(?i)\.exe$')  { $r.SizeMB = Get-SizeMB $r.Source }
    $intel = Get-AgentIntel $r.Command
    $r.LastUsed  = $intel.LastUsed
    $r.Sessions30d = $intel.Sessions30d
    $r.McpCount  = $intel.McpCount
    $r.Auth      = $intel.Auth
}
foreach ($r in $detected) {
    if (-not $r.Version -and $r.Source -match '(?i)\.exe$' -and $r.Method -ne 'winget') {
        # cache probe results per path+mtime so repeat scans skip the timeouts
        $cacheKey = ''
        try { $cacheKey = "$($r.Source)|$((Get-Item -LiteralPath $r.Source -ErrorAction Stop).LastWriteTimeUtc.Ticks)" } catch {}
        if ($cacheKey -and $probeCache.ContainsKey($cacheKey)) {
            $v = "$($probeCache[$cacheKey])"
            if ($v -ne '?') { $r.Version = $v }
        } else {
            $r.Version = "$(Get-ExeVersionProbe $r.Source)"
            $v = $r.Version; if (-not $v) { $v = '?' }
            if ($cacheKey) { $probeCache[$cacheKey] = $v }
        }
    }
}

# --- update check (one npm call + one winget call, both opt-in) -------------
if ($CheckUpdates) {
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        Write-Host "checking npm registry for updates..." -ForegroundColor DarkGray
        $raw = ((& npm outdated -g --json 2>$null) -join "`n").Trim()
        if ($raw) {
            try {
                $out = $raw | ConvertFrom-Json
                foreach ($p in $out.PSObject.Properties) {
                    foreach ($r in $detected) {
                        if ($r.Package -eq $p.Name -and $p.Value.latest -and $p.Value.latest -ne $r.Version) {
                            $r.Latest = $p.Value.latest
                            $r.UpdateCmd = "npm i -g $($r.Package)@latest"
                        }
                    }
                }
            } catch {}
        }
    }
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "checking winget for updates..." -ForegroundColor DarkGray
        $wg = @{}
        foreach ($line in (winget upgrade --disable-interactivity 2>$null)) {
            if ($line -notmatch '[A-Za-z]') { continue }
            $parts = $line -split '\s{2,}'
            if ($parts.Count -ge 4 -and $parts[1].Trim() -match '\.' -and $parts[1].Trim() -ne 'Id') {
                $wg[$parts[1].Trim()] = $parts[3].Trim()
            }
        }
        foreach ($r in ($detected | Where-Object { $_.Method -eq 'winget' -and -not $_.Latest })) {
            foreach ($k in $wg.Keys) {
                if ($r.Source -match [regex]::Escape($k) -or $k -match [regex]::Escape($r.Name)) {
                    $r.Latest = $wg[$k]; $r.UpdateCmd = "winget upgrade --id `"$k`""; break
                }
            }
        }
    }
}
$updates = @($detected | Where-Object { $_.Latest })

# --- fleet health: dead weight, conflicts, totals, rank ----------------------
$staleDays = 60
foreach ($r in ($detected + $possible)) {
    $r.Stale = $true
    if ($r.LastUsed -and ((Get-Date) - $r.LastUsed).TotalDays -le $staleDays) { $r.Stale = $false }
    if     ($r.Method -eq 'npm' -and $r.Package)                   { $r.UninstallCmd = "npm rm -g $($r.Package)" }
    elseif ($r.Method -eq 'winget' -and $r.Command -eq '(winget)') { $r.UninstallCmd = "winget uninstall --id `"$($r.Source)`"" }
    elseif ($r.Method -eq 'winget')                                { $r.UninstallCmd = "winget uninstall `"$($r.Name)`"" }
    elseif ($r.Source -match '(?i)\.(exe|cmd|bat|ps1)$')           { $r.UninstallCmd = "Remove-Item `"$($r.Source)`"" }
}
$stale = @($detected | Where-Object { $_.Stale })
$reclaimMB = 0.0; foreach ($r in $stale) { if ($r.SizeMB) { $reclaimMB += $r.SizeMB } }
$conflicted = @(($detected + $possible) | Where-Object { $_.Shadows.Count })
$totMB = 0.0; foreach ($r in $detected) { if ($r.SizeMB) { $totMB += $r.SizeMB } }
$active30 = @($detected | Where-Object { $_.LastUsed -and ((Get-Date) - $_.LastUsed).TotalDays -le 30 }).Count
$dcount = $detected.Count
$rankName = if ($dcount -le 2) { 'MINIMALIST' }
            elseif ($dcount -le 5) { 'COLLECTOR' }
            elseif ($dcount -le 9) { 'ENTHUSIAST' }
            elseif ($dcount -le 13) { 'CERTIFIED HOARDER' }
            else { 'AGENT SINGULARITY' }

# --- persist scan history (names diff, trend, probe cache) --------------------
$histEntry = [pscustomobject]@{ d = (Get-Date -Format 'yyyy-MM-dd'); c = $detected.Count; mb = [math]::Round($totMB, 1) }
if ($histArr.Count -and "$($histArr[$histArr.Count-1].d)" -eq $histEntry.d) { $histArr[$histArr.Count-1] = $histEntry }
else { $histArr = @($histArr) + @($histEntry) }
if ($histArr.Count -gt 60) { $histArr = @($histArr[($histArr.Count-60)..($histArr.Count-1)]) }
try {
    [pscustomobject]@{
        date    = (Get-Date -Format 'yyyy-MM-dd HH:mm')
        agents  = $curNames
        history = $histArr
        probes  = $probeCache
    } | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $histFile -Encoding utf8
} catch {}

# --- terminal report ---------------------------------------------------------
$rank = @{ 'npm'=1; 'winget'=2; 'pip / uv'=3; 'standalone installer'=4 }

Write-Host ""
Write-Host "Auto-detected coding agents ($($detected.Count) detected, $($possible.Count) possible, $(Format-Size $totMB) on disk)" -ForegroundColor Cyan
$reclaimLabel = Format-Size $reclaimMB; if (-not $reclaimLabel) { $reclaimLabel = 'none' }
Write-Host ("fleet rank: {0} (lv {1}) | {2}/{1} used this month | dead weight: {3}" -f $rankName, $detected.Count, $active30, $reclaimLabel) -ForegroundColor Magenta
if (-not $IncludeEditors) { Write-Host "(GUI editors hidden - use -IncludeEditors)" -ForegroundColor DarkGray }
if ($newNames.Count)  { Write-Host ("+ new since last scan ({0}): {1}"  -f $prevDate, ($newNames -join ', '))  -ForegroundColor Green }
if ($goneNames.Count) { Write-Host ("- gone since last scan ({0}): {1}" -f $prevDate, ($goneNames -join ', ')) -ForegroundColor DarkGray }

foreach ($grp in $detected | Group-Object Method | Sort-Object { $rank[$_.Name] }) {
    Write-Host ""
    Write-Host ("== Installed via {0} ({1}) ==" -f $grp.Name, $grp.Count) -ForegroundColor Yellow
    $cols = @(
        @{n='Agent';e={$_.Name}},
        @{n='Version';e={$_.Version}},
        @{n='Size';e={Format-Size $_.SizeMB}},
        @{n='Used';e={Format-Age $_.LastUsed}},
        @{n='30d';e={if ($_.Sessions30d) { "$($_.Sessions30d)x" }}},
        @{n='MCP';e={if ($_.McpCount) { $_.McpCount }}},
        @{n='Auth';e={if ($_.Auth) { 'yes' }}},
        @{n='Source';e={$_.Source}}
    )
    if ($ShowReasons) { $cols += @{n='Why';e={$_.Why}} }
    $grp.Group | Sort-Object Name | Format-Table $cols -AutoSize
}

if ($conflicted.Count) {
    Write-Host ""
    Write-Host "== PATH conflicts (same command, multiple installs) ==" -ForegroundColor Yellow
    foreach ($r in $conflicted | Sort-Object Name) {
        Write-Host ("  {0}: wins -> {1}" -f $r.Name, $r.Source) -ForegroundColor White
        foreach ($sPath in $r.Shadows) { Write-Host ("  {0}  shadowed -> {1}" -f (' ' * $r.Name.Length), $sPath) -ForegroundColor DarkGray }
    }
}

if ($stale.Count) {
    Write-Host ""
    Write-Host ("== dead weight (untouched > {0}d) - reclaim ~{1} ==" -f $staleDays, $reclaimLabel) -ForegroundColor Yellow
    foreach ($r in $stale | Sort-Object @{e={$_.SizeMB}} -Descending) {
        $ageTxt = 'never seen used'; if ($r.LastUsed) { $ageTxt = "last used $(Format-Age $r.LastUsed)" }
        $szTxt = Format-Size $r.SizeMB; if (-not $szTxt) { $szTxt = '?' }
        Write-Host ("  {0,-18} {1,-9} {2,-18} {3}" -f $r.Name, $szTxt, $ageTxt, $r.UninstallCmd) -ForegroundColor White
    }
}

if ($possible.Count) {
    Write-Host ""
    Write-Host "== Possible (weak signal - review) ==" -ForegroundColor DarkYellow
    $possible | Sort-Object Name | Format-Table @{n='Agent';e={$_.Name}}, @{n='Source';e={$_.Source}}, @{n='Why';e={$_.Why}} -AutoSize
}

if ($CheckUpdates) {
    Write-Host ""
    if ($updates.Count) {
        Write-Host "== Updates available ($($updates.Count)) ==" -ForegroundColor Yellow
        foreach ($r in $updates | Sort-Object Name) {
            Write-Host ("  {0,-18} {1,-12} ->  {2,-12} {3}" -f $r.Name, $r.Version, $r.Latest, $r.UpdateCmd) -ForegroundColor White
        }
    } else {
        Write-Host "== Everything is up to date ==" -ForegroundColor Green
    }
} else {
    Write-Host "(tip: -CheckUpdates shows which agents are outdated + the update command, -UpdateAll runs them)" -ForegroundColor DarkGray
}

if ($UpdateAll -and $updates.Count) {
    Write-Host ""
    $ans = Read-Host ("-UpdateAll: run all {0} update command(s) now? (y/n)" -f $updates.Count)
    if ($ans -match '^(y|yes)$') {
        foreach ($r in $updates | Sort-Object Name) {
            Write-Host ""
            Write-Host (">> {0}" -f $r.UpdateCmd) -ForegroundColor Cyan
            try { Invoke-Expression $r.UpdateCmd } catch { Write-Host ("   failed: {0}" -f $_.Exception.Message) -ForegroundColor Red }
        }
        Write-Host ""
        Write-Host "updates done - re-run the scan to verify versions" -ForegroundColor Green
    } else {
        Write-Host "skipped" -ForegroundColor DarkGray
    }
}
Write-Host ""

# --- JSON export --------------------------------------------------------------
if ($Json) {
    $export = foreach ($r in ($detected + $possible)) {
        [pscustomobject]@{
            name      = $r.Name;    tier    = $(if ($r.Score -ge 4) { 'detected' } else { 'possible' })
            command   = $r.Command; source  = $r.Source; method = $r.Method; kind = $r.Kind
            version   = $r.Version; latest  = $r.Latest; updateCmd = $r.UpdateCmd
            sizeMB    = $r.SizeMB
            lastUsed  = $(if ($r.LastUsed) { $r.LastUsed.ToString('s') } else { $null })
            sessions30d = $r.Sessions30d; mcpServers = $r.McpCount; loggedIn = [bool]$r.Auth
            stale     = [bool]$r.Stale; uninstallCmd = $r.UninstallCmd; shadowedBy = @($r.Shadows)
            score     = $r.Score;   why     = $r.Why
        }
    }
    $jsonPath = Join-Path $PSScriptRoot 'coding-agents.json'
    @($export) | ConvertTo-Json -Depth 4 | Out-File -LiteralPath $jsonPath -Encoding utf8
    Write-Host "JSON export: $jsonPath" -ForegroundColor Green
}

# --- HTML report ------------------------------------------------------------
if (-not $NoHtml) {
    function Enc($s) { [System.Net.WebUtility]::HtmlEncode([string]$s) }
    $chanColors = @{ 'npm'='#ff6b5e'; 'winget'='#5ad1ff'; 'pip / uv'='#ffcf5a'; 'standalone installer'='#d4ff3f' }

    function New-UnitChips($r, [bool]$IsNew) {
        $chips = ''
        if ($IsNew)       { $chips += '<span class="chip new">NEW</span>' }
        if ($r.SizeMB)    { $chips += "<span class=""chip"">$(Enc (Format-Size $r.SizeMB))</span>" }
        if ($r.LastUsed)  { $chips += "<span class=""chip"">$(Enc (Format-Age $r.LastUsed))</span>" }
        if ($r.Sessions30d) { $chips += "<span class=""chip sess"" title=""session files touched in the last 30 days"">$($r.Sessions30d)&times;/30d</span>" }
        if ($r.McpCount)  { $chips += "<span class=""chip mcp"" title=""MCP servers configured"">$($r.McpCount) mcp</span>" }
        if ($r.Auth)      { $chips += '<span class="chip ok" title="credentials found - probably logged in">logged in</span>' }
        if ($r.Shadows.Count) { $chips += "<span class=""chip warn"" title=""shadowed on PATH: $(Enc ($r.Shadows -join ' | '))"">shadowed &times;$($r.Shadows.Count)</span>" }
        if ($r.Latest)    { $chips += "<button class=""chip upd"" data-cmd=""$(Enc $r.UpdateCmd)"" title=""click to copy: $(Enc $r.UpdateCmd)"">update $(Enc $r.Latest)</button>" }
        $chips
    }

    $sb = [System.Text.StringBuilder]::new()
    $chN = 0; $d = 0
    foreach ($grp in $detected | Group-Object Method | Sort-Object { $rank[$_.Name] }) {
        $chN++; $c = $chanColors[$grp.Name]; if (-not $c) { $c = '#d4ff3f' }
        $chId = '{0:D2}' -f $chN
        [void]$sb.AppendLine("<section class=""channel"" style=""--c:$c;--d:$d"">")
        [void]$sb.AppendLine("<div class=""ch-head""><span class=""ch-id"">$chId</span><h2>$(Enc $grp.Name)</h2><span class=""ch-count"">$($grp.Count)</span></div>")
        [void]$sb.AppendLine('<ol class="units">')
        $i = 0
        foreach ($r in $grp.Group | Sort-Object Name) {
            $i++; $d++; $idx = '{0:D2}' -f $i
            $ver = ''; if ($r.Version) { $ver = "<span class=""ver"">v$(Enc $r.Version)</span>" }
            $chips = New-UnitChips $r ($newNames -contains $r.Name)
            $k = Enc ("$($r.Name) $($r.Source) $($r.Method)".ToLower())
            [void]$sb.AppendLine("<li class=""unit"" style=""--d:$d"" data-k=""$k""><span class=""idx"">$idx</span><span class=""cmd"">$(Enc $r.Name)$ver</span><span class=""path"" title=""$(Enc $r.Source)"">$(Enc $r.Source)</span><span class=""chips"">$chips</span><span class=""dot""></span></li>")
        }
        [void]$sb.AppendLine('</ol></section>')
    }
    if ($possible.Count) {
        $chN++; $chId = '{0:D2}' -f $chN
        [void]$sb.AppendLine("<section class=""channel possible"" style=""--c:#8a8a80;--d:$d"">")
        [void]$sb.AppendLine("<div class=""ch-head""><span class=""ch-id"">$chId</span><h2>possible</h2><span class=""ch-count"">$($possible.Count)</span></div>")
        [void]$sb.AppendLine('<ol class="units">')
        $i = 0
        foreach ($r in $possible | Sort-Object Name) {
            $i++; $d++; $idx = '{0:D2}' -f $i
            $k = Enc ("$($r.Name) $($r.Source) $($r.Why)".ToLower())
            [void]$sb.AppendLine("<li class=""unit"" style=""--d:$d"" data-k=""$k""><span class=""idx"">$idx</span><span class=""cmd"">$(Enc $r.Name)</span><span class=""path"" title=""$(Enc $r.Why)"">$(Enc $r.Why)</span><span class=""chips""></span><span class=""dot hollow""></span></li>")
        }
        [void]$sb.AppendLine('</ol></section>')
    }
    if ($conflicted.Count) {
        $chN++; $chId = '{0:D2}' -f $chN
        [void]$sb.AppendLine("<section class=""channel confl"" style=""--c:#ffcf5a;--d:$d"">")
        [void]$sb.AppendLine("<div class=""ch-head""><span class=""ch-id"">$chId</span><h2>path conflicts</h2><span class=""ch-count"">$($conflicted.Count)</span></div>")
        [void]$sb.AppendLine('<ol class="units">')
        $i = 0
        foreach ($r in $conflicted | Sort-Object Name) {
            $i++; $d++; $idx = '{0:D2}' -f $i
            $shadowTxt = $r.Shadows -join '   |   '
            $k = Enc ("$($r.Name) conflict shadowed".ToLower())
            [void]$sb.AppendLine("<li class=""unit"" style=""--d:$d"" data-k=""$k""><span class=""idx"">$idx</span><span class=""cmd"">$(Enc $r.Name)</span><span class=""path"" title=""wins: $(Enc $r.Source)"">wins: $(Enc $r.Source) &middot; shadowed: $(Enc $shadowTxt)</span><span class=""chips""><span class=""chip warn"">$($r.Shadows.Count) shadowed</span></span><span class=""dot hollow""></span></li>")
        }
        [void]$sb.AppendLine('</ol></section>')
    }
    if ($stale.Count) {
        $chN++; $chId = '{0:D2}' -f $chN
        $reclaimTxt = Format-Size $reclaimMB; if (-not $reclaimTxt) { $reclaimTxt = '0 MB' }
        [void]$sb.AppendLine("<section class=""channel dead"" style=""--c:#ff6b5e;--d:$d"">")
        [void]$sb.AppendLine("<div class=""ch-head""><span class=""ch-id"">$chId</span><h2>dead weight &middot; reclaim ~$(Enc $reclaimTxt)</h2><span class=""ch-count"">$($stale.Count)</span></div>")
        [void]$sb.AppendLine('<ol class="units">')
        $i = 0
        foreach ($r in $stale | Sort-Object @{e={$_.SizeMB}} -Descending) {
            $i++; $d++; $idx = '{0:D2}' -f $i
            $ageTxt = 'never seen used'; if ($r.LastUsed) { $ageTxt = "last used $(Format-Age $r.LastUsed)" }
            $chips = ''
            if ($r.SizeMB) { $chips += "<span class=""chip"">$(Enc (Format-Size $r.SizeMB))</span>" }
            if ($r.UninstallCmd) { $chips += "<button class=""chip rm"" data-cmd=""$(Enc $r.UninstallCmd)"" title=""click to copy: $(Enc $r.UninstallCmd)"">copy uninstall</button>" }
            $k = Enc ("$($r.Name) dead stale unused".ToLower())
            [void]$sb.AppendLine("<li class=""unit"" style=""--d:$d"" data-k=""$k""><span class=""idx"">$idx</span><span class=""cmd"">$(Enc $r.Name)</span><span class=""path"">$(Enc $ageTxt)</span><span class=""chips"">$chips</span><span class=""dot""></span></li>")
        }
        [void]$sb.AppendLine('</ol></section>')
    }

    $generated = Get-Date -Format 'yyyy-MM-dd HH:mm'
    $dc = $detected.Count; $pc = $possible.Count
    $cc = (@($detected | Group-Object Method)).Count
    $machine = $env:COMPUTERNAME
    $diskLabel = Format-Size $totMB; if (-not $diskLabel) { $diskLabel = '0 MB' }

    $metaExtra = ''
    if ($newNames.Count) { $metaExtra = " &middot; <span class=""ac"">+$($newNames.Count) new since last scan</span>" }
    if ($reclaimMB -gt 0) { $metaExtra += " &middot; <span class=""wr"">$(Enc (Format-Size $reclaimMB)) reclaimable</span>" }

    if ($CheckUpdates) {
        $tile4 = "<div class=""stat$(if ($updates.Count) { ' warn' })"" style=""--i:3""><span class=""num"" data-count=""$($updates.Count)"">$($updates.Count)</span><span class=""lbl"">updates available</span></div>"
    } else {
        $tile4 = "<div class=""stat"" style=""--i:3""><span class=""num"" data-count=""$pc"">$pc</span><span class=""lbl"">possible / review</span></div>"
    }
    $tile5 = "<div class=""stat rank"" style=""--i:4""><span class=""num tiny"">$(Enc $rankName)</span><span class=""lbl"">fleet rank &middot; lv $dc</span></div>"

    # data embedded for the trend sparkline + the shareable fleet card
    $histJson = '[]'
    try { $histJson = (ConvertTo-Json -InputObject @($histArr) -Depth 3 -Compress) -replace '<', ('\' + 'u003c') } catch {}
    $cardAgents = @($detected | Sort-Object Name | Select-Object -First 18 | ForEach-Object {
        [pscustomobject]@{ n = $_.Name; v = $_.Version; m = $_.Method }
    })
    $cardObj = [pscustomobject]@{
        dc = $dc; cc = $cc; disk = $diskLabel; rank = $rankName; active = $active30
        reclaim = $reclaimLabel; hostn = "$machine"; date = $generated; agents = $cardAgents
    }
    $cardJson = '{}'
    try { $cardJson = (ConvertTo-Json -InputObject $cardObj -Depth 4 -Compress) -replace '<', ('\' + 'u003c') } catch {}

    $html = @"
<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Coding Agents // Fleet Manifest</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Syne:wght@600;700;800&family=JetBrains+Mono:wght@400;500;700&display=swap" rel="stylesheet">
<style>
*{box-sizing:border-box;margin:0;padding:0}
:root{--bg:#08080a;--panel:#0d0d11;--line:#1c1c23;--ink:#eceae0;--mut:#74746a;--accent:#d4ff3f;--warn:#ffcf5a}
html{scroll-behavior:smooth}
body{background:var(--bg);color:var(--ink);font-family:'JetBrains Mono',ui-monospace,monospace;-webkit-font-smoothing:antialiased;min-height:100vh;position:relative;overflow-x:hidden}
body::before{content:"";position:fixed;inset:0;z-index:0;pointer-events:none;background:radial-gradient(110% 80% at 80% -10%,rgba(212,255,63,.10),transparent 55%),radial-gradient(90% 70% at -5% 110%,rgba(90,209,255,.06),transparent 55%)}
body::after{content:"";position:fixed;inset:0;z-index:0;pointer-events:none;background-image:linear-gradient(rgba(255,255,255,.022) 1px,transparent 1px),linear-gradient(90deg,rgba(255,255,255,.022) 1px,transparent 1px);background-size:46px 46px;-webkit-mask-image:radial-gradient(120% 100% at 50% 0%,#000,transparent 82%);mask-image:radial-gradient(120% 100% at 50% 0%,#000,transparent 82%)}
.grain{position:fixed;inset:0;z-index:2;pointer-events:none;opacity:.045;mix-blend-mode:overlay;background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='160' height='160'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.85' numOctaves='2' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E")}
.wrap{position:relative;z-index:1;max-width:1080px;margin:0 auto;padding:clamp(30px,6vw,80px) clamp(20px,5vw,60px) 70px}
.eyebrow{font-size:11.5px;letter-spacing:.36em;text-transform:uppercase;color:var(--accent);display:flex;align-items:center;gap:13px;opacity:0;animation:rise .6s ease forwards .05s}
.eyebrow::before{content:"";width:38px;height:1px;background:var(--accent)}
h1{font-family:'Syne',sans-serif;font-weight:800;font-size:clamp(56px,13vw,170px);line-height:.82;letter-spacing:-.045em;margin:.16em 0 .14em;clip-path:inset(0 0 110% 0);animation:clipUp 1s cubic-bezier(.2,.8,.15,1) forwards .12s}
h1 em{font-style:normal;color:transparent;-webkit-text-stroke:1.4px var(--mut)}
.meta{color:var(--mut);font-size:12.5px;letter-spacing:.05em;opacity:0;animation:rise .6s ease forwards .42s}
.meta b{color:var(--ink);font-weight:500}.meta .ac{color:var(--accent)}
.stats{display:flex;flex-wrap:wrap;gap:13px;margin:40px 0 4px}
.stat{flex:1;min-width:148px;border:1px solid var(--line);background:linear-gradient(180deg,rgba(255,255,255,.022),transparent);padding:20px 22px;position:relative;opacity:0;animation:rise .6s ease forwards;animation-delay:calc(.5s + var(--i,0)*.09s)}
.stat::after{content:"";position:absolute;top:9px;right:9px;width:7px;height:7px;border-top:1px solid var(--mut);border-right:1px solid var(--mut)}
.stat .num{font-family:'Syne',sans-serif;font-weight:800;font-size:48px;line-height:1;display:block;color:var(--ink);font-variant-numeric:tabular-nums}
.stat.lead .num{color:var(--accent)}
.stat.warn .num{color:var(--warn)}
.stat .num.small{font-size:34px;padding-top:9px}
.stat .lbl{font-size:10.5px;letter-spacing:.24em;text-transform:uppercase;color:var(--mut);margin-top:12px;display:block}
.bar{display:flex;gap:13px;margin-top:44px;opacity:0;animation:rise .6s ease forwards .8s}
.search{width:100%;flex:1;background:var(--panel);border:1px solid var(--line);color:var(--ink);font:inherit;font-size:13px;padding:14px 20px;letter-spacing:.05em;outline:none}
.search:focus{border-color:var(--accent)}
.search::placeholder{color:var(--mut)}
.sharebtn{background:transparent;border:1px solid var(--accent);color:var(--accent);font:inherit;font-size:11.5px;letter-spacing:.16em;text-transform:uppercase;padding:14px 22px;cursor:pointer;white-space:nowrap;transition:background .18s,color .18s}
.sharebtn:hover{background:var(--accent);color:#08080a}
.trend{margin-top:16px;border:1px solid var(--line);background:var(--panel);padding:14px 20px 10px;display:flex;flex-direction:column;gap:7px}
.trend svg{width:100%;height:64px;display:block}
.trend .tl{color:var(--mut);font-size:10.5px;letter-spacing:.2em;text-transform:uppercase}
.channels{margin-top:18px;display:grid;gap:18px}
.channel{border:1px solid var(--line);background:var(--panel);position:relative;overflow:hidden;opacity:0;animation:rise .6s ease forwards;animation-delay:calc(var(--d,0)*42ms + .35s)}
.channel::before{content:"";position:absolute;left:0;top:0;bottom:0;width:3px;background:var(--c)}
.channel.possible{border-style:dashed;opacity:.92}
.ch-head{display:flex;align-items:center;gap:18px;padding:19px 26px 16px;border-bottom:1px solid var(--line)}
.ch-id{font-family:'Syne',sans-serif;font-weight:800;font-size:30px;line-height:1;color:transparent;-webkit-text-stroke:1px var(--c)}
.ch-head h2{font-size:13.5px;letter-spacing:.28em;text-transform:uppercase;font-weight:500;color:var(--ink)}
.ch-count{margin-left:auto;font-size:12px;color:var(--c);border:1px solid var(--c);padding:3px 12px;letter-spacing:.12em;font-variant-numeric:tabular-nums}
.units{list-style:none;padding:7px 0}
.unit{display:grid;grid-template-columns:2.8rem minmax(7rem,15rem) 1fr auto auto;align-items:center;gap:18px;padding:12px 26px;position:relative;opacity:0;transform:translateY(10px);animation:rise .5s cubic-bezier(.2,.7,.15,1) forwards;animation-delay:calc(var(--d,0)*36ms + .4s)}
.unit::before{content:"";position:absolute;left:0;top:0;bottom:0;width:0;background:var(--c);opacity:.09;transition:width .28s cubic-bezier(.2,.7,.15,1)}
.unit:hover::before{width:100%}
.unit:hover .cmd{color:var(--c)}.unit:hover .path{color:var(--ink)}
.idx{color:var(--mut);font-size:12px;font-variant-numeric:tabular-nums}
.cmd{font-weight:700;font-size:14.5px;color:var(--ink);transition:color .2s;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ver{color:var(--mut);font-weight:400;font-size:11px;margin-left:9px;letter-spacing:.02em}
.path{color:var(--mut);font-size:12px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;transition:color .2s}
.chips{display:flex;gap:7px;align-items:center;justify-self:end}
.chip{font-family:inherit;font-size:10.5px;letter-spacing:.08em;color:var(--mut);border:1px solid var(--line);background:transparent;padding:2.5px 9px;white-space:nowrap}
.chip.new{color:var(--accent);border-color:var(--accent)}
.chip.upd{color:var(--warn);border-color:var(--warn);cursor:pointer;transition:background .18s,color .18s}
.chip.upd:hover{background:var(--warn);color:#08080a}
.chip.mcp{color:#5ad1ff;border-color:rgba(90,209,255,.4)}
.chip.ok{color:var(--accent);border-color:rgba(212,255,63,.4)}
.chip.warn{color:var(--warn);border-color:var(--warn)}
.chip.rm{color:#ff6b5e;border-color:#ff6b5e;cursor:pointer;transition:background .18s,color .18s}
.chip.rm:hover{background:#ff6b5e;color:#08080a}
.chips{flex-wrap:wrap;row-gap:4px;max-width:36rem}
.meta .wr{color:#ff6b5e}
.stat .num.tiny{font-size:19px;line-height:1.25;padding-top:16px;letter-spacing:.02em}
.channel.dead{border-style:dashed}
.dot{width:8px;height:8px;border-radius:50%;background:var(--c);box-shadow:0 0 11px var(--c);justify-self:end}
.dot.hollow{background:transparent;border:1px solid var(--c);box-shadow:none}
footer{margin-top:48px;padding-top:18px;border-top:1px solid var(--line);display:flex;justify-content:space-between;flex-wrap:wrap;gap:10px;color:var(--mut);font-size:11.5px;letter-spacing:.06em}
footer .ac{color:var(--accent)}
@keyframes rise{to{opacity:1;transform:none}}
@keyframes clipUp{to{clip-path:inset(0 0 -12% 0)}}
@media(max-width:720px){.unit{grid-template-columns:2.2rem 1fr auto auto;gap:12px}.unit .path{display:none}.chips .chip:not(.upd):not(.new):not(.rm):not(.warn){display:none}}
@media(prefers-reduced-motion:reduce){*{animation:none!important}.eyebrow,.meta,.stat,.channel,.unit,.search{opacity:1!important;transform:none!important}h1{clip-path:none!important}}
</style></head>
<body>
<div class="grain"></div>
<div class="wrap">
<div class="eyebrow">// agent fleet manifest</div>
<h1>CODING<br><em>AGENTS</em></h1>
<p class="meta">scan complete &middot; <b>$dc</b> agents across <b>$cc</b> <span class="ac">channels</span> &middot; <b>$diskLabel</b> on disk &middot; host <b>$(Enc $machine)</b> &middot; $generated$metaExtra</p>
<div class="stats">
<div class="stat lead" style="--i:0"><span class="num" data-count="$dc">$dc</span><span class="lbl">detected</span></div>
<div class="stat" style="--i:1"><span class="num" data-count="$cc">$cc</span><span class="lbl">install channels</span></div>
<div class="stat" style="--i:2"><span class="num small">$diskLabel</span><span class="lbl">disk footprint</span></div>
$tile4
$tile5
</div>
<div class="bar">
<input id="q" class="search" type="text" placeholder="filter agents...  ( press / to focus, esc to clear )" spellcheck="false" autocomplete="off">
<button id="sharebtn" class="sharebtn" title="download a 1200x630 png of your fleet">share card</button>
</div>
<div class="trend" id="trend" hidden><svg id="spark" viewBox="0 0 600 64" preserveAspectRatio="none"></svg><span class="tl" id="trendlbl">fleet over time</span></div>
<div class="channels">
$($sb.ToString())</div>
<footer><span>generated by <span class="ac">list-coding-agents.ps1</span></span><span>heuristic detection &middot; usage intel &middot; tiered confidence</span></footer>
</div>
<script type="application/json" id="histData">$histJson</script>
<script type="application/json" id="cardData">$cardJson</script>
<script>
(function(){
  var els = document.querySelectorAll('[data-count]');
  for (var k=0;k<els.length;k++){ (function(el){
    var target = parseInt(el.getAttribute('data-count'),10) || 0;
    var dur = 1000, t0 = performance.now();
    function step(now){
      var p = Math.min((now - t0)/dur, 1);
      var e = 1 - Math.pow(1 - p, 3);
      el.textContent = Math.round(target * e);
      if (p < 1) requestAnimationFrame(step);
    }
    requestAnimationFrame(step);
  })(els[k]); }
})();
(function(){
  var q = document.getElementById('q');
  if (!q) return;
  function applyFilter(){
    var v = q.value.toLowerCase();
    var chans = document.querySelectorAll('.channel');
    for (var i=0;i<chans.length;i++){
      var units = chans[i].querySelectorAll('.unit'), shown = 0;
      for (var j=0;j<units.length;j++){
        var key = units[j].getAttribute('data-k') || '';
        var hit = key.indexOf(v) > -1;
        units[j].style.display = hit ? '' : 'none';
        if (hit) shown++;
      }
      chans[i].style.display = shown ? '' : 'none';
    }
  }
  q.addEventListener('input', applyFilter);
  document.addEventListener('keydown', function(e){
    if (e.key === '/' && document.activeElement !== q) { e.preventDefault(); q.focus(); }
    if (e.key === 'Escape' && q.value) { q.value = ''; applyFilter(); q.blur(); }
  });
})();
(function(){
  function copyText(cmd, done){
    function fallback(){
      var ta = document.createElement('textarea');
      ta.value = cmd; ta.style.position = 'fixed'; ta.style.opacity = '0';
      document.body.appendChild(ta); ta.select();
      try { document.execCommand('copy'); } catch(err) {}
      document.body.removeChild(ta); done();
    }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(cmd).then(done, fallback);
    } else { fallback(); }
  }
  document.addEventListener('click', function(e){
    var b = e.target && e.target.closest ? e.target.closest('button[data-cmd]') : null;
    if (!b) return;
    copyText(b.getAttribute('data-cmd') || '', function(){
      var t = b.textContent;
      b.textContent = 'copied!';
      setTimeout(function(){ b.textContent = t; }, 1200);
    });
  });
})();
(function(){
  var el = document.getElementById('histData'); if (!el) return;
  var h = []; try { h = JSON.parse(el.textContent) || []; } catch(err) {}
  if (!h || h.length < 2) return;
  var box = document.getElementById('trend'), svg = document.getElementById('spark');
  if (!box || !svg) return;
  box.hidden = false;
  var W = 600, H = 64, P = 6, NS = 'http://www.w3.org/2000/svg';
  function line(vals, color, w){
    var mx = Math.max.apply(null, vals), mn = Math.min.apply(null, vals);
    if (mx === mn) { mx = mn + 1; }
    var pts = [];
    for (var i = 0; i < vals.length; i++){
      var x = P + (W - 2*P) * i / (vals.length - 1);
      var y = H - P - (H - 2*P) * (vals[i] - mn) / (mx - mn);
      pts.push(x.toFixed(1) + ',' + y.toFixed(1));
    }
    var p = document.createElementNS(NS, 'polyline');
    p.setAttribute('points', pts.join(' '));
    p.setAttribute('fill', 'none');
    p.setAttribute('stroke', color);
    p.setAttribute('stroke-width', w);
    p.setAttribute('vector-effect', 'non-scaling-stroke');
    svg.appendChild(p);
  }
  var counts = [], mbs = [];
  for (var i = 0; i < h.length; i++){ counts.push(h[i].c || 0); mbs.push(h[i].mb || 0); }
  line(mbs, '#2e2e38', 2);
  line(counts, '#d4ff3f', 2);
  var lbl = document.getElementById('trendlbl');
  if (lbl){
    var mbNow = mbs[mbs.length - 1];
    var mbTxt = mbNow >= 1024 ? (mbNow/1024).toFixed(1) + ' gb' : Math.round(mbNow) + ' mb';
    lbl.textContent = 'fleet over time - ' + h.length + ' scans - agents ' + counts[0] + ' to ' + counts[counts.length-1] + ' - disk now ' + mbTxt;
  }
})();
(function(){
  var btn = document.getElementById('sharebtn'), el = document.getElementById('cardData');
  if (!btn || !el) return;
  var D = {}; try { D = JSON.parse(el.textContent) || {}; } catch(err) {}
  btn.addEventListener('click', function(){
    var fs = [
      document.fonts.load('800 104px Syne'),
      document.fonts.load('800 34px Syne'),
      document.fonts.load('700 22px "JetBrains Mono"'),
      document.fonts.load('400 19px "JetBrains Mono"')
    ];
    Promise.all(fs).then(draw, draw);
  });
  function draw(){
    var W = 1200, H = 630;
    var cv = document.createElement('canvas'); cv.width = W; cv.height = H;
    var x = cv.getContext('2d');
    x.fillStyle = '#08080a'; x.fillRect(0, 0, W, H);
    x.strokeStyle = 'rgba(255,255,255,.03)'; x.lineWidth = 1;
    var g;
    for (g = 0; g <= W; g += 46){ x.beginPath(); x.moveTo(g, 0); x.lineTo(g, H); x.stroke(); }
    for (g = 0; g <= H; g += 46){ x.beginPath(); x.moveTo(0, g); x.lineTo(W, g); x.stroke(); }
    var rg = x.createRadialGradient(W*0.85, 0, 0, W*0.85, 0, 720);
    rg.addColorStop(0, 'rgba(212,255,63,.14)'); rg.addColorStop(1, 'rgba(212,255,63,0)');
    x.fillStyle = rg; x.fillRect(0, 0, W, H);
    x.fillStyle = '#d4ff3f'; x.font = '700 19px "JetBrains Mono"';
    x.fillText('// AGENT FLEET MANIFEST', 64, 74);
    x.fillStyle = '#eceae0'; x.font = '800 104px Syne';
    x.fillText('CODING AGENTS', 58, 178);
    var rank = (D.rank || '').toString();
    if (rank){
      x.font = '800 34px Syne';
      var rw = x.measureText(rank).width;
      x.strokeStyle = '#d4ff3f'; x.lineWidth = 2;
      x.strokeRect(W - 64 - rw - 44, 216, rw + 44, 62);
      x.fillStyle = '#d4ff3f';
      x.fillText(rank, W - 64 - rw - 22, 259);
    }
    var stats = [
      [(D.dc || 0) + '', 'DETECTED'],
      [(D.cc || 0) + '', 'CHANNELS'],
      [(D.disk || '0 MB') + '', 'ON DISK'],
      [(D.active || 0) + '/' + (D.dc || 0), 'ACTIVE 30D']
    ];
    for (var s = 0; s < stats.length; s++){
      var sx = 64 + s * 205;
      x.fillStyle = '#eceae0'; x.font = '800 44px Syne';
      x.fillText(stats[s][0], sx, 266);
      x.fillStyle = '#74746a'; x.font = '400 15px "JetBrains Mono"';
      x.fillText(stats[s][1], sx, 292);
    }
    x.strokeStyle = '#1c1c23'; x.lineWidth = 1;
    x.beginPath(); x.moveTo(64, 322); x.lineTo(W - 64, 322); x.stroke();
    var ags = D.agents || [];
    for (var a = 0; a < ags.length && a < 18; a++){
      var col = a % 3, row = Math.floor(a / 3);
      var ax = 64 + col * 368, ay = 368 + row * 36;
      var nm = (ags[a].n || '').toString();
      if (nm.length > 20) { nm = nm.slice(0, 19) + '~'; }
      x.fillStyle = '#eceae0'; x.font = '700 21px "JetBrains Mono"';
      x.fillText(nm, ax, ay);
      var vv = (ags[a].v || '').toString();
      if (vv){
        var nw = x.measureText(nm).width;
        x.fillStyle = '#74746a'; x.font = '400 15px "JetBrains Mono"';
        x.fillText('v' + vv, ax + nw + 12, ay);
      }
    }
    x.fillStyle = '#74746a'; x.font = '400 16px "JetBrains Mono"';
    x.fillText((D.hostn || '') + '  -  ' + (D.date || ''), 64, 592);
    x.fillStyle = '#d4ff3f'; x.font = '700 16px "JetBrains Mono"';
    var tag = 'list-coding-agents.ps1';
    x.fillText(tag, W - 64 - x.measureText(tag).width, 592);
    if (cv.toBlob){
      cv.toBlob(function(b){
        if (!b) return;
        var a2 = document.createElement('a');
        a2.href = URL.createObjectURL(b);
        a2.download = 'agent-fleet-card.png';
        document.body.appendChild(a2); a2.click(); document.body.removeChild(a2);
        setTimeout(function(){ URL.revokeObjectURL(a2.href); }, 4000);
      }, 'image/png');
    }
  }
})();
</script>
</body></html>
"@
    $htmlPath = Join-Path $PSScriptRoot 'coding-agents.html'
    $html | Out-File -LiteralPath $htmlPath -Encoding utf8
    Write-Host "HTML report: $htmlPath" -ForegroundColor Green
    try { Invoke-Item -LiteralPath $htmlPath } catch {}
}
