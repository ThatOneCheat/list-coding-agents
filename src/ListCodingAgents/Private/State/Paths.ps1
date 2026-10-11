# Where state and config live.

function Get-LcaStateDirectory {
    <#
    Windows %LOCALAPPDATA%\list-coding-agents, macOS
    ~/Library/Application Support/list-coding-agents, Linux
    ${XDG_STATE_HOME:-~/.local/state}/list-coding-agents.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $base = $null
    switch (Get-LcaPlatform) {
        'windows' {
            $base = Get-LcaKnownFolder -Name 'LocalAppData'
            if (-not $base) {
                $h = Get-LcaKnownFolder -Name 'Home'
                if ($h) { $base = Join-Path -Path (Join-Path -Path $h -ChildPath 'AppData') -ChildPath 'Local' }
            }
        }
        'macos' { $base = Get-LcaKnownFolder -Name 'AppSupport' }
        default { $base = Get-LcaKnownFolder -Name 'XdgStateHome' }
    }
    if (-not $base) { return $null }
    Join-Path -Path $base -ChildPath 'list-coding-agents'
}

function Get-LcaConfigDirectory {
    <#
    Windows %APPDATA%\list-coding-agents, macOS
    ~/Library/Application Support/list-coding-agents, Linux
    ${XDG_CONFIG_HOME:-~/.config}/list-coding-agents.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $base = $null
    switch (Get-LcaPlatform) {
        'windows' {
            $base = Get-LcaKnownFolder -Name 'AppData'
            if (-not $base) {
                $h = Get-LcaKnownFolder -Name 'Home'
                if ($h) { $base = Join-Path -Path (Join-Path -Path $h -ChildPath 'AppData') -ChildPath 'Roaming' }
            }
        }
        'macos' { $base = Get-LcaKnownFolder -Name 'AppSupport' }
        default { $base = Get-LcaKnownFolder -Name 'XdgConfigHome' }
    }
    if (-not $base) { return $null }
    Join-Path -Path $base -ChildPath 'list-coding-agents'
}
