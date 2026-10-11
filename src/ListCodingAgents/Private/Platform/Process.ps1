# Provider seam: running external programs (package managers, winget,
# --version probes). Uses System.Diagnostics.Process directly instead of
# Start-Job (one full PowerShell process per probe in v1): stdin is closed,
# stdout AND stderr are captured (some CLIs print their version on stderr),
# CI=1 / NO_COLOR=1 / TERM=dumb keep tools non-interactive and plain, and a
# hard timeout kills the whole process tree.

function ConvertTo-LcaArgumentString {
    <#
    Joins arguments into one command line using the MSVCRT/CommandLineToArgvW
    quoting rules. .NET applies the same rules when it splits
    ProcessStartInfo.Arguments on Linux/macOS, so one code path serves every
    platform (ProcessStartInfo.ArgumentList does not exist on .NET Framework).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyCollection()][AllowNull()][string[]]$ArgumentList)
    if ($null -eq $ArgumentList -or $ArgumentList.Count -eq 0) { return '' }
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($a in $ArgumentList) {
        if ($null -eq $a) { $a = '' }
        if ($a.Length -gt 0 -and $a -notmatch '[\s"]') { $parts.Add($a); continue }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('"')
        $bs = 0
        foreach ($ch in $a.ToCharArray()) {
            if ($ch -eq [char]'\') { $bs++; continue }
            if ($ch -eq [char]'"') {
                [void]$sb.Append([char]'\', (2 * $bs) + 1)
                [void]$sb.Append([char]'"')
                $bs = 0
                continue
            }
            if ($bs -gt 0) { [void]$sb.Append([char]'\', $bs); $bs = 0 }
            [void]$sb.Append($ch)
        }
        if ($bs -gt 0) { [void]$sb.Append([char]'\', 2 * $bs) }
        [void]$sb.Append('"')
        $parts.Add($sb.ToString())
    }
    $parts -join ' '
}

function Test-LcaSafeBatchArgument {
    <#
    cmd.exe re-parses the command line of a .cmd/.bat file, so quoting alone
    cannot make arbitrary arguments safe there. Only plain tokens (package
    names, ids, versions, flags) are allowed through.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyCollection()][AllowNull()][string[]]$ArgumentList)
    foreach ($a in @($ArgumentList)) {
        if ($null -eq $a) { continue }
        if ($a -match '[\r\n"&|<>^%!()`]') { return $false }
    }
    $true
}

function Test-LcaUnixExecutable {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $mode = [System.IO.File]::GetUnixFileMode($Path)
        return (([int]$mode -band 73) -ne 0)   # 73 = UserExecute|GroupExecute|OtherExecute (0o111)
    } catch {
        Write-Debug "unix mode check failed for ${Path}: $($_.Exception.Message)"
        return $true
    }
}

function Get-LcaPowerShellPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (Test-LcaDesktopEdition) { return (Join-Path -Path $PSHOME -ChildPath 'powershell.exe') }
    $name = 'pwsh'
    if (Test-LcaWindows) { $name = 'pwsh.exe' }
    Join-Path -Path $PSHOME -ChildPath $name
}

function Find-LcaExecutable {
    <#
    Resolves a command name against PATH (and PATHEXT on Windows) through the
    seam, so fixtures can put fake npm/winget/... shims first on PATH.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Name)
    $win = Test-LcaWindows
    if ([System.IO.Path]::IsPathRooted($Name)) {
        if ([System.IO.File]::Exists($Name)) { return $Name }
        return $null
    }
    $exts = @('')
    if ($win) {
        $pathext = Get-LcaEnvironmentVariable -Name 'PATHEXT'
        if (-not $pathext) { $pathext = '.COM;.EXE;.BAT;.CMD' }
        $exts = @($pathext.Split(';') | Where-Object { $_ })
        if ([System.IO.Path]::GetExtension($Name)) { $exts = @('') + $exts }
    }
    foreach ($dir in Get-LcaPathEntry) {
        # Stale PATH entries (missing folders, unmapped drives) are common;
        # Join-Path would throw DriveNotFound for them.
        if (-not [System.IO.Directory]::Exists($dir)) { continue }
        foreach ($e in $exts) {
            $cand = [System.IO.Path]::Combine($dir, $Name + $e)
            if (-not [System.IO.File]::Exists($cand)) { continue }
            if ($win -or (Test-LcaUnixExecutable -Path $cand)) { return $cand }
        }
    }
    $null
}

