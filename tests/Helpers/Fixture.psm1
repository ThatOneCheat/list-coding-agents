# Fixture builder for tests: fake HOME / APPDATA / LOCALAPPDATA / XDG trees,
# a PATH made only of fixture folders, and fake executables (agents and
# package managers alike) that are thin wrappers around
# tests/fixtures/bin/shim.ps1, which records arguments and replays canned
# output. Nothing here ever touches the real toolchain.
Set-StrictMode -Version Latest

$script:RepoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '../..')).ProviderPath
$script:ShimScript = Join-Path -Path $script:RepoRoot -ChildPath 'tests/fixtures/bin/shim.ps1'

function Test-FixtureWindows {
    [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
}

function Get-FixtureHostPath {
    <# The PowerShell executable running the tests (shims use the same one). #>
    (Get-Process -Id $PID).Path
}

function Join-FixturePath {
    param([Parameter(Mandatory = $true)][string]$Base, [Parameter(Mandatory = $true)][string]$Relative)
    $p = $Base
    foreach ($seg in ($Relative -split '[\\/]')) { if ($seg) { $p = Join-Path -Path $p -ChildPath $seg } }
    $p
}

function New-LcaFixture {
    <#
    Creates an isolated machine image under -Root and returns
    { Root, Home, AppData, LocalAppData, XdgConfig, XdgData, XdgState, XdgCache,
      Bin, NpmRoot, NpmBin, PathDirs (List), ShimData, ShimLog, Now }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root, [string]$Now = '2026-10-11T12:00:00+00:00')
    $win = Test-FixtureWindows
    $homeDir = Join-Path -Path $Root -ChildPath 'home'
    $fx = [pscustomobject]@{
        Root         = $Root
        Home         = $homeDir
        AppData      = (Join-FixturePath -Base $homeDir -Relative 'AppData/Roaming')
        LocalAppData = (Join-FixturePath -Base $homeDir -Relative 'AppData/Local')
        XdgConfig    = (Join-FixturePath -Base $homeDir -Relative '.config')
        XdgData      = (Join-FixturePath -Base $homeDir -Relative '.local/share')
        XdgState     = (Join-FixturePath -Base $homeDir -Relative '.local/state')
        XdgCache     = (Join-FixturePath -Base $homeDir -Relative '.cache')
        Bin          = (Join-Path -Path $Root -ChildPath 'bin')
        NpmRoot      = $null
        NpmBin       = $null
        PathDirs     = (New-Object System.Collections.Generic.List[string])
        ShimData     = (Join-Path -Path $Root -ChildPath 'shimdata')
        ShimLog      = (Join-Path -Path $Root -ChildPath 'shim.log')
        Now          = $Now
        Windows      = $win
    }
    if ($win) {
        $fx.NpmBin = Join-Path -Path $fx.AppData -ChildPath 'npm'
        $fx.NpmRoot = Join-Path -Path $fx.NpmBin -ChildPath 'node_modules'
    } else {
        $fx.NpmBin = Join-FixturePath -Base $homeDir -Relative '.npm-global/bin'
        $fx.NpmRoot = Join-FixturePath -Base $homeDir -Relative '.npm-global/lib/node_modules'
    }
    foreach ($d in @($fx.Home, $fx.AppData, $fx.LocalAppData, $fx.XdgConfig, $fx.XdgData, $fx.XdgState, $fx.XdgCache, $fx.Bin, $fx.ShimData, $fx.NpmBin, $fx.NpmRoot)) {
        [void](New-Item -ItemType Directory -Path $d -Force)
    }
    $fx.PathDirs.Add($fx.NpmBin)
    $fx.PathDirs.Add($fx.Bin)
    $fx
}

function Add-LcaFixturePathDir {
    <# Adds a folder (created if needed) to the end of the fixture PATH. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Fixture, [Parameter(Mandatory = $true)][string]$Path, [switch]$First)
    [void](New-Item -ItemType Directory -Path $Path -Force)
    if ($Fixture.PathDirs.Contains($Path)) { return $Path }
    if ($First) { $Fixture.PathDirs.Insert(0, $Path) } else { $Fixture.PathDirs.Add($Path) }
    $Path
}

function Set-LcaShimResponse {
    <#
    Canned response for `<Tool> <Arguments>`. Use -Arguments '*' for the
    fallback. StdOut/StdErr are written verbatim.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Fixture,
        [Parameter(Mandatory = $true)][string]$Tool,
        [AllowEmptyString()][string]$Arguments = '*',
        [AllowEmptyString()][string]$StdOut = '',
        [AllowEmptyString()][string]$StdErr = '',
        [int]$ExitCode = 0,
        [double]$SleepSec = 0
    )
    $file = Join-Path -Path $Fixture.ShimData -ChildPath ($Tool + '.json')
    $map = [ordered]@{}
    if (Test-Path -LiteralPath $file) {
        $old = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($file))
        foreach ($p in $old.PSObject.Properties) { $map[$p.Name] = $p.Value }
    }
    $map[$Arguments] = [ordered]@{ stdout = $StdOut; stderr = $StdErr; exitCode = $ExitCode; sleepSec = $SleepSec }
    [System.IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject $map -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
}

