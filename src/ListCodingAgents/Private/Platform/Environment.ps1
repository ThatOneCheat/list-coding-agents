# Provider seam: platform, environment, filesystem roots, clock.
# Every scanner reads the outside world through these small functions so tests
# can mock them. Nothing else in the module reads $env:, calls Get-Date or
# touches $IsWindows (which does not exist on Windows PowerShell 5.1 and throws
# under StrictMode).

function Get-LcaPlatform {
    <# Returns 'windows', 'macos' or 'linux'. #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { return 'windows' }
    $isMac = Get-Variable -Name 'IsMacOS' -ValueOnly -ErrorAction Ignore
    if ($isMac) { return 'macos' }
    'linux'
}

function Test-LcaWindows {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    (Get-LcaPlatform) -eq 'windows'
}

function Test-LcaDesktopEdition {
    <# True on Windows PowerShell 5.1 (.NET Framework). #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $PSVersionTable.PSEdition -ne 'Core'
}

function Get-LcaEnvironmentVariable {
    <# Reads one environment variable. Empty values come back as $null. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Name)
    $v = [System.Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrEmpty($v)) { return $null }
    $v
}

function Split-LcaPathList {
    <#
    Splits a PATH-style list. Entries are trimmed, unquoted, env-expanded
    (Windows), stripped of trailing separators - but a drive root stays
    "C:\" (v1's TrimEnd turned it into the drive-relative "C:") - and
    de-duplicated in order (case-insensitively on Windows).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory = $true)][char]$Separator,
        [bool]$Windows
    )
    if (-not $Value) { return @() }
    $cmp = [StringComparer]::Ordinal
    if ($Windows) { $cmp = [StringComparer]::OrdinalIgnoreCase }
    $seen = New-Object System.Collections.Generic.HashSet[string] ($cmp)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($part in $Value.Split($Separator)) {
        $p = $part.Trim().Trim('"')
        if (-not $p) { continue }
        if ($Windows -and $p.Contains('%')) { $p = [System.Environment]::ExpandEnvironmentVariables($p) }
        if ($p.Length -gt 1) {
            $trimmed = $p.TrimEnd('\', '/')
            if ($trimmed -match '^[A-Za-z]:$') { $p = $trimmed + '\' }
            elseif ($trimmed) { $p = $trimmed }
        }
        if ($seen.Add($p)) { $out.Add($p) }
    }
    $out.ToArray()
}

function Get-LcaPathEntry {
    <#
    The PATH, split on the platform separator (';' on Windows, ':' elsewhere -
    v1 always split on ';', which found nothing on Linux/macOS).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    Split-LcaPathList -Value (Get-LcaEnvironmentVariable -Name 'PATH') -Separator ([System.IO.Path]::PathSeparator) -Windows (Test-LcaWindows)
}

function Get-LcaKnownFolder {
    <#
    Filesystem roots. Windows values come from the environment (USERPROFILE,
    APPDATA, LOCALAPPDATA) so fixtures can redirect them; XDG roots honour the
    XDG_* variables (absolute paths only, per the spec) and fall back to the
    spec defaults. Returns $null when a root does not apply to the platform.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Home', 'AppData', 'LocalAppData', 'XdgConfigHome', 'XdgDataHome', 'XdgStateHome',
            'XdgCacheHome', 'AppSupport', 'WinDir', 'ProgramFiles', 'ProgramFilesX86', 'ProgramData', 'Temp')]
        [string]$Name
    )
    $platform = Get-LcaPlatform
    $homeDir = $null
    if ($platform -eq 'windows') { $homeDir = Get-LcaEnvironmentVariable -Name 'USERPROFILE' }
    if (-not $homeDir) { $homeDir = Get-LcaEnvironmentVariable -Name 'HOME' }
    if (-not $homeDir) { $homeDir = [System.Environment]::GetFolderPath('UserProfile') }

    switch ($Name) {
        'Home' { return $homeDir }
        'AppData' { if ($platform -eq 'windows') { return (Get-LcaEnvironmentVariable -Name 'APPDATA') }; return $null }
        'LocalAppData' { if ($platform -eq 'windows') { return (Get-LcaEnvironmentVariable -Name 'LOCALAPPDATA') }; return $null }
        'WinDir' { if ($platform -eq 'windows') { return (Get-LcaEnvironmentVariable -Name 'WINDIR') }; return $null }
        'ProgramFiles' { if ($platform -eq 'windows') { return (Get-LcaEnvironmentVariable -Name 'ProgramFiles') }; return $null }
        'ProgramFilesX86' { if ($platform -eq 'windows') { return (Get-LcaEnvironmentVariable -Name 'ProgramFiles(x86)') }; return $null }
        'ProgramData' { if ($platform -eq 'windows') { return (Get-LcaEnvironmentVariable -Name 'ProgramData') }; return $null }
        'AppSupport' {
            if ($platform -eq 'macos' -and $homeDir) { return (Join-Path -Path (Join-Path -Path $homeDir -ChildPath 'Library') -ChildPath 'Application Support') }
            return $null
        }
        'Temp' { return [System.IO.Path]::GetTempPath() }
    }

    # XDG roots
    $map = @{
        XdgConfigHome = @('XDG_CONFIG_HOME', '.config')
        XdgDataHome   = @('XDG_DATA_HOME', '.local/share')
        XdgStateHome  = @('XDG_STATE_HOME', '.local/state')
        XdgCacheHome  = @('XDG_CACHE_HOME', '.cache')
    }
    $spec = $map[$Name]
    $v = Get-LcaEnvironmentVariable -Name $spec[0]
    if ($v -and [System.IO.Path]::IsPathRooted($v)) { return $v }
    if ($platform -eq 'windows' -or -not $homeDir) { return $null }
    $rel = $spec[1]
    $acc = $homeDir
    foreach ($seg in $rel.Split('/')) { $acc = Join-Path -Path $acc -ChildPath $seg }
    $acc
}

function Get-LcaNow {
    <#
    The clock seam. LCA_FAKE_NOW (ISO 8601) pins the clock for fixture runs and
    screenshot generation; it is never set in normal use.
    #>
    [CmdletBinding()]
    [OutputType([System.DateTimeOffset])]
    param()
    $fake = Get-LcaEnvironmentVariable -Name 'LCA_FAKE_NOW'
    if ($fake) {
        $parsed = [System.DateTimeOffset]::MinValue
        if ([System.DateTimeOffset]::TryParse($fake, [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
            return $parsed
        }
    }
    [System.DateTimeOffset]::Now
}

function Get-LcaHostName {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $n = Get-LcaEnvironmentVariable -Name 'COMPUTERNAME'
    if (-not $n) { $n = Get-LcaEnvironmentVariable -Name 'HOSTNAME' }
    if (-not $n) {
        try { $n = [System.Net.Dns]::GetHostName() } catch { $n = $null }
    }
    $n
}

function Get-LcaUserName {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $n = Get-LcaEnvironmentVariable -Name 'USERNAME'
    if (-not $n) { $n = Get-LcaEnvironmentVariable -Name 'USER' }
    if (-not $n) {
        $homeDir = Get-LcaKnownFolder -Name 'Home'
        if ($homeDir) { $n = Split-Path -Path $homeDir -Leaf }
    }
    $n
}
