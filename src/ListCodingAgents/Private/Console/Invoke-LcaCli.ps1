# The list-coding-agents.ps1 entry point. The script's param block (see
# src/list-coding-agents.ps1) forwards $PSBoundParameters here. Pipeline
# output (-PassThru objects, -Format text, -Version) goes to the output
# stream; the exit code is left in $script:LcaLastExitCode for the script.

$script:LcaLastExitCode = 0
$script:LcaExitCode = @{
    Ok           = 0
    Error        = 1
    BadArguments = 2
    FailOn       = 3
    UpdateFailed = 4
}
$script:LcaFormatValues = @('table', 'json', 'csv', 'markdown')
$script:LcaFailOnValues = @('outdated', 'stale', 'conflict', 'new')

function Get-LcaCliOption {
    <#
    Merges bound parameters over config.json "defaults" (a switch given on
    the command line always wins) and returns a hashtable of every option.
    Throws an ArgumentException for invalid -Format / -FailOn values.
    -FailOn accepts "a,b" as one string (that is how pwsh -File passes it).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([hashtable]$BoundParameters = @{}, [hashtable]$ConfigDefaults = @{})
    $names = @('IncludeEditors', 'ShowReasons', 'NoHtml', 'SkipWinget', 'CheckUpdates', 'UpdateAll', 'Json',
        'IncludeExtensions', 'All', 'NoProbe', 'NoOpen', 'PassThru', 'Quiet', 'NoColor', 'Redact', 'Version', 'Force')
    $opt = @{}
    foreach ($n in $names) {
        $v = $false
        if ($ConfigDefaults.ContainsKey($n)) { $v = [bool]$ConfigDefaults[$n] }
        if ($BoundParameters.ContainsKey($n)) { $v = [bool]$BoundParameters[$n] }
        $opt[$n] = $v
    }
    foreach ($n in @('Explain', 'OutDir', 'Format', 'FailOn', 'WhatIf', 'Confirm')) {
        $opt[$n] = $null
        if ($BoundParameters.ContainsKey($n)) { $opt[$n] = $BoundParameters[$n] }
    }
    foreach ($n in @('WhatIf', 'Confirm')) { $opt[$n] = [bool]$opt[$n] }
    if ($opt['Explain'] -is [string] -and -not $opt['Explain'].Trim()) { $opt['Explain'] = $null }
    if ($opt['OutDir'] -is [string] -and -not $opt['OutDir'].Trim()) { $opt['OutDir'] = $null }
    if ($opt['Format']) {
        $f = ([string]$opt['Format']).Trim().ToLowerInvariant()
        if ($script:LcaFormatValues -notcontains $f) {
            throw (New-Object System.ArgumentException ("-Format must be one of: {0} (got '{1}')" -f ($script:LcaFormatValues -join ', '), $opt['Format']))
        }
        $opt['Format'] = $f
    } else { $opt['Format'] = $null }
    $fo = @()
    foreach ($item in @($opt['FailOn'])) {
        foreach ($part in ([string]$item -split ',')) {
            $c = $part.Trim().ToLowerInvariant()
            if (-not $c) { continue }
            if ($script:LcaFailOnValues -notcontains $c) {
                throw (New-Object System.ArgumentException ("-FailOn accepts: {0} (got '{1}')" -f ($script:LcaFailOnValues -join ', '), $c))
            }
            if ($fo -notcontains $c) { $fo += $c }
        }
    }
    $opt['FailOn'] = $fo
    if ($opt['UpdateAll']) { $opt['CheckUpdates'] = $true }
    $opt
}

