<#
.SYNOPSIS
    Detects AI coding-agent CLIs installed on this Windows machine.

.DESCRIPTION
    Scans PATH (non-Windows dirs), npm global packages, and winget for coding
    agents. Scoring combines:

      1. Exact / near-exact known CLI names (bare binaries often ship with no
         PE metadata - codex/grok/kimi/jcode are empty shells without this)
      2. Install-path signatures (.grok\bin, OpenAI\Codex, .kimi-code, ...)
      3. npm package.json description / keywords / real AI SDK deps
      4. PE VersionInfo when present (Claude Code is the good example)
      5. winget package id / publisher

    Pure MCP utility servers (excel-csv-mcp, screenshot-mcp, ...) are excluded:
    @modelcontextprotocol/sdk alone is NOT treated as an agent signal.

    Tiers:
      DETECTED  score >= 4
      POSSIBLE  score 2-3

    Escape hatch: agents-extra.txt (one command name per line).

.PARAMETER IncludeEditors
    Also include GUI AI editors (Cursor/Windsurf-style).
.PARAMETER ShowReasons
    Print score signals per hit.
.PARAMETER NoHtml
    Skip writing/opening the HTML report.
.PARAMETER SkipWinget
    Skip winget list (faster).
#>
[CmdletBinding()]
param(
    [switch]$IncludeEditors,
    [switch]$ShowReasons,
    [switch]$NoHtml,
    [switch]$SkipWinget
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Lexicons - linguistic + known CLI names (not a closed product catalogue).
# Bare agent installers often embed zero metadata, so exact command names
# matter; unknown agents still surface via npm/winget/path/PE signals.
# ---------------------------------------------------------------------------

# Exact command basenames that are coding-agent CLIs when found on PATH.
$KnownCli = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@(
        'claude', 'codex', 'gemini', 'grok', 'kimi', 'opencode', 'openclaw',
        'qwen', 'jcode', 'mimo', 'vibe', 'aider', 'cody', 'crush', 'droid',
        'amp', 'goose', 'cline', 'kilocode', 'kilo', 'factory', 'blackbox',
        'auggie', 'cursor-agent', 'windsurf', 'pi', 'sg', 'src', 'continue',
        'roo', 'roo-code', 'continue-cli', 'copilot', 'gh-copilot'
    ),
    [StringComparer]::OrdinalIgnoreCase
)

# Path fragments that strongly imply an agent install tree.
$PathSignatures = @(
    '(?i)\\\.local\\bin\\claude',
    '(?i)\\OpenAI\\Codex\\',
    '(?i)\\\.grok\\bin\\',
    '(?i)\\\.kimi-code\\',
    '(?i)\\\.mimocode\\',
    '(?i)\\jcode\\bin\\',
    '(?i)\\Programs\\cursor\\',
    '(?i)\\Programs\\Windsurf\\',
    '(?i)\\gemini-cli\\',
    '(?i)\\opencode',
    '(?i)\\anthropic\\',
    '(?i)\\Claude\\'
)

# Note: bare "google" is intentionally omitted (matches Android platform-tools, etc.).
$AiVendors = 'anthropic|openai|moonshot|mistral|cohere|sourcegraph|augment(code)?|codeium|anysphere|factory|sst|kilocode|perplexity|deepseek|\bxai\b'
# Real model SDKs - deliberately NOT modelcontextprotocol (shared by non-agents).
$AiSdkDep  = '(?i)@anthropic-ai/|(^|/)openai(@|/|$)|@google/genai|generative-ai|langchain|ollama|@ai-sdk/|^ai$|mistralai|@google/generative-ai'
$BrandWords = 'claude|gemini|copilot|codex|aider|cody|goose|opencode|openclaw|cline|roo[- ]?code|droid|crush|qwen|grok|kimi|antigravity|blackbox|windsurf|cursor|mimo|jcode|vibe|\bgpt\b|\bllm\b|kilocode|factory'
$AgentPhrase = 'coding[- ]?agent|code[- ]?agent|agentic|ai[- ]?coding|ai pair|pair program|autonomous (coding|software|dev)|ai software engineer|terminal.*agent|ai[- ]?powered coding|coding assistant'
# Hard exclude: package managers, pure MCP utilities, scaffolding, etc.
$HardExclude = '(?i)install .*skill|skill for|\bdeploy(ment)?\b|package manager|boilerplate|scaffold|video extension|image extension|redistributable|driver|\bmcp[- ]?server\b|^mcp\b|\bmodel context protocol\b'

