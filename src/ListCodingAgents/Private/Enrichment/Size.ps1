# Disk footprint (ported from v1 Get-SizeMB).

function Get-LcaSizeMB {
    <#
    Size in MB of a directory (recursive) or a single file (unrounded;
    rounding happens on display / export).
    Returns $null when the path is missing or unreadable.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param([AllowNull()][AllowEmptyString()][string]$Path)
    if (-not $Path) { return $null }
    try {
        if (Test-Path -LiteralPath $Path -PathType Container) {
            $sum = 0L
            foreach ($f in Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue) { $sum += $f.Length }
        } else {
            $sum = (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).Length
        }
        return ($sum / 1MB)
    } catch {
        Add-LcaDiagnostic -Source 'size' -Level 'info' -Message "cannot measure $Path" -ErrorRecord $_
    }
    $null
}