function Resolve-LcaOutputPath {
    <# Resolves a user path against the PowerShell location (not the .NET process directory). #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Path)
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Invoke-LcaCli {
    <#
    Runs the CLI. Pipeline output (-PassThru objects, -Format text,
    -Version) is written to the output stream; the process exit code is left
    in $script:LcaLastExitCode for the entry script.
    #>
    [CmdletBinding()]
    param(
        [hashtable]$BoundParameters = @{},
        [AllowEmptyString()][AllowNull()][string]$ScriptRoot
    )
    $script:LcaLastExitCode = $script:LcaExitCode.Ok
    Clear-LcaDiagnostic
    try {
        $cfg = Get-LcaConfig -Context ([pscustomobject]@{ ConfigDir = (Get-LcaConfigDirectory) })
        try {
            $opt = Get-LcaCliOption -BoundParameters $BoundParameters -ConfigDefaults $cfg.Defaults
        } catch [System.ArgumentException] {
            $script:LcaLastExitCode = $script:LcaExitCode.BadArguments
            # -ErrorAction Continue: a caller's $ErrorActionPreference = 'Stop'
            # must not turn this into an exception and lose exit code 2.
            Write-Error -Message $_.Exception.Message -Category InvalidArgument -ErrorAction Continue
            return
        }
        if ($opt.Version) {
            Write-Output ('list-coding-agents {0}' -f $script:LcaToolVersion)
            return
        }
        # Machine-readable stdout (-Format) must not be mixed with the coloured
        # report or notices, and should not pop a browser.
        $machine = [bool]$opt.Format
        $talk = -not $opt.Quiet -and -not $machine
        $ctxOptions = @{
            IncludeEditors = $opt.IncludeEditors; IncludeExtensions = $opt.IncludeExtensions; All = $opt.All
            SkipWinget = $opt.SkipWinget; CheckUpdates = $opt.CheckUpdates; NoProbe = $opt.NoProbe
            Explain = $opt.Explain; ShowReasons = $opt.ShowReasons; Redact = $opt.Redact
            Quiet = (-not $talk); NoColor = $opt.NoColor; Format = $opt.Format
        }
        $ctx = New-LcaContext -Options $ctxOptions -ScriptRoot $ScriptRoot -Config $cfg
        $ctx.Data['quiet'] = -not $talk
        $scan = Invoke-LcaScan -Context $ctx

        if ($opt.Explain) {
            foreach ($l in (Get-LcaExplanation -Context $ctx -Scan $scan -Name $opt.Explain).Lines) { Write-LcaConsoleLine $l }
        } elseif ($talk) {
            Write-LcaConsoleReport -Context $ctx -Scan $scan
        }

        $exit = $script:LcaExitCode.Ok
        if ($opt.UpdateAll) {
            $res = @(Invoke-LcaUpdateAll -Context $ctx -Scan $scan -Force:$opt.Force -DryRun:$opt.WhatIf -AskConfirm:$opt.Confirm)
            if (@($res | Where-Object { $_.Status -eq 'failed' }).Count) { $exit = $script:LcaExitCode.UpdateFailed }
        }
        if (@($opt.FailOn).Count) {
            $failed = @(Test-LcaFailOn -Context $ctx -Scan $scan -FailOn $opt.FailOn)
            if ($failed.Count -and $exit -eq $script:LcaExitCode.Ok) {
                $exit = $script:LcaExitCode.FailOn
                if ($talk) { Write-LcaConsoleLine ('-FailOn matched: ' + ($failed -join ', ')) 'Red' }
            }
        }

        $scan.Diagnostics = @(Get-LcaDiagnostic)
        $export = ConvertTo-LcaExport -Scan $scan -Context $ctx -Redact:$opt.Redact
        # -WhatIf promises that nothing changes: no state, no files.
        if ($opt.WhatIf) {
            if ($talk) { Write-LcaConsoleLine 'What if: state, JSON and HTML were not written (-WhatIf).' 'DarkGray' }
        } else {
            Save-LcaState -Context $ctx -Scan $scan
            $outDir = $opt.OutDir
            if (-not $outDir) { $outDir = '.' }
            $outDir = Resolve-LcaOutputPath -Path $outDir
            if ($opt.Json) {
                $jsonPath = Join-Path -Path $outDir -ChildPath 'coding-agents.json'
                Write-LcaTextFile -Path $jsonPath -Content ((ConvertTo-LcaJson -InputObject $export) + "`n")
                if ($talk) { Write-LcaConsoleLine "JSON export: $jsonPath" 'Green' }
            }
            if (-not $opt.NoHtml) {
                $htmlPath = Join-Path -Path $outDir -ChildPath 'coding-agents.html'
                Write-LcaTextFile -Path $htmlPath -Content (ConvertTo-LcaReportHtml -Export $export)
                if ($talk) { Write-LcaConsoleLine "HTML report: $htmlPath" 'Green' }
                if (-not $opt.NoOpen -and $talk) { Open-LcaFile -Path $htmlPath }
            }
        }
        if ($opt.Format -eq 'json') { Write-Output (ConvertTo-LcaJson -InputObject $export) }
        if ($opt.PassThru) { Select-LcaAgentInScope -Context $ctx -Agent $scan.Agents | ForEach-Object { Write-Output $_ } }
        $script:LcaLastExitCode = $exit
    } catch {
        $script:LcaLastExitCode = $script:LcaExitCode.Error
        Write-Error -ErrorRecord $_ -ErrorAction Continue
    }
}