function Get-AgentScore {
    param(
        [string]$Text,
        [string[]]$Deps,
        [string]$Publisher,
        [string]$Name,
        [string]$Path
    )

    $name = if ($Name) { $Name.ToLowerInvariant() } else { '' }
    # Do NOT fold the full filesystem path into $t. Sibling tools in an agent
    # install dir (.kimi-code\bin\fd.exe) would inherit brand words from the
    # folder name. Path is only used for signature checks below.
    $t = (($Text, ($Deps -join ' '), $Publisher, $name) -join ' ')
    $tLower = $t.ToLowerInvariant()
    $score = 0
    $why = [System.Collections.Generic.List[string]]::new()

    # Pure MCP utilities / non-agents - bail early unless exact known CLI.
    $isKnown = $KnownCli.Contains($name)
    if (-not $isKnown) {
        if ($name -match '(?i)(^|-)mcp($|-)|-mcp-server$|^mcp-') {
            return [pscustomobject]@{ Score = -99; Why = 'excluded (mcp utility)' }
        }
        if ($tLower -match $HardExclude -and $tLower -notmatch $AgentPhrase) {
            return [pscustomobject]@{ Score = -99; Why = 'excluded (non-agent phrase)' }
        }
        if ($name -match '(?i)(launcher|host|helper|shim|wrapper|updater|unins)') {
            return [pscustomobject]@{ Score = -99; Why = 'excluded (helper binary)' }
        }
    }

    if ($isKnown) {
        $score += 6
        $why.Add('known CLI name')
    }

    # Path signatures only boost the primary agent CLI, not sibling tools.
    if ($Path -and ($isKnown -or $name -match "^(?:$BrandWords)$")) {
        foreach ($pat in $PathSignatures) {
            if ($Path -match $pat) {
                $score += 3
                $why.Add('install path signature')
                break
            }
        }
    }

    if ($tLower -match $AgentPhrase) {
        $score += 4
        $why.Add('coding-agent phrase')
    }

    # Vendor from PE CompanyName / package text only (never from path).
    $vendorText = (($Publisher, $Text) -join ' ')
    if ($vendorText -match "(?i)($AiVendors)") {
        if ($Publisher -notmatch '(?i)^(Node\.js|Oven|Microsoft Corporation)$') {
            $score += 3
            $why.Add('AI vendor')
        }
    }

    $sdkHits = @($Deps | Where-Object { $_ -and ($_ -match $AiSdkDep) })
    if ($sdkHits.Count -gt 0) {
        $score += 3
        $why.Add('AI SDK dependency')
    }

    if ($tLower -match '\bagent\b' -and $tLower -match 'code|coding|cli|terminal|dev') {
        $score += 2
        $why.Add('agent + code')
    }

    if ($tLower -match "(?i)($BrandWords)") {
        $score += 1
        $why.Add('model/brand name')
        if ($tLower -match 'cli|code|coding|terminal|assistant') {
            $score += 2
            $why.Add('brand + cli/code')
        }
        # Exact basename is the brand word alone (codex, grok, kimi...).
        if ($name -match "^(?:$BrandWords)$") {
            $score += 2
            $why.Add('brand command')
        }
    }

    if ($tLower -match '(^|[^a-z])ai([^a-z]|$)' -and $tLower -match 'code|coding|cli|agent|assistant') {
        $score += 1
        $why.Add('ai + code token')
    }

    [pscustomobject]@{ Score = $score; Why = ($why -join ', ') }
}

