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
      * exact known CLI names + install-path signatures (bare agent exes
        often ship with zero metadata, so codex/grok/kimi/jcode rely on this)

    Pure MCP utility servers are excluded: @modelcontextprotocol/sdk alone is
    not treated as an agent signal.

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
    Two escape hatches, one name per line, "#" for comments:
      agents-extra.txt    force a name IN  (undetectable agents)
      agents-exclude.txt  force a name OUT (false positives; wins over -extra)

.PARAMETER IncludeEditors
    Also include GUI AI editors (Cursor/Windsurf/Kiro/Trae style launchers)
    and desktop apps that winget knows about (Claude, ChatGPT/Codex, ...).
.PARAMETER ShowReasons
    Print the signals that triggered each detection.
.PARAMETER NoHtml
    Skip writing/opening the HTML report.
.PARAMETER NoOpen
    Write the HTML report but don't launch the browser (handy from scripts).
.PARAMETER SkipWinget
    Skip the winget package scan (faster when you already know it adds nothing).
    This makes the run a partial scan: winget-only agents are carried over from
    the last full scan rather than reported as removed, and no trend point is
    recorded (its totals would understate the fleet).
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
    [switch]$NoOpen,
    [switch]$SkipWinget,
    [switch]$CheckUpdates,
    [switch]$UpdateAll,
    [switch]$Json
)
if ($UpdateAll) { $CheckUpdates = $true }
$scanClock = [System.Diagnostics.Stopwatch]::StartNew()

# ---------------------------------------------------------------------------
# Lexicons (linguistic signals, not a product catalogue). These rarely change:
# they are model/vendor words, so newly-released agents are still detected via
# their metadata even if their brand isn't listed here.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Lexicons - linguistic + known CLI names (not a closed product catalogue).
# Bare agent installers often embed zero metadata, so exact command names
# matter; unknown agents still surface via npm/winget/path/PE signals.
# ---------------------------------------------------------------------------

# Exact command basenames that are coding-agent CLIs when found on PATH.
# Only names distinctive enough that a match is near-certain belong here - a hit
# scores +6, which auto-detects on the name alone.
$KnownCli = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@(
        'claude', 'codex', 'gemini', 'grok', 'kimi', 'opencode', 'openclaw',
        'qwen', 'jcode', 'mimo', 'aider', 'cody', 'crush', 'droid',
        'goose', 'cline', 'kilocode', 'kilo', 'factory', 'blackbox',
        'auggie', 'cursor-agent', 'windsurf', 'kiro',
        'roo-code', 'continue-cli', 'copilot', 'gh-copilot',
        'openhands', 'codebuddy', 'iflow', 'mux', 'zencoder', 'hermes', 'hermes-agent',
        'letta', 'trae', 'trae-cn'
    ),
    [StringComparer]::OrdinalIgnoreCase
)

# Agent CLIs whose names are also common non-agent tools or ordinary words:
#   sg  = ast-grep      src = Sourcegraph code search
#   amp / pi / vibe / continue / roo = too generic to stand alone
# These only nudge into the review tier; corroborating evidence (install path,
# AI SDK dependency, vendor, agent phrasing) is what promotes them to DETECTED.
$AmbiguousCli = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@('sg', 'src', 'amp', 'pi', 'vibe', 'continue', 'roo'),
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
    '(?i)\\Programs\\(trae|Trae CN)\\',
    '(?i)\\gemini-cli\\',
    '(?i)\\opencode',
    '(?i)\\anthropic\\',
    '(?i)\\Claude\\',
    '(?i)\\\.openhands\\',
    '(?i)\\\.hermes\\'
)

# Note: bare "google" is intentionally omitted (matches Android platform-tools, etc.).
$AiVendors    = 'anthropic|openai|moonshot|mistral|cohere|sourcegraph|augment(code)?|codeium|anysphere|factory|\bsst\b|kilocode|perplexity|deepseek|\bxai\b|bytedance|tencent|all[- ]?hands|nous(\s?research)?|letta'
# Real model SDKs - deliberately NOT modelcontextprotocol (shared by non-agents).
$AiSdkDep     = '(?i)@anthropic-ai/|(^|/)openai(@|/|$)|@google/genai|generative-ai|langchain|ollama|@ai-sdk/|^ai$|mistralai|@google/generative-ai'
$BrandWords   = 'claude|gemini|copilot|codex|aider|cody|goose|opencode|openclaw|cline|roo[- ]?code|droid|crush|qwen|grok|kimi|antigravity|blackbox|windsurf|cursor|kiro|mimo|jcode|vibe|\bgpt\b|\bllm\b|kilocode|factory|openhands|codebuddy|iflow|mux|trae|zencoder|hermes|letta'
# A bare brand basename, optionally with the usual agent suffix, so that
# "kimi-cli" and "claude-code" score like plain "kimi" and "claude" do.
$BrandCmdRx   = "^(?:$BrandWords)(?:[-_]?(?:cli|code|agent))?$"
$AgentPhrase  = 'coding[- ]?agent|code[- ]?agent|agentic|ai[- ]?coding|ai pair|pair program|autonomous (coding|software|dev)|ai software engineer|terminal.*agent|ai[- ]?powered coding|coding assistant'
# Hard exclude: package managers, pure MCP utilities, scaffolding, etc.
$HardExclude  = '(?i)install .*skill|skill for|\bdeploy(ment)?\b|package manager|boilerplate|scaffold|video extension|image extension|redistributable|driver|\bmcp[- ]?server\b|^mcp\b|\bmodel context protocol\b'