function Open-LcaProcess {
    <#
    Starts a process and returns a handle without waiting, so slow queries
    (winget, brew, npm) can run while the PATH scan proceeds. Collect the
    result with Wait-LcaProcess. Never throws: a failed start is recorded on
    the handle.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [AllowEmptyCollection()][string[]]$ArgumentList = @(),
        [string]$WorkingDirectory,
        [hashtable]$Environment,
        [System.Text.Encoding]$Encoding
    )
    $handle = [pscustomobject]@{
        PSTypeName   = 'ListCodingAgents.ProcessHandle'
        FilePath     = $FilePath
        ArgumentList = @($ArgumentList)
        Process      = $null
        OutTask      = $null
        ErrTask      = $null
        Error        = $null
        Started      = [System.Diagnostics.Stopwatch]::StartNew()
    }
    try {
        $exe = $FilePath
        if (-not [System.IO.Path]::IsPathRooted($exe)) {
            $found = Find-LcaExecutable -Name $exe
            if (-not $found) { throw "command not found: $FilePath" }
            $exe = $found
        }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $argString = ConvertTo-LcaArgumentString -ArgumentList $ArgumentList
        $ext = [System.IO.Path]::GetExtension($exe).ToLowerInvariant()
        if ((Test-LcaWindows) -and ($ext -eq '.cmd' -or $ext -eq '.bat')) {
            # The quoted batch path may contain spaces and parentheses
            # ("Program Files (x86)") but nothing cmd.exe expands inside quotes.
            if ($exe -match '[\r\n"&|<>^%!]' -or -not (Test-LcaSafeBatchArgument -ArgumentList $ArgumentList)) {
                throw "refusing to pass shell metacharacters to batch file $exe"
            }
            $comspec = Get-LcaEnvironmentVariable -Name 'ComSpec'
            if (-not $comspec) { $comspec = 'cmd.exe' }
            $psi.FileName = $comspec
            # /s strips the outer quotes; the batch path itself is always quoted.
            $psi.Arguments = '/d /s /c ""' + $exe + '" ' + $argString + '"'
        } elseif ($ext -eq '.ps1') {
            $psi.FileName = Get-LcaPowerShellPath
            $psi.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
                (ConvertTo-LcaArgumentString -ArgumentList @($exe)) + ' ' + $argString
        } else {
            $psi.FileName = $exe
            $psi.Arguments = $argString
        }
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $enc = $Encoding
        if (-not $enc) { $enc = New-Object System.Text.UTF8Encoding($false) }
        $psi.StandardOutputEncoding = $enc
        $psi.StandardErrorEncoding = $enc
        if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
        $psi.EnvironmentVariables['CI'] = '1'
        $psi.EnvironmentVariables['NO_COLOR'] = '1'
        $psi.EnvironmentVariables['TERM'] = 'dumb'
        $psi.EnvironmentVariables['NO_UPDATE_NOTIFIER'] = '1'
        # Python tools (pip, pipx, uv shims) print in the locale code page otherwise.
        $psi.EnvironmentVariables['PYTHONUTF8'] = '1'
        $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
        if ($Environment) {
            foreach ($k in $Environment.Keys) { $psi.EnvironmentVariables[[string]$k] = [string]$Environment[$k] }
        }
        $p = [System.Diagnostics.Process]::Start($psi)
        $handle.Process = $p
        # Close stdin so a CLI waiting for input sees EOF. On .NET Framework the
        # stdin writer would emit a UTF-8 BOM on close (Console.InputEncoding),
        # so close the raw stream there instead of the writer.
        try {
            if (Test-LcaDesktopEdition) { $p.StandardInput.BaseStream.Close() } else { $p.StandardInput.Close() }
        } catch { Write-Debug "stdin close failed: $($_.Exception.Message)" }
        $handle.OutTask = $p.StandardOutput.ReadToEndAsync()
        $handle.ErrTask = $p.StandardError.ReadToEndAsync()
    } catch {
        $handle.Error = $_.Exception.Message
        Write-Verbose "process start failed: $FilePath - $($handle.Error)"
    }
    $handle
}