function Get-NpmMeta {
    $map = @{}
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) { return $map }

    $root = $null
    try { $root = (& npm root -g 2>$null | Out-String).Trim() } catch { return $map }
    if (-not $root -or -not (Test-Path -LiteralPath $root)) { return $map }

    $pkgDirs = [System.Collections.Generic.List[string]]::new()
    foreach ($d in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue) {
        if ($d.Name -like '@*') {
            foreach ($sub in Get-ChildItem -LiteralPath $d.FullName -Directory -ErrorAction SilentlyContinue) {
                $pkgDirs.Add($sub.FullName)
            }
        } else {
            $pkgDirs.Add($d.FullName)
        }
    }

    foreach ($dir in $pkgDirs) {
        $pj = Join-Path $dir 'package.json'
        if (-not (Test-Path -LiteralPath $pj)) { continue }
        try {
            $j = Get-Content -LiteralPath $pj -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch { continue }

        $propNames = @($j.PSObject.Properties.Name)
        if ($propNames -notcontains 'bin' -or -not $j.bin) { continue }

        $cmds = if ($j.bin -is [string]) {
            $fallback = if ($propNames -contains 'name') { ($j.name -split '/')[-1] } else { Split-Path $dir -Leaf }
            @($fallback)
        } else {
            @($j.bin.PSObject.Properties.Name)
        }

        $deps = [System.Collections.Generic.List[string]]::new()
        foreach ($section in @('dependencies', 'optionalDependencies', 'peerDependencies')) {
            if ($propNames -notcontains $section) { continue }
            $block = $j.$section
            if ($block) {
                foreach ($p in $block.PSObject.Properties) { [void]$deps.Add([string]$p.Name) }
            }
        }

        $kw = @()
        if ($propNames -contains 'keywords' -and $j.keywords) { $kw = @($j.keywords) }

        $pkgName = if ($propNames -contains 'name') { [string]$j.name } else { '' }
        $pkgVer  = if ($propNames -contains 'version') { [string]$j.version } else { '' }
        $pkgDesc = if ($propNames -contains 'description') { [string]$j.description } else { '' }

        $meta = [pscustomobject]@{
            Package = $pkgName
            Version = $pkgVer
            Text    = (@($pkgName, $pkgDesc) + $kw) -join ' '
            Deps    = @($deps)
        }
        foreach ($c in $cmds) {
            if ($c) { $map[$c.ToLowerInvariant()] = $meta }
        }
    }
    $map
}

