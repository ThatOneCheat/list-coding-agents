# Diagnostics: every recoverable failure (a tool that is missing, a query that
# timed out, a file that could not be parsed) is recorded here, written to
# -Verbose, and exported in the JSON "diagnostics" array - never swallowed by
# an empty catch. Messages pass through Protect-LcaText so a parser error
# that quotes file content cannot carry a secret into any output.

$script:LcaDiagnostics = New-Object System.Collections.Generic.List[object]

function Clear-LcaDiagnostic {
    [CmdletBinding()]
    param()
    $script:LcaDiagnostics = New-Object System.Collections.Generic.List[object]
}

function Protect-LcaText {
    <# Masks anything that looks like a credential and caps the length. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Text, [int]$MaxLength = 300)
    if (-not $Text) { return $Text }
    $t = $Text
    $tokenPatterns = @(
        '(?i)\bsk-[A-Za-z0-9_\-]{4,}',
        '\bgh[pousr]_[A-Za-z0-9_]{4,}',
        '\bgithub_pat_[A-Za-z0-9_]{8,}',
        '\bxox[abprs]-[A-Za-z0-9\-]{6,}',
        '\bAKIA[0-9A-Z]{12,}',
        '\bAIza[0-9A-Za-z_\-]{12,}',
        '\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{4,}\.?[A-Za-z0-9_\-]*'
    )
    foreach ($p in $tokenPatterns) { $t = [regex]::Replace($t, $p, '<redacted>') }
    # "apiKey": "value" / token=value - keep the key name, drop the value
    $t = [regex]::Replace($t,
        '(?i)("?(api[_-]?key|access[_-]?token|refresh[_-]?token|secret|password|bearer|authorization)"?\s*[:=]\s*)("[^"]*"|\S+)',
        '$1<redacted>')
    if ($t.Length -gt $MaxLength) { $t = $t.Substring(0, $MaxLength) + '...' }
    $t
}

function Add-LcaDiagnostic {
    <#
    Records one diagnostic. -ErrorRecord adds the exception type and (unless
    -NoExceptionText) its scrubbed message. Use -NoExceptionText when the
    exception could quote the content of a config file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('info', 'warning', 'error')][string]$Level = 'warning',
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [switch]$NoExceptionText
    )
    $msg = $Message
    if ($ErrorRecord) {
        $ex = $ErrorRecord.Exception
        $msg += ' [' + $ex.GetType().Name
        if (-not $NoExceptionText) { $msg += ': ' + $ex.Message }
        $msg += ']'
    }
    $msg = Protect-LcaText -Text $msg
    $script:LcaDiagnostics.Add([pscustomobject]@{
            PSTypeName = 'ListCodingAgents.Diagnostic'
            Source     = $Source
            Level      = $Level
            Message    = $msg
        })
    Write-Verbose ("[{0}] {1}: {2}" -f $Level, $Source, $msg)
}

function Get-LcaDiagnostic {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    $script:LcaDiagnostics.ToArray()
}
