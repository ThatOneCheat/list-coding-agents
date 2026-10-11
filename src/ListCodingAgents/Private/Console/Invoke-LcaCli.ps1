# The list-coding-agents.ps1 entry point. The script's param block (see
# src/list-coding-agents.ps1) forwards $PSBoundParameters here. Returns the
# process exit code; the script decides whether to call exit.

$script:LcaLastExitCode = 0
$script:LcaExitCode = @{
    Ok           = 0
    Error        = 1
    BadArguments = 2
    FailOn       = 3
    UpdateFailed = 4
}

function Get-LcaCliOption {
    <#
    Merges bound parameters over config.json "defaults" (a switch given on
    the command line always wins) and returns a hashtable of every option.
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
    if ($opt['UpdateAll']) { $opt['CheckUpdates'] = $true }
    $opt
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
    try {
        $probeCtx = [pscustomobject]@{ ConfigDir = (Get-LcaConfigDirectory) }
        $cfg = Get-LcaConfig -Context $probeCtx
        $opt = Get-LcaCliOption -BoundParameters $BoundParameters -ConfigDefaults $cfg.Defaults
        $script:LcaLastExitCode = $script:LcaExitCode.Ok
        if ($opt.Version) {
            Write-Output ('list-coding-agents {0}' -f $script:LcaToolVersion)
            return
        }
        $ctxOptions = @{
            IncludeEditors = $opt.IncludeEditors; IncludeExtensions = $opt.IncludeExtensions; All = $opt.All
            SkipWinget = $opt.SkipWinget; CheckUpdates = $opt.CheckUpdates; NoProbe = $opt.NoProbe
            Explain = $opt.Explain; ShowReasons = $opt.ShowReasons; Redact = $opt.Redact
        }
        $ctx = New-LcaContext -Options $ctxOptions -ScriptRoot $ScriptRoot
        $ctx.Data['quiet'] = [bool]$opt.Quiet
        $scan = Invoke-LcaScan -Context $ctx

        if ($opt.Explain) {
            foreach ($l in (Get-LcaExplanation -Context $ctx -Scan $scan -Name $opt.Explain).Lines) { Write-LcaConsoleLine $l }
        } elseif (-not $opt.Quiet -and -not $opt.Format) {
            Write-LcaConsoleReport -Context $ctx -Scan $scan
        }

        $exit = $script:LcaExitCode.Ok
        if ($opt.UpdateAll) {
            $res = @(Invoke-LcaUpdateAll -Context $ctx -Scan $scan -Force:$opt.Force -DryRun:([bool]$opt.WhatIf) -AskConfirm:([bool]$opt.Confirm))
            if (@($res | Where-Object { $_.Status -eq 'failed' }).Count) { $exit = $script:LcaExitCode.UpdateFailed }
        }
        if ($opt.FailOn) {
            $failed = @(Test-LcaFailOn -Context $ctx -Scan $scan -FailOn $opt.FailOn)
            if ($failed.Count -and $exit -eq $script:LcaExitCode.Ok) {
                $exit = $script:LcaExitCode.FailOn
                if (-not $opt.Quiet) { Write-LcaConsoleLine ('-FailOn matched: ' + ($failed -join ', ')) 'Red' }
            }
        }

        Save-LcaState -Context $ctx -Scan $scan

        $outDir = $opt.OutDir
        if (-not $outDir) { $outDir = (Get-Location).ProviderPath }
        $scan.Diagnostics = @(Get-LcaDiagnostic)
        $export = ConvertTo-LcaExport -Scan $scan -Context $ctx -Redact:$opt.Redact
        if ($opt.Json) {
            $jsonPath = Join-Path -Path $outDir -ChildPath 'coding-agents.json'
            Write-LcaTextFile -Path $jsonPath -Content ((ConvertTo-LcaJson -InputObject $export) + "`n")
            if (-not $opt.Quiet) { Write-LcaConsoleLine "JSON export: $jsonPath" 'Green' }
        }
        if (-not $opt.NoHtml) {
            $htmlPath = Join-Path -Path $outDir -ChildPath 'coding-agents.html'
            Write-LcaTextFile -Path $htmlPath -Content (ConvertTo-LcaReportHtml -Export $export)
            if (-not $opt.Quiet) { Write-LcaConsoleLine "HTML report: $htmlPath" 'Green' }
            if (-not $opt.NoOpen) { Open-LcaReport -Path $htmlPath }
        }
        if ($opt.Format -eq 'json') { Write-Output (ConvertTo-LcaJson -InputObject $export) }
        if ($opt.PassThru) { Select-LcaAgentInScope -Context $ctx -Agent $scan.Agents | ForEach-Object { Write-Output $_ } }
        $script:LcaLastExitCode = $exit
    } catch {
        $script:LcaLastExitCode = $script:LcaExitCode.Error
        Write-Error -ErrorRecord $_
    }
}

function Open-LcaReport {
    <# Opens the report with the platform's default handler; never fatal. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        switch (Get-LcaPlatform) {
            'windows' { Invoke-Item -LiteralPath $Path }
            'macos' { [void](Open-LcaProcess -FilePath 'open' -ArgumentList @($Path)) }
            default { [void](Open-LcaProcess -FilePath 'xdg-open' -ArgumentList @($Path)) }
        }
    } catch {
        Add-LcaDiagnostic -Source 'report' -Level 'info' -Message "could not open $Path" -ErrorRecord $_
    }
}
