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

    Honest limitation: a command that is a bare binary with no metadata and a
    non-descriptive name (e.g. "agy") cannot be classified by any heuristic.
    Add such names to agents-extra.txt (one per line) as an escape hatch.

.PARAMETER IncludeEditors
    Also include GUI AI editors (Cursor/Windsurf/Kiro style launchers).
.PARAMETER ShowReasons
    Print the signals that triggered each detection.
.PARAMETER NoHtml
    Skip writing/opening the HTML report.
#>
[CmdletBinding()]
param([switch]$IncludeEditors, [switch]$ShowReasons, [switch]$NoHtml)

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
            Package = $j.name; Version = $j.version
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
            if ($f.FullName.StartsWith($env:WINDIR, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            if ($exts -notcontains $f.Extension.ToUpperInvariant()) { continue }
            $name = $f.BaseName.ToLowerInvariant()
            if (-not $seen.ContainsKey($name)) { $seen[$name] = $f.FullName }
        }
    }
    $seen.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Command = $_.Key; Path = $_.Value } }
}

$npmMeta = Get-NpmMeta
$extraFile = Join-Path $PSScriptRoot 'agents-extra.txt'
$extra = if (Test-Path -LiteralPath $extraFile) { Get-Content $extraFile | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ -and $_ -notmatch '^#' } } else { @() }

# --- evaluate every PATH candidate -----------------------------------------
$rows = foreach ($c in Get-PathCandidates) {
    $name = $c.Command; $path = $c.Path
    $text = $name; $deps = @(); $publisher = ''; $method = 'standalone installer'; $kind = 'cli'

    if ($path -match '(?i)\\AppData\\Roaming\\npm\\' -or $path -match '(?i)\\node_modules\\') { $method = 'npm' }
    elseif ($path -match '(?i)\\WindowsApps\\')                                                { $method = 'winget' }
    elseif ($path -match '(?i)\\Python\\.*\\Scripts\\' -or $path -match '(?i)\\uv\\')          { $method = 'pip / uv' }
    if ($path -match '(?i)\\Programs\\[^\\]+\\.*bin\\')                                         { $kind = 'editor' }

    if ($npmMeta.ContainsKey($name)) { $m = $npmMeta[$name]; $text = $m.Text; $deps = $m.Deps; $method = 'npm' }
    if ($path -match '\.exe$') {
        try { $vi = (Get-Item -LiteralPath $path).VersionInfo
              $text = ($text, $vi.ProductName, $vi.FileDescription) -join ' '
              $publisher = "$($vi.CompanyName)" } catch {}
    }

    $s = Get-AgentScore -Text $text -Deps $deps -Publisher $publisher -Name $name
    if ($extra -contains $name -and $s.Score -lt 4) { $s = [pscustomobject]@{ Score = 5; Why = 'agents-extra.txt override' } }

    [pscustomobject]@{ Name=$name; Command=$name; Source=$path; Method=$method; Kind=$kind; Score=$s.Score; Why=$s.Why }
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
            $rows += [pscustomobject]@{ Name=$pkgName; Command='(winget)'; Source=$id; Method='winget'; Kind='cli'; Score=$s.Score; Why=$s.Why }
        }
    }
}

# --- split into tiers -------------------------------------------------------
$detected = $rows | Where-Object { $_.Score -ge 4 -and ($IncludeEditors -or $_.Kind -ne 'editor') }
$possible = $rows | Where-Object { $_.Score -ge 2 -and $_.Score -lt 4 -and ($IncludeEditors -or $_.Kind -ne 'editor') }

$rank = @{ 'npm'=1; 'winget'=2; 'pip / uv'=3; 'standalone installer'=4 }

Write-Host ""
Write-Host "Auto-detected coding agents ($(@($detected).Count) detected, $(@($possible).Count) possible)" -ForegroundColor Cyan
if (-not $IncludeEditors) { Write-Host "(GUI editors hidden - use -IncludeEditors)" -ForegroundColor DarkGray }

