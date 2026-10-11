# agents-extra.txt / agents-exclude.txt: one command name per line, '#'
# comments. Read from next to the script (v1) and from the config directory.

function Get-LcaNameList {
    <# Union of the named list file in ScriptRoot and ConfigDir, lowercased. #>
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.HashSet[string]])]
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)][string]$FileName)
    $set = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    $dirs = @()
    if ($Context.ScriptRoot) { $dirs += $Context.ScriptRoot }
    if ($Context.ConfigDir) { $dirs += $Context.ConfigDir }
    foreach ($d in $dirs) {
        $p = Join-Path -Path $d -ChildPath $FileName
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        try {
            foreach ($raw in ((Read-LcaTextFile -Path $p) -split "`r?`n")) {
                $line = $raw.Trim()
                if ($line -and $line -notmatch '^\s*#') { [void]$set.Add($line.ToLowerInvariant()) }
            }
        } catch {
            Add-LcaDiagnostic -Source 'config' -Message "cannot read $p" -ErrorRecord $_
        }
    }
    # leading comma stops PowerShell unrolling the HashSet into loose strings -
    # without it an empty set comes back as $null and .Contains() blows up
    , $set
}