function Stop-LcaProcessTree {
    <# Kills a process this module started, including its children. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Internal: only ever kills a child process this module started, after its timeout.')]
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process)
    try { if ($Process.HasExited) { return } } catch { Write-Debug "HasExited failed: $($_.Exception.Message)" }
    # .NET Core 3.0+ has Kill(bool entireProcessTree); .NET Framework does not.
    $killTree = $Process.GetType().GetMethod('Kill', [type[]]@([bool]))
    if ($killTree) {
        try { [void]$killTree.Invoke($Process, @($true)); return } catch { Write-Debug "Kill(true) failed: $($_.Exception.Message)" }
    }
    if (Test-LcaWindows) {
        try {
            $tk = New-Object System.Diagnostics.ProcessStartInfo
            $tk.FileName = 'taskkill.exe'
            $winDir = Get-LcaKnownFolder -Name 'WinDir'
            if ($winDir) { $tk.FileName = [System.IO.Path]::Combine($winDir, 'System32', 'taskkill.exe') }
            $tk.Arguments = '/PID ' + $Process.Id + ' /T /F'
            $tk.UseShellExecute = $false
            $tk.CreateNoWindow = $true
            $tk.RedirectStandardOutput = $true
            $tk.RedirectStandardError = $true
            $k = [System.Diagnostics.Process]::Start($tk)
            [void]$k.WaitForExit(5000)
            if ($k.HasExited -and $k.ExitCode -eq 0) { return }
            Write-Debug ("taskkill exit code {0}" -f $k.ExitCode)
        } catch { Write-Debug "taskkill failed: $($_.Exception.Message)" }
    }
    try { $Process.Kill() } catch { Write-Debug "Kill() failed: $($_.Exception.Message)" }
}

function Wait-LcaProcess {
    <#
    Waits for a handle from Open-LcaProcess up to the timeout (measured from
    when it started) and returns
    { ExitCode, StdOut, StdErr, TimedOut, Failed, Error, DurationMs }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]$Handle,
        [double]$TimeoutSec = 30
    )
    $res = [pscustomobject]@{
        PSTypeName = 'ListCodingAgents.ProcessResult'
        FilePath   = $Handle.FilePath
        ExitCode   = $null
        StdOut     = ''
        StdErr     = ''
        TimedOut   = $false
        Failed     = $false
        Error      = $null
        DurationMs = 0
    }
    if ($Handle.Error -or -not $Handle.Process) {
        $res.Failed = $true
        $res.Error = $Handle.Error
        $res.DurationMs = [int]$Handle.Started.ElapsedMilliseconds
        return $res
    }
    $p = $Handle.Process
    try {
        $remaining = [int][Math]::Max(1, ($TimeoutSec * 1000) - $Handle.Started.ElapsedMilliseconds)
        $pipeWait = 5000
        if (-not $p.WaitForExit($remaining)) {
            $res.TimedOut = $true
            $res.Failed = $true
            $res.Error = ('timed out after {0}s' -f $TimeoutSec)
            Stop-LcaProcessTree -Process $p
            [void]$p.WaitForExit(3000)
            $pipeWait = 1000
        }
        # Grandchildren can keep the pipes open after a kill; never wait forever.
        if ($Handle.OutTask -and $Handle.OutTask.Wait($pipeWait)) { $res.StdOut = [string]$Handle.OutTask.Result }
        if ($Handle.ErrTask -and $Handle.ErrTask.Wait([Math]::Min($pipeWait, 2000))) { $res.StdErr = [string]$Handle.ErrTask.Result }
        if ($p.HasExited) { $res.ExitCode = $p.ExitCode }
        if (-not $res.TimedOut -and $null -ne $res.ExitCode -and $res.ExitCode -ne 0) {
            $res.Failed = $true
            $res.Error = ('exit code {0}' -f $res.ExitCode)
        }
    } catch {
        $res.Failed = $true
        $res.Error = $_.Exception.Message
        Write-Verbose "process wait failed: $($Handle.FilePath) - $($res.Error)"
    } finally {
        try { $p.Dispose() } catch { Write-Debug "dispose failed: $($_.Exception.Message)" }
    }
    $res.DurationMs = [int]$Handle.Started.ElapsedMilliseconds
    $res
}

