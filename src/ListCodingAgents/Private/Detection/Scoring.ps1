# Heuristic scorer (ported from v1 Get-AgentScore). Every weight, threshold
# and lexicon lives in ONE table: the "scoring" block of data/catalog.json.
# The scorer returns structured evidence ({Signal, Label, Weight, Source})
# instead of v1's comma-joined string; Why keeps v1's text for -ShowReasons.

$script:LcaScoringModelCache = $null

function Get-LcaScoringModel {
    <#
    Compiles the catalog's scoring table plus the command / path-signature
    sets derived from catalog entries:
      KnownCommands     - commands of non-ambiguous entries (v1 $KnownCli)
      AmbiguousCommands - commands of ambiguous entries     (v1 $AmbiguousCli)
      PathSignatures    - union of entry signatures, matched against paths
                          normalised to '/' (v1 $PathSignatures used '\')
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)]$Catalog, [switch]$Force)
    if ($script:LcaScoringModelCache -and -not $Force -and [object]::ReferenceEquals($script:LcaScoringModelCache.Catalog, $Catalog)) {
        return $script:LcaScoringModelCache
    }
    $cmp = [StringComparer]::OrdinalIgnoreCase
    $known = New-Object System.Collections.Generic.HashSet[string] ($cmp)
    $ambig = New-Object System.Collections.Generic.HashSet[string] ($cmp)
    $sigs = New-Object System.Collections.Generic.List[string]
    $byCommand = @{}
    foreach ($e in @($Catalog.agents)) {
        $isAmb = [bool](Get-LcaProperty -InputObject $e -Name 'ambiguous' -Default $false)
        foreach ($c in @(Get-LcaProperty -InputObject $e -Name 'commands' -Default @())) {
            if (-not $c) { continue }
            $lc = ([string]$c).ToLowerInvariant()
            if ($isAmb) { [void]$ambig.Add($lc) } else { [void]$known.Add($lc) }
            if (-not $byCommand.ContainsKey($lc)) { $byCommand[$lc] = $e }
        }
        foreach ($s in @(Get-LcaProperty -InputObject $e -Name 'pathSignatures' -Default @())) {
            if ($s -and -not $sigs.Contains([string]$s)) { $sigs.Add([string]$s) }
        }
    }
    # a name listed both ways counts as known (v1: $isAmbig = -not $isKnown -and ...)
    $sc = $Catalog.scoring
    $lex = $sc.lexicons
    $model = [pscustomobject]@{
        Catalog           = $Catalog
        Weights           = $sc.weights
        Thresholds        = $sc.thresholds
        Lexicons          = $lex
        BrandCommandRegex = ('^(?:' + $lex.brandWords + ')' + $lex.brandCommandSuffix + '$')
        KnownCommands     = $known
        AmbiguousCommands = $ambig
        PathSignatures    = $sigs.ToArray()
        EntryByCommand    = $byCommand
    }
    $script:LcaScoringModelCache = $model
    $model
}

