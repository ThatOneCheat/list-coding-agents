# Bounded parallelism that works on Windows PowerShell 5.1 (a RunspacePool;
# ForEach-Object -Parallel is 7.0+). Runspaces do not see module functions,
# so the caller names the functions the work item needs and their
# definitions are copied into the pool's InitialSessionState.

function Invoke-LcaParallel {
    <#
    Runs $ScriptBlock once per input item with at most $ThrottleLimit running
    at a time and returns one result per item, in input order:
      { Input, Output, Error }
    The script block receives the item as its first argument. With a throttle
    of 1 (or a single item) the work runs inline in the current runspace,
    which keeps Pester mocks effective.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [AllowEmptyCollection()][object[]]$InputObject = @(),
        [int]$ThrottleLimit = 4,
        [string[]]$FunctionName = @(),
        [hashtable]$Variable = @{},
        [double]$TimeoutSec = 300
    )
    $items = @($InputObject)
    if ($items.Count -eq 0) { return @() }

    if ($ThrottleLimit -le 1 -or $items.Count -eq 1) {
        $results = foreach ($item in $items) {
            $r = [pscustomobject]@{ Input = $item; Output = $null; Error = $null }
            try { $r.Output = & $ScriptBlock $item } catch { $r.Error = $_.Exception.Message }
            $r
        }
        return @($results)
    }

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($fn in $FunctionName) {
        $cmd = Get-Command -Name $fn -CommandType Function -ErrorAction Stop
        $entry = New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry ($fn, $cmd.Definition)
        $iss.Commands.Add($entry)
    }
    foreach ($k in $Variable.Keys) {
        $ve = New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry ([string]$k, $Variable[$k], '')
        $iss.Variables.Add($ve)
    }
    $limit = [Math]::Max(1, [Math]::Min($ThrottleLimit, $items.Count))
    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $limit, $iss, $Host)
    $jobs = New-Object System.Collections.Generic.List[object]
    # StrictMode must come after the work item's own param block, so the
    # caller's script block runs nested inside a small wrapper.
    $body = "param(`$lcaItem)`nSet-StrictMode -Version Latest`n& {`n" + $ScriptBlock.ToString() + "`n} `$lcaItem"
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
            $r = [pscustomobject]@{ Input = $j.Input; Output = $null; Error = $null }
            try {
                $left = [int][Math]::Max(1, ($TimeoutSec * 1000) - $deadline.ElapsedMilliseconds)
                if ($j.Async.AsyncWaitHandle.WaitOne($left)) {
                    $out = @($j.PS.EndInvoke($j.Async))
                    $r.Output = $out
                    if ($out.Count -eq 1) { $r.Output = $out[0] }
                    if ($j.PS.Streams.Error.Count -gt 0 -and $null -eq $r.Output) {
                        $r.Error = $j.PS.Streams.Error[0].ToString()
                    }
                } else {
                    $r.Error = 'parallel work item timed out'
                    [void]$j.PS.BeginStop($null, $null)
                }
            } catch {
                $r.Error = $_.Exception.Message
            }
            $r
        }
        return @($results)
    } finally {
        foreach ($j in $jobs) {
            try { $j.PS.Dispose() } catch { Write-Debug "runspace dispose failed: $($_.Exception.Message)" }
        }
        try { $pool.Close(); $pool.Dispose() } catch { Write-Debug "pool dispose failed: $($_.Exception.Message)" }
    }
}