function Get-PathCandidates {
    $exts = @(
        $env:PATHEXT -split ';' |
            Where-Object { $_ } |
            ForEach-Object { $_.ToUpperInvariant() }
    ) + @('.PS1') | Select-Object -Unique

    $dirs = $env:PATH -split ';' |
        Where-Object { $_ -and $_.Trim() } |
        ForEach-Object { $_.Trim().TrimEnd('\') } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Container } |
        Select-Object -Unique

    $seen = @{}
    $winDir = $env:WINDIR

    foreach ($dir in $dirs) {
        # Skip pure Windows system dirs (keep WindowsApps for winget shims).
        if ($winDir -and $dir.StartsWith($winDir, [StringComparison]::OrdinalIgnoreCase) -and
            $dir -notmatch '(?i)\\WindowsApps$') { continue }

        try {
            $files = Get-ChildItem -LiteralPath $dir -File -ErrorAction Stop
        } catch { continue }

        foreach ($f in $files) {
            $ext = $f.Extension.ToUpperInvariant()
            if ($exts -notcontains $ext) { continue }
            $name = $f.BaseName.ToLowerInvariant()
            if (-not $name) { continue }
            if (-not $seen.ContainsKey($name)) {
                $seen[$name] = $f.FullName
            }
        }
    }

    $seen.GetEnumerator() | ForEach-Object {
        [pscustomobject]@{ Command = $_.Key; Path = $_.Value }
    }
}

function Get-Method {
    param([string]$Path)
    if (-not $Path) { return 'unknown' }
    if ($Path -match '(?i)\\AppData\\Roaming\\npm\\|\\node_modules\\') { return 'npm' }
    if ($Path -match '(?i)\\WindowsApps\\|\\WinGet\\') { return 'winget' }
    if ($Path -match '(?i)\\Python\\.*\\Scripts\\|\\uv\\|\\pipx\\') { return 'pip / uv' }
    if ($Path -match '(?i)\\scoop\\') { return 'scoop' }
    if ($Path -match '(?i)\\.cargo\\bin\\') { return 'cargo' }
    if ($Path -match '(?i)\\.bun\\bin\\') { return 'bun' }
    if ($Path -match '(?i)\\.local\\bin\\|\\Programs\\') { return 'standalone installer' }
    return 'standalone installer'
}

function Get-Kind {
    param([string]$Path, [string]$Name)
    if ($Path -match '(?i)\\Programs\\(cursor|windsurf|kiro)\\' -or
        $Name -match '^(cursor|windsurf|kiro)$') { return 'editor' }
    return 'cli'
}

function Get-PeText {
    param([string]$Path)
    if (-not $Path -or $Path -notmatch '\.exe$') {
        return [pscustomobject]@{ Text = ''; Publisher = ''; Version = '' }
    }
    try {
        $vi = (Get-Item -LiteralPath $Path).VersionInfo
        # Node/Bun wrappers are noise for classification.
        $company = [string]$vi.CompanyName
        $product = [string]$vi.ProductName
        $desc = [string]$vi.FileDescription
        if ($company -match '(?i)^(Node\.js|Oven)$' -or $product -match '(?i)^(Node\.js|Bun)$') {
            # Wrapper runtime version is not the agent version.
            return [pscustomobject]@{ Text = ''; Publisher = ''; Version = '' }
        }
        [pscustomobject]@{
            Text      = (@($product, $desc) -join ' ').Trim()
            Publisher = $company
            Version   = if ($vi.ProductVersion) { [string]$vi.ProductVersion } else { [string]$vi.FileVersion }
        }
    } catch {
        [pscustomobject]@{ Text = ''; Publisher = ''; Version = '' }
    }
}

# --- load overrides ---------------------------------------------------------
Write-Host "Scanning npm global packages..." -ForegroundColor DarkGray
$npmMeta = Get-NpmMeta

$extraFile = Join-Path $PSScriptRoot 'agents-extra.txt'
$extra = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
if (Test-Path -LiteralPath $extraFile) {
    Get-Content -LiteralPath $extraFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -and $line -notmatch '^\s*#') { [void]$extra.Add($line.ToLowerInvariant()) }
    }
}

# --- PATH candidates --------------------------------------------------------
Write-Host "Scanning PATH commands..." -ForegroundColor DarkGray
$rows = [System.Collections.Generic.List[object]]::new()
$haveNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

foreach ($c in Get-PathCandidates) {
    $name = $c.Command
    $path = $c.Path
    # Skip hidden/backup/old launcher basenames (e.g. .jcode-launcher-old-...).
    if ($name.StartsWith('.')) { continue }

    $text = $name
    $deps = @()
    $publisher = ''
    $version = ''
    $method = Get-Method $path
    $kind = Get-Kind -Path $path -Name $name

    if ($npmMeta.ContainsKey($name)) {
        $m = $npmMeta[$name]
        $text = $m.Text
        $deps = $m.Deps
        $method = 'npm'
        if ($m.Version) { $version = $m.Version }
    }

    $pe = Get-PeText -Path $path
    if ($pe.Text) { $text = (@($text, $pe.Text) -join ' ').Trim() }
    if ($pe.Publisher) { $publisher = $pe.Publisher }
    if (-not $version -and $pe.Version) { $version = $pe.Version }

    $s = Get-AgentScore -Text $text -Deps $deps -Publisher $publisher -Name $name -Path $path
    if ($extra.Contains($name) -and $s.Score -lt 4) {
        $s = [pscustomobject]@{ Score = 5; Why = 'agents-extra.txt override' }
    }

    if ($s.Score -lt 2) { continue }

    [void]$haveNames.Add($name)
    $rows.Add([pscustomobject]@{
        Name    = $name
        Command = $name
        Source  = $path
        Method  = $method
        Kind    = $kind
        Version = $version
        Score   = $s.Score
        Why     = $s.Why
    })
}