function ConvertTo-LcaSignaturePath {
    <# Normalises a path for signature matching: '\' -> '/'. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Path)
    if (-not $Path) { return '' }
    $Path.Replace('\', '/')
}

function Get-LcaAgentScore {
    <#
    Scores one candidate. Inputs mirror v1: Text (package description,
    keywords, version-info text), Deps (dependency names), Publisher,
    Name (command basename or package display name) and Path (used ONLY for
    install-path signatures - never folded into the scored text, so sibling
    tools in an agent's install dir do not inherit its brand).
    Returns { Score, Evidence, Why, Excluded }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [AllowNull()][AllowEmptyCollection()][string[]]$Deps,
        [AllowNull()][AllowEmptyString()][string]$Publisher,
        [AllowNull()][AllowEmptyString()][string]$Name,
        [AllowNull()][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory = $true)]$Model
    )
    $w = $Model.Weights
    $lex = $Model.Lexicons
    # NB: PowerShell variable names are case-insensitive - $name IS $Name, so
    # it must be computed in one expression from the parameter.
    $name = if ($Name) { $Name.ToLowerInvariant() } else { '' }
    if ($null -eq $Deps) { $Deps = @() }
    $t = (@($Text, ($Deps -join ' '), $Publisher, $name) -join ' ')
    $tLower = $t.ToLowerInvariant()
    $ev = New-Object System.Collections.Generic.List[object]

    $excluded = {
        param($signal, $label)
        $e = New-LcaEvidence -Signal $signal -Label $label -Weight $w.excluded -Source 'name'
        [pscustomobject]@{ Score = [int]$w.excluded; Evidence = @($e); Why = $label; Excluded = $true }
    }

    # Pure MCP utilities / non-agents bail early unless the name is a known
    # CLI. Ambiguous names deliberately do NOT get the bypass: an
    # "amp-mcp-server" or "sg-updater" is still filtered by the guards below.
    $isKnown = $Model.KnownCommands.Contains($name)
    $isAmbig = (-not $isKnown) -and $Model.AmbiguousCommands.Contains($name)
    if (-not $isKnown) {
        if ($name -match $lex.mcpUtilityName) { return (& $excluded 'excluded-mcp-utility' 'excluded (mcp utility)') }
        # "CLI to install <x> skill ..." is a skill installer, never an agent -
        # unconditional (loose phrases like "ai coding" would otherwise keep it
        # alive via the agent-phrase guard below).
        if ($tLower -match $lex.skillInstaller) { return (& $excluded 'excluded-skill-installer' 'excluded (skill installer)') }
        if ($tLower -match $lex.hardExclude -and $tLower -notmatch $lex.agentPhrase) {
            return (& $excluded 'excluded-non-agent-phrase' 'excluded (non-agent phrase)')
        }
        if ($name -match $lex.helperName) { return (& $excluded 'excluded-helper-binary' 'excluded (helper binary)') }
    }

    if ($isKnown) {
        $ev.Add((New-LcaEvidence -Signal 'known-command' -Label 'known CLI name' -Weight $w.knownCommand -Source 'name' -Detail $name))
    } elseif ($isAmbig) {
        # Enough for the review tier, never enough to auto-detect alone:
        # ast-grep's "sg" must not be announced as a coding agent on a machine
        # that has never installed one.
        $ev.Add((New-LcaEvidence -Signal 'ambiguous-command' -Label 'ambiguous CLI name (needs corroboration)' -Weight $w.ambiguousCommand -Source 'name' -Detail $name))
    }

    # Path signatures only boost the primary agent CLI, not sibling tools.
    if ($Path -and ($isKnown -or $isAmbig -or $name -match $Model.BrandCommandRegex)) {
        $np = ConvertTo-LcaSignaturePath -Path $Path
        foreach ($pat in $Model.PathSignatures) {
            if ($np -match ('(?i)' + $pat)) {
                $ev.Add((New-LcaEvidence -Signal 'path-signature' -Label 'install path signature' -Weight $w.pathSignature -Source 'path' -Detail $pat))
                break
            }
        }
    }

    if ($tLower -match $lex.agentPhrase) {
        $ev.Add((New-LcaEvidence -Signal 'agent-phrase' -Label 'coding-agent phrase' -Weight $w.agentPhrase -Source 'text' -Detail $Matches[0]))
    }

    # Vendor from version-info CompanyName / package text only (never path).
    $vendorText = (@($Publisher, $Text) -join ' ')
    if ($vendorText -match ('(?i)(' + $lex.aiVendors + ')')) {
        $vendorHit = $Matches[1]
        if ($Publisher -notmatch $lex.vendorPublisherIgnore) {
            $ev.Add((New-LcaEvidence -Signal 'ai-vendor' -Label 'AI vendor' -Weight $w.aiVendor -Source 'vendor' -Detail $vendorHit))
        }
    }

    $sdkHits = @($Deps | Where-Object { $_ -and ($_ -match $lex.aiSdkDependency) })
    if ($sdkHits.Count -gt 0) {
        $ev.Add((New-LcaEvidence -Signal 'ai-sdk' -Label 'AI SDK dependency' -Weight $w.aiSdkDependency -Source 'dependencies' -Detail ($sdkHits -join ' ')))
    }

    if ($tLower -match $lex.agentWord -and $tLower -match $lex.agentContext) {
        $ev.Add((New-LcaEvidence -Signal 'agent-code' -Label 'agent + code' -Weight $w.agentPlusCode -Source 'text'))
    }

    if ($tLower -match ('(?i)(' + $lex.brandWords + ')')) {
        $brandHit = $Matches[1]
        $ev.Add((New-LcaEvidence -Signal 'brand' -Label 'model/brand name' -Weight $w.brandName -Source 'text' -Detail $brandHit))
        if ($tLower -match $lex.brandContext) {
            $ev.Add((New-LcaEvidence -Signal 'brand-cli' -Label 'brand + cli/code' -Weight $w.brandPlusCli -Source 'text'))
        }
        # Basename is the brand word itself, with or without the usual agent
        # suffix - "kimi", "kimi-cli" and "claude-code" all qualify.
        if ($name -match $Model.BrandCommandRegex) {
            $ev.Add((New-LcaEvidence -Signal 'brand-command' -Label 'brand command' -Weight $w.brandCommand -Source 'name' -Detail $name))
        }
    }

    if ($tLower -match $lex.aiToken -and $tLower -match $lex.aiContext) {
        $ev.Add((New-LcaEvidence -Signal 'ai-code' -Label 'ai + code token' -Weight $w.aiPlusCode -Source 'text'))
    }

    $score = 0
    foreach ($e in $ev) { $score += $e.Weight }
    [pscustomobject]@{
        Score    = [int]$score
        Evidence = $ev.ToArray()
        Why      = (@($ev | ForEach-Object { $_.Label }) -join ', ')
        Excluded = $false
    }
}

function Get-LcaTier {
    <# 'detected' / 'possible' / 'excluded' from a score, using the table. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][int]$Score, [Parameter(Mandatory = $true)]$Model)
    if ($Score -ge [int]$Model.Thresholds.detected) { return 'detected' }
    if ($Score -ge [int]$Model.Thresholds.possible) { return 'possible' }
    'excluded'
}