# --- scoring ----------------------------------------------------------------
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
    # Ambiguous names deliberately do NOT get the bypass: an "amp-mcp-server" or
    # "sg-updater" should still be filtered out by the guards below.
    $isKnown = $KnownCli.Contains($name)
    $isAmbig = (-not $isKnown) -and $AmbiguousCli.Contains($name)
    if (-not $isKnown) {
        if ($name -match '(?i)(^|-)mcp($|-)|-mcp-server$|^mcp-') {
            return [pscustomobject]@{ Score = -99; Why = 'excluded (mcp utility)' }
        }
        # "CLI to install <x> skill ..." is a skill installer, never an agent -
        # this one is unconditional (loose phrases like "ai coding" would
        # otherwise keep it alive via the AgentPhrase guard below).
        if ($tLower -match '(?i)install .*skill|skill for') {
            return [pscustomobject]@{ Score = -99; Why = 'excluded (skill installer)' }
        }
        if ($tLower -match $HardExclude -and $tLower -notmatch $AgentPhrase) {
            return [pscustomobject]@{ Score = -99; Why = 'excluded (non-agent phrase)' }
        }
        if ($name -match '(?i)(launcher|host|helper|shim|wrapper|updater|unins|runner)') {
            return [pscustomobject]@{ Score = -99; Why = 'excluded (helper binary)' }
        }
    }

    if ($isKnown) {
        $score += 6
        $why.Add('known CLI name')
    } elseif ($isAmbig) {
        # Enough to land in the review tier, never enough to auto-detect alone:
        # ast-grep's "sg" should not be announced as a coding agent on a machine
        # that has never installed one.
        $score += 2
        $why.Add('ambiguous CLI name (needs corroboration)')
    }

    # Path signatures only boost the primary agent CLI, not sibling tools.
    if ($Path -and ($isKnown -or $isAmbig -or $name -match $BrandCmdRx)) {
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
        # whole words only: "codex" is not "code" plus an x, so the Codex app's
        # helper exes don't collect this on their name alone
        if ($tLower -match '\b(cli|code|coding|terminal|assistant)\b') {
            $score += 2
            $why.Add('brand + cli/code')
        }
        # Basename is the brand word itself, with or without the usual agent
        # suffix - "kimi", "kimi-cli" and "claude-code" all qualify.
        if ($name -match $BrandCmdRx) {
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

# --- enrichment helpers ------------------------------------------------------
function Write-Utf8File([string]$Path, [string]$Text) {
    # Out-File -Encoding utf8 puts a byte order mark in front on Windows
    # PowerShell 5.1, which trips up jq / node / python readers of the json.
    # Plain UTF-8, same bytes on both editions.
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

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

function Get-AgentIntel([string[]]$Names, [string[]]$ExtraDirs = @()) {
    # One walk over the agent's config dirs: newest write (last used), count of
    # session-ish files touched in the last 30 days, MCP servers configured,
    # and a credentials hint (probably logged in). All heuristic, all generic.
    # Several names can be tried (a winget row has no command, only a display
    # name and a package id), plus known-good dirs the caller worked out.
    $res = [pscustomobject]@{ LastUsed = $null; Sessions30d = 0; McpCount = 0; Auth = $false }
    $dirs = @()
    foreach ($n in $Names) { foreach ($d in (Get-ConfigDirs $n)) { if ($dirs -notcontains $d) { $dirs += $d } } }
    foreach ($d in $ExtraDirs) { if ($d -and (Test-Path -LiteralPath $d) -and ($dirs -notcontains $d)) { $dirs += $d } }
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

function Get-ExeVersionProbe([string]$Path, [int]$TimeoutSec = 8, [string[]]$Arguments = @('--version')) {
    # Bare exes carry no metadata, so ask them directly, with a timeout so an
    # interactive/hung CLI can't stall the whole scan. This used to go through
    # Start-Job, which costs ~2s just to spin up the job host and, on a
    # timeout, left the hung CLI running in the background. A plain process
    # is quicker to start and gets its whole tree killed when time is up.
    $p = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Path
        $psi.Arguments = (@($Arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' ')
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true     # closed right away: a CLI that wants to chat gets EOF, not a wait
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true     # some CLIs print their version there
        # most CLIs skip update checks, prompts and colours when they see these
        $psi.EnvironmentVariables['CI'] = '1'
        $psi.EnvironmentVariables['NO_COLOR'] = '1'
        $psi.EnvironmentVariables['TERM'] = 'dumb'
        $psi.EnvironmentVariables['NO_UPDATE_NOTIFIER'] = '1'
        $p = [System.Diagnostics.Process]::Start($psi)
        try { $p.StandardInput.Close() } catch {}
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            # kill the whole tree: node/bun wrappers spawn the real CLI as a child
            try { & taskkill /PID $p.Id /T /F 2>$null | Out-Null } catch {}
            try { if (-not $p.HasExited) { $p.Kill() } } catch {}
            return $null
        }
        # a leftover child could keep the pipes open, so don't wait forever for EOF
        if ([System.Threading.Tasks.Task]::WaitAll(@($outTask, $errTask), 2000)) {
            $out = $outTask.Result + ' ' + $errTask.Result
            if ($out -match '(\d+\.\d+(\.\d+)*)') { return $Matches[1] }
        }
    } catch {} finally {
        if ($p) { $p.Dispose() }
    }
    $null
}

# --- npm: command -> rich metadata -----------------------------------------
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
            Dir     = $dir
            Text    = (@($pkgName, $pkgDesc) + $kw) -join ' '
            Deps    = @($deps)
        }
        foreach ($c in $cmds) {
            if ($c) { $map[$c.ToLowerInvariant()] = $meta }
        }
    }
    $map
}