# --- winget (optional; catches agents not on PATH) --------------------------
if (-not $SkipWinget -and (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host "Scanning winget packages..." -ForegroundColor DarkGray
    $wingetLines = @()
    try {
        # Prefer machine-readable output when available.
        $json = & winget list --disable-interactivity --accept-source-agreements 2>$null | Out-String
        $wingetLines = $json -split "`r?`n"
    } catch {
        $wingetLines = @()
    }

    foreach ($line in $wingetLines) {
        if ($line -notmatch '[A-Za-z]') { continue }
        # winget table: Name  Id  Version  Available  Source  (2+ spaces)
        $parts = $line -split '\s{2,}' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        if ($parts.Count -lt 2) { continue }
        $pkgName = $parts[0]
        $id = $parts[1]
        if ($pkgName -eq 'Name' -or $id -eq 'Id') { continue }
        if ($pkgName -match '^(The following|No installed|-{2,})') { continue }

        $publisher = ($id -split '\.')[0]
        $key = (($pkgName -split '\s+')[0]).ToLowerInvariant()
        if ($haveNames.Contains($key)) { continue }

        $s = Get-AgentScore -Text ("$pkgName $id") -Deps @() -Publisher $publisher -Name $pkgName -Path $id
        if ($s.Score -ge 2) {
            [void]$haveNames.Add($key)
            $rows.Add([pscustomobject]@{
                Name    = $pkgName
                Command = '(winget)'
                Source  = $id
                Method  = 'winget'
                Kind    = 'cli'
                Version = if ($parts.Count -ge 3) { $parts[2] } else { '' }
                Score   = $s.Score
                Why     = $s.Why
            })
        }
    }
}

# --- tier split -------------------------------------------------------------
$detected = @($rows | Where-Object {
    $_.Score -ge 4 -and ($IncludeEditors -or $_.Kind -ne 'editor')
} | Sort-Object Name -Unique)

$possible = @($rows | Where-Object {
    $_.Score -ge 2 -and $_.Score -lt 4 -and ($IncludeEditors -or $_.Kind -ne 'editor')
} | Sort-Object Name -Unique)

$rank = @{
    'npm' = 1
    'winget' = 2
    'pip / uv' = 3
    'scoop' = 4
    'cargo' = 5
    'bun' = 6
    'standalone installer' = 7
    'unknown' = 8
}

Write-Host ""
Write-Host ("Auto-detected coding agents ({0} detected, {1} possible)" -f @($detected).Count, @($possible).Count) -ForegroundColor Cyan
if (-not $IncludeEditors) {
    Write-Host "(GUI editors hidden - use -IncludeEditors)" -ForegroundColor DarkGray
}

foreach ($grp in $detected | Group-Object Method | Sort-Object { if ($rank.ContainsKey($_.Name)) { $rank[$_.Name] } else { 99 } }) {
    Write-Host ""
    Write-Host ("== Installed via {0} ({1}) ==" -f $grp.Name, $grp.Count) -ForegroundColor Yellow
    $cols = @(
        @{ n = 'Agent'; e = { $_.Name } },
        @{ n = 'Version'; e = { $_.Version } },
        @{ n = 'Source'; e = { $_.Source } }
    )
    if ($ShowReasons) { $cols += @{ n = 'Why'; e = { $_.Why } }; $cols += @{ n = 'Score'; e = { $_.Score } } }
    $grp.Group | Sort-Object Name | Format-Table $cols -AutoSize | Out-Host
}

if (@($possible).Count) {
    Write-Host ""
    Write-Host "== Possible (weak signal - review) ==" -ForegroundColor DarkYellow
    $possible | Sort-Object Name | Format-Table @(
        @{ n = 'Agent'; e = { $_.Name } },
        @{ n = 'Source'; e = { $_.Source } },
        @{ n = 'Why'; e = { $_.Why } },
        @{ n = 'Score'; e = { $_.Score } }
    ) -AutoSize | Out-Host
}
Write-Host ""

# --- HTML report ------------------------------------------------------------
if (-not $NoHtml) {
    function Enc([string]$s) { [System.Net.WebUtility]::HtmlEncode([string]$s) }
    $chanColors = @{
        'npm'                  = '#ff6b5e'
        'winget'               = '#5ad1ff'
        'pip / uv'             = '#ffcf5a'
        'scoop'                = '#c79bff'
        'cargo'                = '#ffa07a'
        'bun'                  = '#fbf0df'
        'standalone installer' = '#d4ff3f'
        'unknown'              = '#8a8a80'
    }

    $sb = [System.Text.StringBuilder]::new()
    $chN = 0
    $d = 0
    foreach ($grp in $detected | Group-Object Method | Sort-Object { if ($rank.ContainsKey($_.Name)) { $rank[$_.Name] } else { 99 } }) {
        $chN++
        $c = $chanColors[$grp.Name]
        if (-not $c) { $c = '#d4ff3f' }
        $chId = '{0:D2}' -f $chN
        [void]$sb.AppendLine("<section class=""channel"" style=""--c:$c;--d:$d"">")
        [void]$sb.AppendLine("<div class=""ch-head""><span class=""ch-id"">$chId</span><h2>$(Enc $grp.Name)</h2><span class=""ch-count"">$($grp.Count)</span></div>")
        [void]$sb.AppendLine('<ol class="units">')
        $i = 0
        foreach ($r in $grp.Group | Sort-Object Name) {
            $i++; $d++
            $idx = '{0:D2}' -f $i
            $ver = if ($r.Version) { " <span class=""ver"">$(Enc $r.Version)</span>" } else { '' }
            [void]$sb.AppendLine("<li class=""unit"" style=""--d:$d""><span class=""idx"">$idx</span><span class=""cmd"">$(Enc $r.Name)$ver</span><span class=""path"" title=""$(Enc $r.Source)"">$(Enc $r.Source)</span><span class=""dot""></span></li>")
        }
        [void]$sb.AppendLine('</ol></section>')
    }
    if (@($possible).Count) {
        $chN++
        $chId = '{0:D2}' -f $chN
        [void]$sb.AppendLine("<section class=""channel possible"" style=""--c:#8a8a80;--d:$d"">")
        [void]$sb.AppendLine("<div class=""ch-head""><span class=""ch-id"">$chId</span><h2>possible</h2><span class=""ch-count"">$(@($possible).Count)</span></div>")
        [void]$sb.AppendLine('<ol class="units">')
        $i = 0
        foreach ($r in $possible | Sort-Object Name) {
            $i++; $d++
            $idx = '{0:D2}' -f $i
            [void]$sb.AppendLine("<li class=""unit"" style=""--d:$d""><span class=""idx"">$idx</span><span class=""cmd"">$(Enc $r.Name)</span><span class=""path"" title=""$(Enc $r.Why)"">$(Enc $r.Why)</span><span class=""dot hollow""></span></li>")
        }
        [void]$sb.AppendLine('</ol></section>')
    }

    $generated = Get-Date -Format 'yyyy-MM-dd HH:mm'
    $dc = @($detected).Count
    $pc = @($possible).Count
    $cc = @($detected | Group-Object Method).Count
    $machine = $env:COMPUTERNAME

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
:root{--bg:#08080a;--panel:#0d0d11;--line:#1c1c23;--ink:#eceae0;--mut:#74746a;--accent:#d4ff3f}
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
.stat .lbl{font-size:10.5px;letter-spacing:.24em;text-transform:uppercase;color:var(--mut);margin-top:12px;display:block}
.channels{margin-top:54px;display:grid;gap:18px}
.channel{border:1px solid var(--line);background:var(--panel);position:relative;overflow:hidden;opacity:0;animation:rise .6s ease forwards;animation-delay:calc(var(--d,0)*42ms + .35s)}
.channel::before{content:"";position:absolute;left:0;top:0;bottom:0;width:3px;background:var(--c)}
.channel.possible{border-style:dashed}
.ch-head{display:flex;align-items:center;gap:18px;padding:19px 26px 16px;border-bottom:1px solid var(--line)}
.ch-id{font-family:'Syne',sans-serif;font-weight:800;font-size:30px;line-height:1;color:transparent;-webkit-text-stroke:1px var(--c)}
.ch-head h2{font-size:13.5px;letter-spacing:.28em;text-transform:uppercase;font-weight:500;color:var(--ink)}
.ch-count{margin-left:auto;font-size:12px;color:var(--c);border:1px solid var(--c);padding:3px 12px;letter-spacing:.12em;font-variant-numeric:tabular-nums}
.units{list-style:none;padding:7px 0}
.unit{display:grid;grid-template-columns:3rem minmax(7rem,16rem) 1fr auto;align-items:center;gap:20px;padding:12px 26px;position:relative;opacity:0;transform:translateY(10px);animation:rise .5s cubic-bezier(.2,.7,.15,1) forwards;animation-delay:calc(var(--d,0)*36ms + .4s)}
.unit::before{content:"";position:absolute;left:0;top:0;bottom:0;width:0;background:var(--c);opacity:.09;transition:width .28s cubic-bezier(.2,.7,.15,1)}
.unit:hover::before{width:100%}
.unit:hover .cmd{color:var(--c)}.unit:hover .path{color:var(--ink)}
.idx{color:var(--mut);font-size:12px;font-variant-numeric:tabular-nums}
.cmd{font-weight:700;font-size:14.5px;color:var(--ink);transition:color .2s}
.cmd .ver{font-weight:400;font-size:11px;color:var(--mut);margin-left:.5em}
.path{color:var(--mut);font-size:12px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;transition:color .2s}
.dot{width:8px;height:8px;border-radius:50%;background:var(--c);box-shadow:0 0 11px var(--c);justify-self:end}
.dot.hollow{background:transparent;border:1px solid var(--c);box-shadow:none}
footer{margin-top:48px;padding-top:18px;border-top:1px solid var(--line);display:flex;justify-content:space-between;flex-wrap:wrap;gap:10px;color:var(--mut);font-size:11.5px;letter-spacing:.06em}
footer .ac{color:var(--accent)}
@keyframes rise{to{opacity:1;transform:none}}
@keyframes clipUp{to{clip-path:inset(0 0 -12% 0)}}
@media(max-width:600px){.unit{grid-template-columns:2.2rem 1fr auto;gap:13px}.unit .path{display:none}}
@media(prefers-reduced-motion:reduce){*{animation:none!important}.eyebrow,.meta,.stat,.channel,.unit{opacity:1!important;transform:none!important}h1{clip-path:none!important}}
</style></head>
<body>
<div class="grain"></div>
<div class="wrap">
<div class="eyebrow">// agent fleet manifest</div>
<h1>CODING<br><em>AGENTS</em></h1>
<p class="meta">scan complete &middot; <b>$dc</b> agents across <b>$cc</b> <span class="ac">channels</span> &middot; host <b>$(Enc $machine)</b> &middot; $generated</p>
<div class="stats">
<div class="stat lead" style="--i:0"><span class="num" data-count="$dc">$dc</span><span class="lbl">detected</span></div>
<div class="stat" style="--i:1"><span class="num" data-count="$cc">$cc</span><span class="lbl">install channels</span></div>
<div class="stat" style="--i:2"><span class="num" data-count="$pc">$pc</span><span class="lbl">possible / review</span></div>
</div>
<div class="channels">
$($sb.ToString())</div>
<footer><span>generated by <span class="ac">list-coding-agents.ps1</span></span><span>heuristic detection &middot; tiered confidence</span></footer>
</div>
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
</script>
</body></html>
"@
    $htmlPath = Join-Path $PSScriptRoot 'coding-agents.html'
    $html | Out-File -LiteralPath $htmlPath -Encoding utf8
    Write-Host "HTML report: $htmlPath" -ForegroundColor Green
    Invoke-Item -LiteralPath $htmlPath
}