function New-LcaShim {
    <#
    Creates an executable named -Name in -Dir that runs the shim. On Windows
    it is <Name>.cmd; elsewhere an executable sh script. Returns its path.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Fixture, [Parameter(Mandatory = $true)][string]$Name, [string]$Dir)
    if (-not $Dir) { $Dir = $Fixture.Bin }
    [void](New-Item -ItemType Directory -Path $Dir -Force)
    $hostExe = Get-FixtureHostPath
    if ($Fixture.Windows) {
        $p = Join-Path -Path $Dir -ChildPath ($Name + '.cmd')
        $body = '@"' + $hostExe + '" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $script:ShimScript + '" ' + $Name + " %*`r`n"
        [System.IO.File]::WriteAllText($p, $body, (New-Object System.Text.UTF8Encoding($false)))
    } else {
        $p = Join-Path -Path $Dir -ChildPath $Name
        $body = "#!/bin/sh`nexec '" + $hostExe + "' -NoLogo -NoProfile -NonInteractive -File '" + $script:ShimScript + "' '" + $Name + "' `"`$@`"`n"
        [System.IO.File]::WriteAllText($p, $body, (New-Object System.Text.UTF8Encoding($false)))
        & chmod 755 $p
    }
    $p
}

function New-LcaFixtureCommand {
    <#
    A fake agent (or any) command on the fixture PATH whose `--version`
    prints -VersionOutput. Returns the created path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Fixture,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Dir,
        [string]$VersionOutput,
        [string]$VersionStdErr = '',
        [double]$SleepSec = 0
    )
    $p = New-LcaShim -Fixture $Fixture -Name $Name -Dir $Dir
    if ($PSBoundParameters.ContainsKey('VersionOutput') -or $VersionStdErr -or $SleepSec) {
        Set-LcaShimResponse -Fixture $Fixture -Tool $Name -Arguments '--version' -StdOut ([string]$VersionOutput) -StdErr $VersionStdErr -SleepSec $SleepSec
    }
    $p
}

