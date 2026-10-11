# The scan context: options, platform, clock, config, catalog, override
# lists, caches, timings. Created once per scan by New-LcaContext and passed
# to every phase. FROZEN CONTRACT for Phase 2 workstreams.

$script:LcaToolVersion = '2.0.0'
$script:LcaSchemaVersion = 2

function New-LcaContext {
    <#
    Options (all optional): IncludeEditors, IncludeExtensions, All, SkipWinget,
    CheckUpdates, NoProbe, Explain, ShowReasons, Redact.
    ScriptRoot is the folder of the entry script (v1 read agents-extra.txt /
    agents-exclude.txt / last-scan.json from there); empty under irm | iex.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Constructor: builds an in-memory object and changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [hashtable]$Options = @{},
        [AllowEmptyString()][AllowNull()][string]$ScriptRoot
    )
    $opt = [ordered]@{
        IncludeEditors    = $false
        IncludeExtensions = $false
        All               = $false
        SkipWinget        = $false
        CheckUpdates      = $false
        NoProbe           = $false
        Explain           = $null
        ShowReasons       = $false
        Redact            = $false
    }
    foreach ($k in $Options.Keys) {
        if (-not $opt.Contains($k)) { throw "New-LcaContext: unknown option '$k'" }
        $v = $Options[$k]
        if ($v -is [System.Management.Automation.SwitchParameter]) { $v = $v.IsPresent }
        $opt[$k] = $v
    }
    if ($opt.All) { $opt.IncludeEditors = $true; $opt.IncludeExtensions = $true }

    $ctx = [pscustomobject]@{
        PSTypeName   = 'ListCodingAgents.Context'
        Options      = [pscustomobject]$opt
        Platform     = (Get-LcaPlatform)
        Now          = (Get-LcaNow)
        ScriptRoot   = $ScriptRoot
        StateDir     = $null
        ConfigDir    = $null
        Config       = $null
        Catalog      = $null
        Extra        = $null
        Exclude      = $null
        ProbeCache   = @{}
        Parallelism  = 4
        Timings      = [ordered]@{}
        Data         = @{}   # scratch space for cross-phase data (e.g. npm metadata)
    }
    $ctx.StateDir = Get-LcaStateDirectory
    $ctx.ConfigDir = Get-LcaConfigDirectory
    $ctx.Config = Get-LcaConfig -Context $ctx
    $ctx.Catalog = Get-LcaCatalog
    $ctx.Extra = Get-LcaNameList -Context $ctx -FileName 'agents-extra.txt'
    $ctx.Exclude = Get-LcaNameList -Context $ctx -FileName 'agents-exclude.txt'
    $cpu = [System.Environment]::ProcessorCount
    $ctx.Parallelism = [int][Math]::Max(2, [Math]::Min(8, $cpu))
    if ($ctx.Config.Parallelism) { $ctx.Parallelism = [int]$ctx.Config.Parallelism }
    $ctx
}

function Measure-LcaPhase {
    <#
    Runs one scan phase, records its wall-clock time in Context.Timings and
    prints it with -Verbose. Returns the script block's output.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $ScriptBlock
    } finally {
        $sw.Stop()
        $Context.Timings[$Name] = [int]$sw.ElapsedMilliseconds
        Write-Verbose ('phase {0}: {1} ms' -f $Name, $sw.ElapsedMilliseconds)
    }
}
