# Fake package-manager shim. The fixture builder (tests/Helpers/Fixture.psm1)
# puts tiny wrappers named npm / npm.cmd / winget.cmd ... on the fixture PATH;
# each one calls this script with the tool name first. Nothing real is ever
# installed, upgraded or removed: the shim records its arguments and replays
# a canned response.
#
#   LCA_SHIM_LOG   file that receives one JSON line per call {tool, args}
#   LCA_SHIM_DATA  folder with <tool>.json:
#                  { "<args joined by spaces>": { "stdout": "...", "stderr": "...",
#                                                 "exitCode": 0, "sleepSec": 0 },
#                    "*": { ... fallback ... } }
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Tool,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)
$ErrorActionPreference = 'Stop'
if ($null -eq $Rest) { $Rest = @() }
$key = ($Rest -join ' ')
if ($env:LCA_SHIM_LOG) {
    $line = ConvertTo-Json -Compress -InputObject ([ordered]@{ tool = $Tool; args = @($Rest) })
    [System.IO.File]::AppendAllText($env:LCA_SHIM_LOG, $line + "`n")
}
$resp = $null
if ($env:LCA_SHIM_DATA) {
    $file = Join-Path -Path $env:LCA_SHIM_DATA -ChildPath ($Tool + '.json')
    if (Test-Path -LiteralPath $file) {
        $map = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($file))
        $p = $map.PSObject.Properties[$key]
        if (-not $p) { $p = $map.PSObject.Properties['*'] }
        if ($p) { $resp = $p.Value }
    }
}
if (-not $resp) {
    [Console]::Error.WriteLine("shim ${Tool}: no canned response for '$key'")
    exit 97
}
$get = { param($n, $d) $q = $resp.PSObject.Properties[$n]; if ($q -and $null -ne $q.Value) { $q.Value } else { $d } }
# pidFile: record this shim's PID (and a spawned grandchild's) so tests can
# prove a timeout kills the whole process tree.
$pidFile = [string](& $get 'pidFile' '')
if ($pidFile) {
    $pids = @($PID)
    if ([bool](& $get 'spawnChild' $false)) {
        $hostExe = (Get-Process -Id $PID).Path
        $sp = @{ FilePath = $hostExe; ArgumentList = @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 120'); PassThru = $true }
        if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { $sp['WindowStyle'] = 'Hidden' }
        $child = Start-Process @sp
        $pids += $child.Id
    }
    [System.IO.File]::WriteAllText($pidFile, ($pids -join ','))
}
$sleep = [double](& $get 'sleepSec' 0)
if ($sleep -gt 0) { Start-Sleep -Milliseconds ([int]($sleep * 1000)) }
$out = [string](& $get 'stdout' '')
$err = [string](& $get 'stderr' '')
# Raw UTF-8 bytes: Console writers would use the OEM code page on Windows
# and turn canned non-ASCII output (winget's ellipsis) into '?'.
$utf8 = New-Object System.Text.UTF8Encoding($false)
if ($out) { $b = $utf8.GetBytes($out); $so = [Console]::OpenStandardOutput(); $so.Write($b, 0, $b.Length); $so.Flush() }
if ($err) { $b = $utf8.GetBytes($err); $se = [Console]::OpenStandardError(); $se.Write($b, 0, $b.Length); $se.Flush() }
exit ([int](& $get 'exitCode' 0))