function Select-NpmPrimaryRow([System.Collections.Generic.List[object]]$Rows) {
    # One row per npm package: vercel ships both "vercel" and "vc", and that is
    # one tool, not two. Keep the bin that is named like the package.
    $byPkg = @{}
    foreach ($r in $Rows) {
        if ($r.Method -eq 'npm' -and $r.Package) {
            if (-not $byPkg.ContainsKey($r.Package)) { $byPkg[$r.Package] = @() }
            $byPkg[$r.Package] += $r
        }
    }
    $drop = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($pkg in @($byPkg.Keys)) {
        $group = @($byPkg[$pkg])
        if ($group.Count -lt 2) { continue }
        $base = ($pkg -split '/')[-1]
        $keep = $group | Where-Object { $_.Command -eq $base } | Select-Object -First 1
        if (-not $keep) { $keep = $group[0] }
        foreach ($r in $group) { if ($r.Command -ne $keep.Command) { [void]$drop.Add($r.Command) } }
    }
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $Rows) { if (-not ($r.Method -eq 'npm' -and $drop.Contains($r.Command))) { $out.Add($r) } }
    ,$out
}

# --- candidate commands: PATH (outside Windows) -----------------------------
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
                $seen[$name] = [pscustomobject]@{ Path = $f.FullName; Shadows = @() }
            } elseif ($seen[$name].Path -ne $f.FullName -and ((Split-Path $seen[$name].Path) -ne (Split-Path $f.FullName))) {
                # same command name in a later PATH dir - it is shadowed
                $seen[$name].Shadows += $f.FullName
            }
        }
    }

    $seen.GetEnumerator() | ForEach-Object {
        [pscustomobject]@{ Command = $_.Key; Path = $_.Value.Path; Shadows = @($_.Value.Shadows) }
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
    if ($Path -match '(?i)\\Programs\\(cursor|windsurf|kiro|trae|trae-cn)\\' -or
        $Name -match '^(cursor|windsurf|kiro|trae|trae-cn)$') { return 'editor' }
    return 'cli'
}

