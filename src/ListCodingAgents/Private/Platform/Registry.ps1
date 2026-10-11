# Provider seam: Windows registry and PE version info. Both switch off
# cleanly on macOS/Linux (they return nothing).

function Get-LcaUninstallEntry {
    <#
    Reads the Windows Uninstall keys (HKCU, HKLM, HKLM WOW6432Node) and returns
    { DisplayName, DisplayVersion, Publisher, InstallLocation, EstimatedSizeKB,
      UninstallString, QuietUninstallString, KeyName, Hive }.
    Returns an empty array on other platforms.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param()
    if (-not (Test-LcaWindows)) { return @() }
    $roots = @(
        @('HKCU', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'),
        @('HKLM', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall'),
        @('HKLM32', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
    )
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($r in $roots) {
        $keys = @()
        try { $keys = @(Get-ChildItem -LiteralPath $r[1] -ErrorAction Stop) } catch {
            Write-Debug "registry read failed: $($r[1]) - $($_.Exception.Message)"
            continue
        }
        foreach ($k in $keys) {
            $p = $null
            try { $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Stop } catch {
                Write-Debug "registry value read failed: $($k.PSPath)"
                continue
            }
            $names = @($p.PSObject.Properties | ForEach-Object { $_.Name })
            if ($names -notcontains 'DisplayName' -or -not $p.DisplayName) { continue }
            $get = {
                param($n)
                if ($names -contains $n) { return $p.$n }
                $null
            }
            $size = & $get 'EstimatedSize'
            $out.Add([pscustomobject]@{
                    DisplayName          = [string]$p.DisplayName
                    DisplayVersion       = [string](& $get 'DisplayVersion')
                    Publisher            = [string](& $get 'Publisher')
                    InstallLocation      = [string](& $get 'InstallLocation')
                    EstimatedSizeKB      = $(if ($null -ne $size) { [long]$size } else { $null })
                    UninstallString      = [string](& $get 'UninstallString')
                    QuietUninstallString = [string](& $get 'QuietUninstallString')
                    KeyName              = [string]$k.PSChildName
                    Hive                 = $r[0]
                })
        }
    }
    $out.ToArray()
}

function Get-LcaFileVersionInfo {
    <#
    Embedded version-info of an executable (CompanyName, ProductName,
    FileDescription, ProductVersion, FileVersion). Only meaningful for
    Windows PE files; returns $null for anything else.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($Path -notmatch '(?i)\.exe$') { return $null }
    try {
        $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        [pscustomobject]@{
            CompanyName     = [string]$vi.CompanyName
            ProductName     = [string]$vi.ProductName
            FileDescription = [string]$vi.FileDescription
            ProductVersion  = [string]$vi.ProductVersion
            FileVersion     = [string]$vi.FileVersion
        }
    } catch {
        Write-Debug "version info failed for ${Path}: $($_.Exception.Message)"
        $null
    }
}