function Invoke-LcaProcess {
    <# Runs a program to completion (or timeout). See Open-LcaProcess. #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [AllowEmptyCollection()][string[]]$ArgumentList = @(),
        [double]$TimeoutSec = 30,
        [string]$WorkingDirectory,
        [hashtable]$Environment,
        [System.Text.Encoding]$Encoding
    )
    $h = Open-LcaProcess -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory -Environment $Environment -Encoding $Encoding
    Wait-LcaProcess -Handle $h -TimeoutSec $TimeoutSec
}

function Split-LcaCommandLine {
    <#
    Splits a Windows command line (e.g. a registry UninstallString) into
    tokens with the CommandLineToArgvW rules: the first token is the program
    (quoted or not), later tokens follow the MSVCRT backslash/quote rules.
    Returns $null for an empty string.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()][AllowEmptyString()][string]$CommandLine)
    if (-not $CommandLine -or -not $CommandLine.Trim()) { return $null }
    $s = $CommandLine.Trim()
    $tokens = New-Object System.Collections.Generic.List[string]
    $i = 0
    # program name: quoted -> up to the next quote; else up to whitespace
    if ($s[0] -eq [char]'"') {
        $end = $s.IndexOf([char]'"', 1)
        if ($end -lt 0) { $end = $s.Length }
        $tokens.Add($s.Substring(1, $end - 1))
        $i = $end + 1
    } else {
        while ($i -lt $s.Length -and -not [char]::IsWhiteSpace($s[$i])) { $i++ }
        $tokens.Add($s.Substring(0, $i))
    }
    $cur = New-Object System.Text.StringBuilder
    $inQuote = $false
    $have = $false
    while ($i -lt $s.Length) {
        $ch = $s[$i]
        if ([char]::IsWhiteSpace($ch) -and -not $inQuote) {
            if ($have) { $tokens.Add($cur.ToString()); [void]$cur.Clear(); $have = $false }
            $i++
            continue
        }
        if ($ch -eq [char]'\') {
            $n = 0
            while ($i -lt $s.Length -and $s[$i] -eq [char]'\') { $n++; $i++ }
            if ($i -lt $s.Length -and $s[$i] -eq [char]'"') {
                [void]$cur.Append([char]'\', [int][Math]::Floor($n / 2))
                if ($n % 2 -eq 1) { [void]$cur.Append([char]'"'); $i++ }
            } else {
                [void]$cur.Append([char]'\', $n)
            }
            $have = $true
            continue
        }
        if ($ch -eq [char]'"') {
            if ($inQuote -and ($i + 1) -lt $s.Length -and $s[$i + 1] -eq [char]'"') {
                [void]$cur.Append([char]'"'); $i += 2; $have = $true; continue
            }
            $inQuote = -not $inQuote
            $have = $true
            $i++
            continue
        }
        [void]$cur.Append($ch)
        $have = $true
        $i++
    }
    if ($have) { $tokens.Add($cur.ToString()) }
    $tokens.ToArray()
}

function Open-LcaFile {
    <#
    Opens a file with the platform's default handler (the HTML report in the
    browser). Never fatal, never inherits our pipes, never waits.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        switch (Get-LcaPlatform) {
            'windows' { Invoke-Item -LiteralPath $Path }
            default {
                $opener = 'xdg-open'
                if ((Get-LcaPlatform) -eq 'macos') { $opener = 'open' }
                $exe = Find-LcaExecutable -Name $opener
                if (-not $exe) {
                    Add-LcaDiagnostic -Source 'report' -Level 'info' -Message "no $opener to open $Path"
                    return
                }
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = $exe
                $psi.Arguments = ConvertTo-LcaArgumentString -ArgumentList @($Path)
                $psi.UseShellExecute = $false
                $psi.RedirectStandardInput = $false
                $psi.RedirectStandardOutput = $false
                $psi.RedirectStandardError = $false
                $p = [System.Diagnostics.Process]::Start($psi)
                if ($p) { $p.Dispose() }
            }
        }
    } catch {
        Add-LcaDiagnostic -Source 'report' -Level 'info' -Message "could not open $Path" -ErrorRecord $_
    }
}
