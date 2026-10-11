# File output is always BOM-less UTF-8 with LF line endings, on every
# edition. v1 used Out-File -Encoding utf8, which writes a BOM on Windows
# PowerShell 5.1 and none on 7; Python's json and Node's JSON.parse reject
# the BOM.

function Write-LcaTextFile {
    <#
    Writes text as BOM-less UTF-8. Writes to a temp file in the same folder
    first and then moves it into place, so an interrupted run never leaves a
    half-written state file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )
    # .NET resolves relative paths against the process directory, which is
    # not the PowerShell location after a cd.
    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $dir -Force)
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    $tmp = $Path + '.' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $Content, $enc)
    try {
        if ([System.IO.File]::Exists($Path)) {
            [System.IO.File]::Replace($tmp, $Path, $null)
        } else {
            [System.IO.File]::Move($tmp, $Path)
        }
    } catch {
        # File.Replace is unsupported on some file systems; fall back to copy.
        Write-Debug "atomic replace failed for ${Path}: $($_.Exception.Message)"
        [System.IO.File]::Copy($tmp, $Path, $true)
        [System.IO.File]::Delete($tmp)
    }
}

function Read-LcaTextFile {
    <# Reads a text file (BOM or not) as UTF-8. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Path)
    [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function ConvertTo-LcaJson {
    <#
    Serializes with enough depth and without unrolling: a one-element or
    empty array stays an array (v1 wrote an object for one agent and an
    empty file for none).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$InputObject, [switch]$Compress)
    if ($null -eq $InputObject) { return 'null' }
    if (($InputObject -is [array]) -and $InputObject.Count -eq 0) { return '[]' }
    $json = ConvertTo-Json -InputObject $InputObject -Depth 12 -Compress:$Compress
    $json -replace "`r`n", "`n"
}

function ConvertFrom-LcaJson {
    <#
    Parses JSON text. Strips a UTF-8 BOM. A top-level array is emitted item
    by item on every edition (wrap the call in @() when the document is an
    array). Date-like strings stay strings where the edition allows it
    (pwsh 7.5+ -DateKind String); on 7.0-7.4 they arrive as [DateTime] - use
    ConvertTo-LcaIsoString / ConvertTo-LcaDateTimeOffset, never "$value".
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $t = $Text.TrimStart([char]0xFEFF)
    if (-not $t.Trim()) { throw 'empty JSON document' }
    $p = @{ InputObject = $t }
    if ($script:LcaJsonHasDateKind) { $p['DateKind'] = 'String' }
    ConvertFrom-Json @p
}

$script:LcaJsonHasDateKind = [bool](Get-Command -Name 'ConvertFrom-Json').Parameters.ContainsKey('DateKind')

function Get-LcaProperty {
    <#
    StrictMode-safe property read for objects from ConvertFrom-Json (missing
    properties throw under StrictMode).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([AllowNull()]$InputObject, [Parameter(Mandatory = $true)][string]$Name, [AllowNull()]$Default = $null)
    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $Default
    }
    $p = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    $p.Value
}