function Format-ExeVersion([string]$V) {
    # Windows version-info is always four numbers, so a 2.1.296 build shows up
    # as 2.1.296.0. Drop a trailing .0 when the first three parts are there;
    # a real four-part version (155.0.4283.45) stays as it is.
    if ($V -match '^(\d+\.\d+\.\d+)\.0$') { return $Matches[1] }
    $V
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

function ConvertFrom-WingetRow([string]$Line) {
    # One line of `winget list` -> name / id / version / publisher / product /
    # kind, or $null for the header, separators and progress-bar noise.
    # Ids come in three shapes:
    #   Anthropic.ClaudeCode                   proper id: Publisher.Product
    #   MSIX\OpenAI.Codex_1.2.3.0_x64__hash    packaged store app (always a GUI)
    #   ARP\Machine\X86\Microsoft Copilot      Add/Remove Programs fallback, no publisher
    if (-not $Line -or $Line -notmatch '[A-Za-z]') { return $null }
    # winget table: Name  Id  Version  Available  Source  (2+ spaces between)
    $parts = @($Line -split '\s{2,}' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($parts.Count -lt 2) { return $null }
    $name = $parts[0]; $id = $parts[1]
    if ($name -eq 'Name' -or $id -eq 'Id') { return $null }
    if ($name -match '^(The following|No installed|-{2,})') { return $null }
    $publisher = ''; $product = $id
    if ($id -match '^MSIX\\([^_\\]+)_') {
        $full = $Matches[1]      # OpenAI.Codex / Microsoft.NET.Native.Framework.2.1 / aimgr
        if ($full -match '^([^.]+)\.(.+)$') { $publisher = $Matches[1]; $product = $Matches[2] } else { $product = $full }
    } elseif ($id -match '^ARP\\') {
        $product = ($id -split '\\')[-1]
    } elseif ($id -match '^([^.\\]+)\.(.+)$') {
        $publisher = $Matches[1]; $product = $Matches[2]
    }
    $ver = ''
    if ($parts.Count -ge 3 -and $parts[2] -match '^(\d+(\.\d+)+)') { $ver = $Matches[1] }
    elseif ($id -match '_(\d+(\.\d+)+)_') { $ver = $Matches[1] }
    # GUI or CLI? Editors by name, packaged store apps are always GUIs, and a
    # bare brand name with no cli/code/agent in it (Claude, Copilot, ChatGPT)
    # is the desktop app, not the agent CLI.
    $kind = 'cli'
    if ((Get-Kind -Path $id -Name $product) -eq 'editor' -or (Get-Kind -Path $id -Name $name) -eq 'editor') { $kind = 'editor' }
    elseif ($id -match '^MSIX\\') { $kind = 'app' }
    elseif ($name -notmatch '(?i)\b(cli|code|terminal|agent)\b' -and $product -notmatch '(?i)(cli|code|terminal|agent)$') { $kind = 'app' }
    [pscustomobject]@{ Name = $name; Id = $id; Version = $ver; Publisher = $publisher; Product = $product; Kind = $kind }
}

$npmMeta = Get-NpmMeta

function Get-NameListFile([string]$FileName) {
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $p = Join-Path $PSScriptRoot $FileName
    if (Test-Path -LiteralPath $p) {
        Get-Content -LiteralPath $p -ErrorAction SilentlyContinue | ForEach-Object {
            $line = $_.Trim()
            if ($line -and $line -notmatch '^\s*#') { [void]$set.Add($line.ToLowerInvariant()) }
        }
    }
    # leading comma stops PowerShell unrolling the HashSet into loose strings -
    # without it an empty set comes back as $null and .Contains() blows up
    ,$set
}

$extra   = Get-NameListFile 'agents-extra.txt'     # force IN  (undetectable names)
$exclude = Get-NameListFile 'agents-exclude.txt'  # force OUT (false positives)

# --- evaluate every PATH candidate -----------------------------------------
$rows = [System.Collections.Generic.List[object]]::new()
$haveNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

foreach ($c in Get-PathCandidates) {
    $name = $c.Command; $path = $c.Path
    # Skip hidden/backup/old launcher basenames (e.g. .jcode-launcher-old-...).
    if ($name.StartsWith('.')) { continue }

    $text = $name; $deps = @(); $publisher = ''
    $version = ''; $package = ''; $pkgDir = ''
    $method = Get-Method $path
    $kind = Get-Kind -Path $path -Name $name

    if ($npmMeta.ContainsKey($name)) {
        $m = $npmMeta[$name]
        $text = $m.Text; $deps = $m.Deps; $method = 'npm'
        if ($m.Version) { $version = $m.Version }
        $package = $m.Package; $pkgDir = $m.Dir
    }

    $pe = Get-PeText -Path $path
    if ($pe.Text) { $text = (@($text, $pe.Text) -join ' ').Trim() }
    if ($pe.Publisher) { $publisher = $pe.Publisher }
    if (-not $version -and $pe.Version -match '(\d+(\.\d+)+)') { $version = Format-ExeVersion $Matches[1] }

    $s = Get-AgentScore -Text $text -Deps $deps -Publisher $publisher -Name $name -Path $path
    if ($extra.Contains($name) -and $s.Score -lt 4) { $s = [pscustomobject]@{ Score = 5; Why = 'agents-extra.txt override' } }
    # exclude wins over extra - it is the user's last word on a false positive
    if ($exclude.Contains($name)) { $s = [pscustomobject]@{ Score = -99; Why = 'agents-exclude.txt override' } }

    if ($s.Score -lt 2) { continue }

    [void]$haveNames.Add($name)
    $rows.Add([pscustomobject]@{
        Name=$name; Command=$name; Source=$path; Method=$method; Kind=$kind; Score=$s.Score; Why=$s.Why
        Version=$version; Package=$package; PkgDir=$pkgDir; Product=''
        SizeMB=$null; LastUsed=$null; Latest=''; UpdateCmd=''; UpdateArgs=@()
        Sessions30d=0; McpCount=0; Auth=$false; Stale=$false; UninstallCmd=''; Shadows=@($c.Shadows)
    })
}

$rows = Select-NpmPrimaryRow $rows

# --- evaluate winget packages (catches agents that aren't on PATH, e.g. Codex)
# $wingetScanned drives the partial-scan handling further down: a run that never
# looked at winget must not claim winget-only agents disappeared.
$wingetScanned = $false
if (-not $SkipWinget -and (Get-Command winget -ErrorAction SilentlyContinue)) {
    $wingetScanned = $true
    # --accept-source-agreements: a first-ever winget run otherwise stops to ask
    # about the msstore terms, and --disable-interactivity turns that into a fail
    foreach ($line in (winget list --disable-interactivity --accept-source-agreements 2>$null)) {
        $w = ConvertFrom-WingetRow $line
        if (-not $w) { continue }
        # already found on PATH? check the product half of the id and every word
        # of the display name, so "Claude Code" / Anthropic.ClaudeCode folds into
        # the claude that is already listed instead of showing up twice
        $keys = @($w.Product.ToLowerInvariant()) + @($w.Name.ToLowerInvariant() -split '\s+')
        $dup = $false
        foreach ($k in $keys) { if ($haveNames.Contains($k)) { $dup = $true; break } }
        if ($dup) { continue }
        # agents-exclude.txt wins: match the product, any word, or the whole name
        $skip = $false
        foreach ($k in ($keys + @($w.Name.ToLowerInvariant()))) { if ($exclude.Contains($k)) { $skip = $true; break } }
        if ($skip) { continue }
        # score on the product half of the id ("Codex" out of OpenAI.Codex), not
        # the display name: Microsoft's "Copilot" app is not the copilot CLI.
        # ARP rows with a GUID for a product have nothing better than the name.
        $scoreName = if ($w.Product -match '^\{') { $w.Name } else { $w.Product }
        $s = Get-AgentScore -Text ("$($w.Name) $($w.Id)") -Deps @() -Publisher $w.Publisher -Name $scoreName -Path $w.Id
        if ($s.Score -ge 2) {
            [void]$haveNames.Add($w.Product.ToLowerInvariant())
            $rows.Add([pscustomobject]@{
                Name=$w.Name; Command='(winget)'; Source=$w.Id; Method='winget'; Kind=$w.Kind; Score=$s.Score; Why=$s.Why
                Version=$w.Version; Package=''; PkgDir=''; Product=$w.Product
                SizeMB=$null; LastUsed=$null; Latest=''; UpdateCmd=''; UpdateArgs=@()
                Sessions30d=0; McpCount=0; Auth=$false; Stale=$false; UninstallCmd=''; Shadows=@()
            })
        }
    }
}

# --- split into tiers -------------------------------------------------------
$detected = @($rows | Where-Object { $_.Score -ge 4 -and ($IncludeEditors -or $_.Kind -eq 'cli') })
$possible = @($rows | Where-Object { $_.Score -ge 2 -and $_.Score -lt 4 -and ($IncludeEditors -or $_.Kind -eq 'cli') })
# Everything that scored, whatever -IncludeEditors says. The new/gone diff and
# the saved baseline use this, so toggling the switch between runs doesn't
# make every editor look freshly installed (or freshly removed).
$allDetected = @($rows | Where-Object { $_.Score -ge 4 })

# --- previous scan: name diff, trend history, exe-probe cache ----------------
$histFile  = Join-Path $PSScriptRoot 'last-scan.json'
$prevNames = @(); $prevDate = ''; $histArr = @(); $probeCache = @{}; $sizeCache = @{}
$prevWinget = @(); $prevHasWinget = $false
if (Test-Path -LiteralPath $histFile) {
    try {
        $prev = Get-Content -LiteralPath $histFile -Raw | ConvertFrom-Json
        if ($prev.agents)  { $prevNames = @($prev.agents) }
        if ($prev.date)    { $prevDate  = "$($prev.date)" }
        if ($prev.history) { $histArr   = @($prev.history) }
        if ($prev.probes)  { foreach ($pp in $prev.probes.PSObject.Properties) { $probeCache[$pp.Name] = $pp.Value } }
        if ($prev.PSObject.Properties.Name -contains 'sizes' -and $prev.sizes) {
            foreach ($sp in $prev.sizes.PSObject.Properties) { $sizeCache[$sp.Name] = [double]$sp.Value }
        }
        # Agents only the winget scan can see. Tracked separately so a scan that
        # skipped winget knows which previous names it simply didn't look for.
        if ($prev.PSObject.Properties.Name -contains 'wingetOnly') {
            $prevHasWinget = $true
            if ($prev.wingetOnly) { $prevWinget = @($prev.wingetOnly) }
        }
    } catch {}
}
$curNames = @($allDetected | ForEach-Object { $_.Name })
# Without a winget scan, previous winget-only agents are "not checked", not
# "gone" - reporting them as removed is a lie about state we never observed.
$unscanned = if ($wingetScanned) { @() } else { $prevWinget }
$newNames = @(); $goneNames = @()
if ($prevNames.Count) {
    $newNames  = @($curNames  | Where-Object { $prevNames -notcontains $_ })
    $goneNames = @($prevNames | Where-Object { $curNames -notcontains $_ -and $unscanned -notcontains $_ })
}

# --- enrich the agents that made a tier (sizes, usage intel, version probes) -
Write-Host ""
Write-Host "enriching: sizes + usage intel + mcp configs + versions..." -ForegroundColor DarkGray
foreach ($r in ($detected + $possible)) {
    if ($r.Method -eq 'npm' -and $r.PkgDir) {
        # a big npm package (opencode is 500+ MB of files) takes a second or
        # two to walk cold, and its size can't change without its version
        # changing, so remember it per dir + version in last-scan.json
        $sizeKey = "$($r.PkgDir)|$($r.Version)"
        if ($r.Version -and $sizeCache.ContainsKey($sizeKey)) { $r.SizeMB = $sizeCache[$sizeKey] }
        else {
            $r.SizeMB = Get-SizeMB $r.PkgDir
            if ($r.Version -and $null -ne $r.SizeMB) { $sizeCache[$sizeKey] = $r.SizeMB }
        }
    }
    elseif ($r.Source -match '(?i)\.exe$')  { $r.SizeMB = Get-SizeMB $r.Source }
    # winget rows have no command to go on: try the product half of the id and
    # each word of the display name ("Codex", "ChatGPT" -> ~/.codex), and for a
    # store app its package data folder, which is where a GUI keeps its state
    $intelNames = @($r.Command); $intelDirs = @()
    if ($r.Command -eq '(winget)') {
        $intelNames = @($r.Product) + @($r.Name -split '\s+')
        if ($env:LOCALAPPDATA -and $r.Source -match '^MSIX\\([^_\\]+)_.*__([^_\\]+)$') {
            $intelDirs += (Join-Path $env:LOCALAPPDATA ("Packages\" + $Matches[1] + '_' + $Matches[2]))
        }
    }
    $intel = Get-AgentIntel -Names $intelNames -ExtraDirs $intelDirs
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
                            $r.UpdateArgs = @('npm', 'i', '-g', "$($r.Package)@latest")
                        }
                    }
                }
            } catch {}
        }
    }
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "checking winget for updates..." -ForegroundColor DarkGray
        $wg = @{}
        foreach ($line in (winget upgrade --disable-interactivity --accept-source-agreements 2>$null)) {
            if ($line -notmatch '[A-Za-z]') { continue }
            $parts = $line -split '\s{2,}'
            if ($parts.Count -ge 4 -and $parts[1].Trim() -match '\.' -and $parts[1].Trim() -ne 'Id') {
                $wg[$parts[1].Trim()] = $parts[3].Trim()
            }
        }
        foreach ($r in ($detected | Where-Object { $_.Method -eq 'winget' -and -not $_.Latest })) {
            foreach ($k in $wg.Keys) {
                if ($r.Source -match [regex]::Escape($k) -or $k -match [regex]::Escape($r.Name)) {
                    $r.Latest = $wg[$k]; $r.UpdateCmd = "winget upgrade --id `"$k`""
                    $r.UpdateArgs = @('winget', 'upgrade', '--id', $k); break
                }
            }
        }
    }
}
$updates = @($detected | Where-Object { $_.Latest })

# --- fleet health: dead weight, conflicts, totals, rank ----------------------
$staleDays = 60
foreach ($r in ($detected + $possible)) {
    # untouched for 60+ days = dead weight. No usage info at all means a PATH
    # cli that never made a config folder (so probably never ran), but for a
    # winget row it just means we found nowhere to look, so don't accuse it.
    $r.Stale = $false
    if ($r.LastUsed) { $r.Stale = (((Get-Date) - $r.LastUsed).TotalDays -gt $staleDays) }
    elseif ($r.Command -ne '(winget)') { $r.Stale = $true }
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
# A run without a winget scan is a PARTIAL scan. Writing its short agent list as
# the new baseline would make the next full scan report every winget-only agent
# as "+ new" (and this run report them as "- gone"). So carry the previous
# winget-only names forward and skip the trend point, whose count/size would be
# understated and show up as a phantom dip in the sparkline.
# Rows found by the winget scan carry Command='(winget)' - that is narrower than
# Method='winget', which also covers WindowsApps shims the PATH scan finds fine.
$wingetOnly   = @($allDetected | Where-Object { $_.Command -eq '(winget)' } | ForEach-Object { $_.Name })
$persistNames = $curNames
$writeHist    = $true

if (-not $wingetScanned) {
    if ($prevNames.Count -and -not $prevHasWinget) {
        # Pre-upgrade state file: no way to tell which previous names were
        # winget-only, so leave the baseline alone rather than corrupt it.
        # One full scan re-establishes it.
        $writeHist = $false
    } else {
        $wingetOnly   = $prevWinget
        $persistNames = @(@($curNames) + @($prevWinget) | Select-Object -Unique)
    }
} else {
    # the trend counts CLIs only, whatever -IncludeEditors says, so the
    # sparkline doesn't dip or jump when the switch is toggled between scans
    $trendRows = @($allDetected | Where-Object { $_.Kind -eq 'cli' })
    $trendMB = 0.0; foreach ($r in $trendRows) { if ($r.SizeMB) { $trendMB += $r.SizeMB } }
    $histEntry = [pscustomobject]@{ d = (Get-Date -Format 'yyyy-MM-dd'); c = $trendRows.Count; mb = [math]::Round($trendMB, 1) }
    if ($histArr.Count -and "$($histArr[$histArr.Count-1].d)" -eq $histEntry.d) { $histArr[$histArr.Count-1] = $histEntry }
    else { $histArr = @($histArr) + @($histEntry) }
    if ($histArr.Count -gt 60) { $histArr = @($histArr[($histArr.Count-60)..($histArr.Count-1)]) }
}

if ($writeHist) {
    try {
        $stateJson = [pscustomobject]@{
            date       = (Get-Date -Format 'yyyy-MM-dd HH:mm')
            agents     = $persistNames
            wingetOnly = $wingetOnly
            history    = $histArr
            probes     = $probeCache
            sizes      = $sizeCache
        } | ConvertTo-Json -Depth 5
        Write-Utf8File $histFile $stateJson
    } catch {}
}

# --- terminal report ---------------------------------------------------------
$rank = @{ 'npm'=1; 'winget'=2; 'pip / uv'=3; 'scoop'=4; 'cargo'=5; 'bun'=6; 'standalone installer'=7; 'unknown'=8 }

Write-Host ""
Write-Host "Auto-detected coding agents ($($detected.Count) detected, $($possible.Count) possible, $(Format-Size $totMB) on disk)" -ForegroundColor Cyan
$reclaimLabel = Format-Size $reclaimMB; if (-not $reclaimLabel) { $reclaimLabel = 'none' }
Write-Host ("fleet rank: {0} (lv {1}) | {2}/{1} used this month | dead weight: {3}" -f $rankName, $detected.Count, $active30, $reclaimLabel) -ForegroundColor Magenta
$hiddenGui = @($rows | Where-Object { $_.Score -ge 2 -and $_.Kind -ne 'cli' }).Count
if (-not $IncludeEditors -and $hiddenGui) {
    $guiWord = if ($hiddenGui -eq 1) { 'GUI editor/app' } else { 'GUI editors/apps' }
    Write-Host "($hiddenGui $guiWord hidden - use -IncludeEditors)" -ForegroundColor DarkGray
}
if (-not $wingetScanned) {
    $why = if ($SkipWinget) { '-SkipWinget' } else { 'winget not found' }
    $carried = if ($writeHist) { "$($prevWinget.Count) carried over from last full scan" } else { 'baseline left untouched' }
    Write-Host ("(partial scan: $why - winget packages not checked, $carried)") -ForegroundColor DarkGray
}
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
    if ($IncludeEditors) { $cols += @{n='Kind';e={$_.Kind}} }
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
$scanSecs = [math]::Round($scanClock.Elapsed.TotalSeconds, 1)
Write-Host "scan took ${scanSecs}s" -ForegroundColor DarkGray

if ($UpdateAll -and $updates.Count) {
    Write-Host ""
    $ans = Read-Host ("-UpdateAll: run all {0} update command(s) now? (y/n)" -f $updates.Count)
    if ($ans -match '^(y|yes)$') {
        foreach ($r in $updates | Sort-Object Name) {
            Write-Host ""
            Write-Host (">> {0}" -f $r.UpdateCmd) -ForegroundColor Cyan
            # run the exe + args we built ourselves instead of Invoke-Expression on
            # the display string, so an odd package name can't smuggle extra
            # PowerShell into the command
            $exe = $r.UpdateArgs[0]; $rest = @($r.UpdateArgs | Select-Object -Skip 1)
            $LASTEXITCODE = 0
            try {
                & $exe @rest
                if ($LASTEXITCODE) { Write-Host ("   failed: exit code {0}" -f $LASTEXITCODE) -ForegroundColor Red }
            } catch { Write-Host ("   failed: {0}" -f $_.Exception.Message) -ForegroundColor Red }
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
    # -InputObject keeps a single agent as a one-element array; piping it in
    # would unwrap it and hand scripts a bare object instead of a list
    Write-Utf8File $jsonPath (ConvertTo-Json -InputObject @($export) -Depth 4)
    Write-Host "JSON export: $jsonPath" -ForegroundColor Green
}

# --- HTML report ------------------------------------------------------------
if (-not $NoHtml) {
    function Enc($s) { [System.Net.WebUtility]::HtmlEncode([string]$s) }
    $chanColors = @{ 'npm'='#ff6b5e'; 'winget'='#5ad1ff'; 'pip / uv'='#ffcf5a'; 'scoop'='#c79bff'; 'cargo'='#ffa07a'; 'bun'='#fbf0df'; 'standalone installer'='#d4ff3f'; 'unknown'='#8a8a80' }

    function New-UnitChips($r, [bool]$IsNew) {
        $chips = ''
        if ($IsNew)       { $chips += '<span class="chip new">NEW</span>' }
        if ($r.Kind -ne 'cli') { $chips += "<span class=""chip"" title=""gui, not a cli"">$(Enc $r.Kind)</span>" }
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
<footer><span>generated by <span class="ac">list-coding-agents.ps1</span></span><span>heuristic detection &middot; usage intel &middot; tiered confidence &middot; scanned in ${scanSecs}s</span></footer>
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
    var fs;
    try {
      fs = Promise.all([
        document.fonts.load('800 104px Syne'),
        document.fonts.load('800 44px Syne'),
        document.fonts.load('800 30px Syne'),
        document.fonts.load('700 21px "JetBrains Mono"'),
        document.fonts.load('400 19px "JetBrains Mono"')
      ]);
    } catch(err){ fs = Promise.resolve(); }
    // a font load can hang forever (offline / file://) - never leave the
    // button dead, fall back to system fonts after 2.5s
    var timeout = new Promise(function(_, rej){ setTimeout(function(){ rej(new Error('font timeout')); }, 2500); });
    Promise.race([fs, timeout]).then(draw, draw);
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
    // Stats flow by content width rather than on a fixed 205px pitch. The old
    // pitch was sized for short numbers, so a wide ON DISK value ("2.5 GB" is
    // 227px) ran straight under the rank box's left border, while "12" and "3"
    // left ~300px of dead space behind them.
    var stats = [
      [(D.dc || 0) + '', 'DETECTED'],
      [(D.cc || 0) + '', 'CHANNELS'],
      [(D.disk || '0 MB') + '', 'ON DISK']
    ];
    var STAT_GAP = 48, sx = 64, statsEnd = 64;
    for (var s = 0; s < stats.length; s++){
      x.font = '800 44px Syne';
      var vw = x.measureText(stats[s][0]).width;
      x.font = '400 15px "JetBrains Mono"';
      var lw = x.measureText(stats[s][1]).width;
      x.fillStyle = '#eceae0'; x.font = '800 44px Syne';
      x.fillText(stats[s][0], sx, 266);
      x.fillStyle = '#74746a'; x.font = '400 15px "JetBrains Mono"';
      x.fillText(stats[s][1], sx, 292);
      var tileW = Math.max(vw, lw);
      statsEnd = sx + tileW;
      sx += tileW + STAT_GAP;
    }
    // Fleet-rank pill. The box now hugs its text: shrink the type until it
    // clears the stats with even padding on both sides, then centre it in the
    // box horizontally AND vertically (a fixed baseline left smaller type
    // sitting low). The old fixed-width box gave "CERTIFIED HOARDER" exactly
    // 0px of left padding, so it read as clipping through the border.
    var rank = (D.rank || '').toString();
    var PAD = 22, GAP = 28, boxR = W - 64, boxY = 216, boxH = 62;
    if (rank && boxR - (statsEnd + GAP) >= 140){
      var fs = 30, rw = 0, boxW = 0, boxL = 0;
      for (;;){
        x.font = '800 ' + fs + 'px Syne';
        rw = x.measureText(rank).width;
        boxW = rw + PAD * 2;
        boxL = boxR - boxW;
        if (boxL >= statsEnd + GAP || fs <= 18) break;
        fs -= 2;
      }
      if (boxL < statsEnd + GAP){        // floor reached - clamp, then trim
        boxL = statsEnd + GAP; boxW = boxR - boxL;
        while (rank.length > 4 && x.measureText(rank).width > boxW - PAD * 2){
          rank = rank.slice(0, -1);
        }
        rw = x.measureText(rank).width;
      }
      x.strokeStyle = '#d4ff3f'; x.lineWidth = 2;
      x.strokeRect(boxL, boxY, boxW, boxH);
      var rm = x.measureText(rank);
      var asc = rm.actualBoundingBoxAscent || fs * 0.72;
      x.fillStyle = '#d4ff3f';
      x.fillText(rank, boxL + (boxW - rw) / 2, boxY + (boxH + asc) / 2);
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
    var foot = (D.hostn || '') + '  -  ' + (D.date || '') + '  -  ' + (D.active || 0) + '/' + (D.dc || 0) + ' active 30d';
    if (D.reclaim){ foot += '  -  reclaim ' + D.reclaim; }
    x.fillText(foot, 64, 592);
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
    Write-Utf8File $htmlPath $html
    Write-Host "HTML report: $htmlPath" -ForegroundColor Green
    if (-not $NoOpen) { try { Invoke-Item -LiteralPath $htmlPath } catch {} }
}