function Add-LcaFixtureNpmPackage {
    <#
    A globally installed npm package: <npm root>/<name>/package.json plus a
    bin wrapper per command in the npm bin folder. Also makes `npm root -g`
    answer with the fixture npm root.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Fixture,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Version = '1.0.0',
        [string]$Description = '',
        [string[]]$Keywords = @(),
        [hashtable]$Bin = @{},
        [string[]]$Dependencies = @(),
        [string]$VersionOutput
    )
    $dir = $Fixture.NpmRoot
    foreach ($seg in $Name.Split('/')) { $dir = Join-Path -Path $dir -ChildPath $seg }
    [void](New-Item -ItemType Directory -Path $dir -Force)
    $deps = [ordered]@{}
    foreach ($d in $Dependencies) { $deps[$d] = '^1.0.0' }
    $pj = [ordered]@{ name = $Name; version = $Version; description = $Description; keywords = @($Keywords); bin = $Bin; dependencies = $deps }
    [System.IO.File]::WriteAllText((Join-Path -Path $dir -ChildPath 'package.json'), (ConvertTo-Json -InputObject $pj -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    foreach ($k in $Bin.Keys) {
        $binFile = Join-FixturePath -Base $dir -Relative $Bin[$k]
        [void](New-Item -ItemType Directory -Path (Split-Path -Path $binFile -Parent) -Force)
        [System.IO.File]::WriteAllText($binFile, "// fake`n")
        if ($PSBoundParameters.ContainsKey('VersionOutput')) {
            [void](New-LcaFixtureCommand -Fixture $Fixture -Name $k -Dir $Fixture.NpmBin -VersionOutput $VersionOutput)
        } else {
            [void](New-LcaShim -Fixture $Fixture -Name $k -Dir $Fixture.NpmBin)
        }
    }
    Enable-LcaFixtureNpm -Fixture $Fixture
    $dir
}

function Enable-LcaFixtureNpm {
    <# Puts a fake npm on PATH that knows the fixture's global root. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Fixture)
    $npmShim = New-LcaShim -Fixture $Fixture -Name 'npm'
    Set-LcaShimResponse -Fixture $Fixture -Tool 'npm' -Arguments 'root -g' -StdOut ($Fixture.NpmRoot + "`n")
    $npmShim
}

function Get-LcaFixtureEnvironment {
    <# Environment variables that make a process see the fixture machine. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Fixture)
    $sep = [System.IO.Path]::PathSeparator
    $dirs = New-Object System.Collections.Generic.List[string]
    foreach ($d in $Fixture.PathDirs) { $dirs.Add($d) }
    if ($Fixture.Windows -and $env:WINDIR) {
        # cmd.exe / taskkill live here; the scanner skips %WINDIR% itself.
        $dirs.Add((Join-Path -Path $env:WINDIR -ChildPath 'System32'))
    }
    @{
        HOME            = $Fixture.Home
        USERPROFILE     = $Fixture.Home
        APPDATA         = $Fixture.AppData
        LOCALAPPDATA    = $Fixture.LocalAppData
        XDG_CONFIG_HOME = $Fixture.XdgConfig
        XDG_DATA_HOME   = $Fixture.XdgData
        XDG_STATE_HOME  = $Fixture.XdgState
        XDG_CACHE_HOME  = $Fixture.XdgCache
        PATH            = ($dirs -join $sep)
        LCA_SHIM_DATA   = $Fixture.ShimData
        LCA_SHIM_LOG    = $Fixture.ShimLog
        LCA_FAKE_NOW    = $Fixture.Now
        NO_COLOR        = '1'
    }
}

function Use-LcaFixture {
    <#
    Runs -ScriptBlock with the fixture environment applied to THIS process,
    then restores every variable.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Fixture, [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock)
    $envMap = Get-LcaFixtureEnvironment -Fixture $Fixture
    $saved = @{}
    foreach ($k in $envMap.Keys) {
        $saved[$k] = [System.Environment]::GetEnvironmentVariable($k)
        [System.Environment]::SetEnvironmentVariable($k, [string]$envMap[$k])
    }
    try { & $ScriptBlock } finally {
        foreach ($k in $saved.Keys) { [System.Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
}

function Invoke-LcaFixtureScript {
    <#
    Runs a script file in a child PowerShell with the fixture environment.
    -AsScriptBlock loads the file's TEXT and runs it as a script block, the
    way "irm <url> | iex" users run it (no $PSScriptRoot).
    Returns { ExitCode, StdOut, StdErr }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Fixture,
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$ArgumentList = @(),
        [switch]$AsScriptBlock,
        [string]$WorkingDirectory,
        [double]$TimeoutSec = 300
    )
    $hostExe = Get-FixtureHostPath
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $hostExe
    $quote = {
        param($a)
        if ($a -notmatch '[\s"]' -and $a.Length) { return $a }
        '"' + ($a -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
    }
    if ($AsScriptBlock) {
        # parameter names stay bare; values are single-quoted literals
        $argText = ($ArgumentList | ForEach-Object {
                if ($_ -match '^-[A-Za-z]+$') { $_ } else { "'" + ($_ -replace "'", "''") + "'" }
            }) -join ' '
        $cmd = '$t = [System.IO.File]::ReadAllText(''' + ($Path -replace "'", "''") + '''); & ([scriptblock]::Create($t)) ' + $argText + '; exit $LASTEXITCODE'
        $psi.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command ' + (& $quote $cmd)
    } else {
        $psi.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + (& $quote $Path) + ' ' + (($ArgumentList | ForEach-Object { & $quote $_ }) -join ' ')
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory } else { $psi.WorkingDirectory = $Fixture.Root }
    $envMap = Get-LcaFixtureEnvironment -Fixture $Fixture
    foreach ($k in $envMap.Keys) { $psi.EnvironmentVariables[$k] = [string]$envMap[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $o = $p.StandardOutput.ReadToEndAsync()
    $e = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit([int]($TimeoutSec * 1000))) { $p.Kill(); throw "fixture script timed out: $Path" }
    $p.WaitForExit()
    [pscustomobject]@{ ExitCode = $p.ExitCode; StdOut = $o.Result; StdErr = $e.Result }
}

function Get-LcaShimLog {
    <# Every recorded shim call as { tool, args }. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Fixture)
    if (-not (Test-Path -LiteralPath $Fixture.ShimLog)) { return @() }
    foreach ($l in [System.IO.File]::ReadAllLines($Fixture.ShimLog)) {
        if ($l.Trim()) { ConvertFrom-Json -InputObject $l }
    }
}

function Get-LcaRepoRoot { $script:RepoRoot }

Export-ModuleMember -Function New-LcaFixture, Add-LcaFixturePathDir, Set-LcaShimResponse, New-LcaShim, New-LcaFixtureCommand,
    Add-LcaFixtureNpmPackage, Enable-LcaFixtureNpm, Get-LcaFixtureEnvironment, Use-LcaFixture, Invoke-LcaFixtureScript,
    Get-LcaShimLog, Get-LcaRepoRoot, Join-FixturePath