foreach ($grp in $detected | Group-Object Method | Sort-Object { $rank[$_.Name] }) {
    Write-Host ""
    Write-Host ("== Installed via {0} ({1}) ==" -f $grp.Name, $grp.Count) -ForegroundColor Yellow
    $cols = @(@{n='Agent';e={$_.Name}}, @{n='Command';e={$_.Command}}, @{n='Source';e={$_.Source}})
    if ($ShowReasons) { $cols += @{n='Why';e={$_.Why}} }
    $grp.Group | Sort-Object Name | Format-Table $cols -AutoSize
}

if (@($possible).Count) {
    Write-Host ""
    Write-Host "== Possible (weak signal - review) ==" -ForegroundColor DarkYellow
    $possible | Sort-Object Name | Format-Table @{n='Agent';e={$_.Name}}, @{n='Source';e={$_.Source}}, @{n='Why';e={$_.Why}} -AutoSize
}
Write-Host ""

# --- HTML report ------------------------------------------------------------
if (-not $NoHtml) {
    function Enc($s) { [System.Net.WebUtility]::HtmlEncode([string]$s) }
    $chanColors = @{ 'npm'='#ff6b5e'; 'winget'='#5ad1ff'; 'pip / uv'='#ffcf5a'; 'standalone installer'='#d4ff3f' }

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
            [void]$sb.AppendLine("<li class=""unit"" style=""--d:$d""><span class=""idx"">$idx</span><span class=""cmd"">$(Enc $r.Name)</span><span class=""path"" title=""$(Enc $r.Source)"">$(Enc $r.Source)</span><span class=""dot""></span></li>")
        }
        [void]$sb.AppendLine('</ol></section>')
    }
    if (@($possible).Count) {
        $chN++; $chId = '{0:D2}' -f $chN
        [void]$sb.AppendLine("<section class=""channel possible"" style=""--c:#8a8a80;--d:$d"">")
        [void]$sb.AppendLine("<div class=""ch-head""><span class=""ch-id"">$chId</span><h2>possible</h2><span class=""ch-count"">$(@($possible).Count)</span></div>")
        [void]$sb.AppendLine('<ol class="units">')
        $i = 0
        foreach ($r in $possible | Sort-Object Name) {
            $i++; $d++; $idx = '{0:D2}' -f $i
            [void]$sb.AppendLine("<li class=""unit"" style=""--d:$d""><span class=""idx"">$idx</span><span class=""cmd"">$(Enc $r.Name)</span><span class=""path"" title=""$(Enc $r.Why)"">$(Enc $r.Why)</span><span class=""dot hollow""></span></li>")
        }
        [void]$sb.AppendLine('</ol></section>')
    }

    $generated = Get-Date -Format 'yyyy-MM-dd HH:mm'
    $dc = @($detected).Count; $pc = @($possible).Count
    $cc = (@($detected | Group-Object Method)).Count
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
.channel.possible{border-style:dashed;opacity:.92}
.ch-head{display:flex;align-items:center;gap:18px;padding:19px 26px 16px;border-bottom:1px solid var(--line)}
.ch-id{font-family:'Syne',sans-serif;font-weight:800;font-size:30px;line-height:1;color:transparent;-webkit-text-stroke:1px var(--c)}
.ch-head h2{font-size:13.5px;letter-spacing:.28em;text-transform:uppercase;font-weight:500;color:var(--ink)}
.ch-count{margin-left:auto;font-size:12px;color:var(--c);border:1px solid var(--c);padding:3px 12px;letter-spacing:.12em;font-variant-numeric:tabular-nums}
.units{list-style:none;padding:7px 0}
.unit{display:grid;grid-template-columns:3rem minmax(7rem,13rem) 1fr auto;align-items:center;gap:20px;padding:12px 26px;position:relative;opacity:0;transform:translateY(10px);animation:rise .5s cubic-bezier(.2,.7,.15,1) forwards;animation-delay:calc(var(--d,0)*36ms + .4s)}
.unit::before{content:"";position:absolute;left:0;top:0;bottom:0;width:0;background:var(--c);opacity:.09;transition:width .28s cubic-bezier(.2,.7,.15,1)}
.unit:hover::before{width:100%}
.unit:hover .cmd{color:var(--c)}.unit:hover .path{color:var(--ink)}
.idx{color:var(--mut);font-size:12px;font-variant-numeric:tabular-nums}
.cmd{font-weight:700;font-size:14.5px;color:var(--ink);transition:color .2s}
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
