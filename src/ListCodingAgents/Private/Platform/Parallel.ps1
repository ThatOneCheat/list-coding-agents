# Bounded parallelism that works on Windows PowerShell 5.1 (a RunspacePool;
# ForEach-Object -Parallel is 7.0+). Runspaces do not see module functions or
# module variables, so they are copied into the pool's InitialSessionState.

function Invoke-LcaParallel {
    <#
    Runs $ScriptBlock once per input item with at most $ThrottleLimit running
    at a time and returns one result per item, in input order:
      { Input, Output (always an array), Error (first error text or $null),
        TimedOut }
    The script block receives the item as its first argument. Non-terminating
    errors and exceptions are captured per item; diagnostics recorded inside
    a work item (Add-LcaDiagnostic) are merged into this session's list.
    With a throttle of 1 (or a single item) the work runs inline in the
    current runspace, which keeps Pester mocks effective.
    -FunctionName defaults to every module function (names containing 'Lca'
    or 'CodingAgent'); module variables named Lca* are copied too.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [AllowEmptyCollection()][object[]]$InputObject = @(),
        [int]$ThrottleLimit = 4,
        [string[]]$FunctionName,
        [hashtable]$Variable = @{},
        [double]$TimeoutSec = 300
    )
    $items = @($InputObject)
    if ($items.Count -eq 0) { return @() }

    $split = {
        param($raw)
        $o = New-Object System.Collections.Generic.List[object]
        $e = $null
        foreach ($x in @($raw)) {
            if ($x -is [System.Management.Automation.ErrorRecord]) { if (-not $e) { $e = $x.ToString() } }
            else { $o.Add($x) }
        }
        [pscustomobject]@{ Output = $o.ToArray(); Error = $e }
    }

    if ($ThrottleLimit -le 1 -or $items.Count -eq 1) {
        $results = foreach ($item in $items) {
            $r = [pscustomobject]@{ Input = $item; Output = @(); Error = $null; TimedOut = $false }
            try {
                $s = & $split @(& $ScriptBlock $item 2>&1)
                $r.Output = $s.Output
                $r.Error = $s.Error
            } catch { $r.Error = $_.Exception.Message }
            $r
        }
        return @($results)
    }

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $fnNames = $FunctionName
    if (-not $fnNames) {
        $fnNames = @(Get-ChildItem -Path 'function:' | Where-Object { $_.Name -match 'Lca|CodingAgent' } | ForEach-Object { $_.Name })
    }
    foreach ($fn in $fnNames) {
        $cmd = Get-Command -Name $fn -CommandType Function -ErrorAction Stop
        $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry ($fn, $cmd.Definition)))
    }
    $vars = @{}
    foreach ($v in @(Get-Variable -Scope Script -Name 'Lca*' -ErrorAction Ignore)) {
        if ($v.Name -ne 'LcaDiagnostics') { $vars[$v.Name] = $v.Value }
    }
    foreach ($k in $Variable.Keys) { $vars[[string]$k] = $Variable[$k] }
    foreach ($k in $vars.Keys) {
        $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry ([string]$k, $vars[$k], '')))
    }
    $limit = [Math]::Max(1, [Math]::Min($ThrottleLimit, $items.Count))
    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $limit, $iss, $Host)
    $jobs = New-Object System.Collections.Generic.List[object]
    # StrictMode must come after the work item's own param block, so the
    # caller's script block runs nested inside a small wrapper that also
    # collects its errors and diagnostics.
    $body = "param(`$lcaItem)`nSet-StrictMode -Version Latest`n" +
    "`$script:LcaDiagnostics = New-Object System.Collections.Generic.List[object]`n" +
    "`$lcaOut = @(); `$lcaErr = `$null`n" +
    "try { `$lcaOut = @(& {`n" + $ScriptBlock.ToString() + "`n} `$lcaItem 2>&1) } catch { `$lcaErr = `$_.Exception.Message }`n" +
    "[pscustomobject]@{ LcaEnvelope = `$true; Raw = `$lcaOut; Exception = `$lcaErr; Diagnostics = `$script:LcaDiagnostics.ToArray() }"
    $pending = New-Object System.Collections.Generic.List[object]
    try {
        $pool.Open()
        foreach ($item in $items) {
            $ps = [System.Management.Automation.PowerShell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($body).AddArgument($item)
            $jobs.Add([pscustomobject]@{ Input = $item; PS = $ps; Async = $ps.BeginInvoke() })
        }
        $deadline = [System.Diagnostics.Stopwatch]::StartNew()
        $results = foreach ($j in $jobs) {
            $r = [pscustomobject]@{ Input = $j.Input; Output = @(); Error = $null; TimedOut = $false }
            $left = [int][Math]::Max(0, ($TimeoutSec * 1000) - $deadline.ElapsedMilliseconds)
            if (-not $j.Async.AsyncWaitHandle.WaitOne($left)) {
                $r.TimedOut = $true
                $r.Error = 'parallel work item timed out'
                try { [void]$j.PS.BeginStop($null, $null) } catch { Write-Debug "BeginStop failed: $($_.Exception.Message)" }
                $pending.Add($j)
                $r
                continue
            }
            try {
                $envelope = @($j.PS.EndInvoke($j.Async)) | Where-Object { $_ -and $_.PSObject.Properties['LcaEnvelope'] } | Select-Object -First 1
                if ($envelope) {
                    $s = & $split $envelope.Raw
                    $r.Output = $s.Output
                    $r.Error = $s.Error
                    if ($envelope.Exception) { $r.Error = [string]$envelope.Exception }
                    foreach ($d in @($envelope.Diagnostics)) {
                        if ($d) { Add-LcaDiagnostic -Source ([string]$d.Source) -Level ([string]$d.Level) -Message ([string]$d.Message) }
                    }
                } elseif ($j.PS.Streams.Error.Count -gt 0) {
                    $r.Error = $j.PS.Streams.Error[0].ToString()
                }
            } catch {
                $r.Error = $_.Exception.Message
            }
            $r
        }
        return @($results)
    } finally {
        foreach ($j in $jobs) {
            if ($pending.Contains($j)) { continue }   # still stopping; disposing would block
            try { $j.PS.Dispose() } catch { Write-Debug "runspace dispose failed: $($_.Exception.Message)" }
        }
        # Closing waits for busy runspaces; never block the scan on a hung item.
        try {
            if ($pending.Count) { [void]$pool.BeginClose($null, $null) } else { $pool.Close(); $pool.Dispose() }
        } catch { Write-Debug "pool close failed: $($_.Exception.Message)" }
    }
}
