# Version probes: bare exes carry no metadata, so ask them (`<exe> --version`)
# through the process seam - stdin closed, stdout+stderr captured, hard
# timeout with a process-tree kill - and cache the answer by path + mtime.

function Get-LcaVersionFromText {
    <# First dotted version number in a CLI's --version output. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ($Text -and $Text -match '(\d+\.\d+(\.\d+)*)') { return $Matches[1] }
    $null
}

function Get-LcaProbeCacheKey {
    <# "<path>|<mtime ticks>" (v1 key format), or $null when unreadable. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $it = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return ('{0}|{1}' -f $Path, $it.LastWriteTimeUtc.Ticks)
    } catch {
        Add-LcaDiagnostic -Source 'probe' -Level 'info' -Message "cannot stat $Path" -ErrorRecord $_
        return $null
    }
}

function Get-LcaVersionProbe {
    <# Runs `<exe> --version` with a timeout and returns the version or $null. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$ArgumentList = @('--version'),
        [double]$TimeoutSec = 8
    )
    $r = Invoke-LcaProcess -FilePath $Path -ArgumentList $ArgumentList -TimeoutSec $TimeoutSec
    if ($r.TimedOut) {
        Add-LcaDiagnostic -Source 'probe' -Level 'info' -Message ("{0} --version timed out after {1}s" -f $Path, $TimeoutSec)
        return $null
    }
    $v = Get-LcaVersionFromText -Text $r.StdOut
    if (-not $v) { $v = Get-LcaVersionFromText -Text $r.StdErr }
    $v
}
