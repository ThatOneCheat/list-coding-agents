BeforeDiscovery {
    $IsWin = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
    $IsDesktop = $PSVersionTable.PSEdition -ne 'Core'
}
BeforeAll { . (Join-Path $PSScriptRoot '../Helpers/Bootstrap.ps1') }

Describe 'Get-LcaPathEntry' {
    It 'splits PATH on the platform separator, trims, unquotes and de-duplicates' {
        InModuleScope ListCodingAgents {
            $sep = [System.IO.Path]::PathSeparator
            $root = [System.IO.Path]::GetTempPath().TrimEnd('\', '/')
            $a = Join-Path $root 'lca-a'; $b = Join-Path $root 'lca-b'
            Mock Get-LcaEnvironmentVariable { "  $a $sep`"$b`"$sep$sep$a$sep" } -ParameterFilter { $Name -eq 'PATH' }
            $r = @(Get-LcaPathEntry)
            $r | Should -Be @($a, $b)
        }
    }

    It 'strips trailing separators but keeps a drive root intact (v1 turned C:\ into drive-relative C:)' {
        InModuleScope ListCodingAgents {
            $r = @(Split-LcaPathList -Value 'C:\;C:\Tools\;D:\x/;c:\tools' -Separator ';' -Windows $true)
            $r | Should -Be @('C:\', 'C:\Tools', 'D:\x')
        }
    }

    It 'is case-sensitive off Windows' {
        InModuleScope ListCodingAgents {
            @(Split-LcaPathList -Value '/a/B:/a/b:/a/B/' -Separator ':' -Windows $false) | Should -Be @('/a/B', '/a/b')
        }
    }

    It 'returns nothing for an empty PATH' {
        InModuleScope ListCodingAgents {
            Mock Get-LcaEnvironmentVariable { $null } -ParameterFilter { $Name -eq 'PATH' }
            @(Get-LcaPathEntry).Count | Should -Be 0
        }
    }
}

Describe 'Get-LcaKnownFolder' {
    It 'honours absolute XDG variables and ignores relative ones' -Skip:$IsWin {
        InModuleScope ListCodingAgents {
            Mock Get-LcaPlatform { 'linux' }
            Mock Get-LcaEnvironmentVariable { $null }
            Mock Get-LcaEnvironmentVariable { '/home/u' } -ParameterFilter { $Name -eq 'HOME' }
            Mock Get-LcaEnvironmentVariable { '/x/state' } -ParameterFilter { $Name -eq 'XDG_STATE_HOME' }
            Mock Get-LcaEnvironmentVariable { 'relative/config' } -ParameterFilter { $Name -eq 'XDG_CONFIG_HOME' }
            Get-LcaKnownFolder -Name XdgStateHome | Should -Be '/x/state'
            Get-LcaKnownFolder -Name XdgConfigHome | Should -Be '/home/u/.config'
            Get-LcaKnownFolder -Name XdgDataHome | Should -Be '/home/u/.local/share'
            Get-LcaKnownFolder -Name AppData | Should -BeNullOrEmpty
        }
    }

    It 'uses USERPROFILE / APPDATA / LOCALAPPDATA on Windows' {
        InModuleScope ListCodingAgents {
            Mock Get-LcaPlatform { 'windows' }
            Mock Get-LcaEnvironmentVariable { $null }
            Mock Get-LcaEnvironmentVariable { 'C:\Users\u' } -ParameterFilter { $Name -eq 'USERPROFILE' }
            Mock Get-LcaEnvironmentVariable { 'C:\Users\u\AppData\Roaming' } -ParameterFilter { $Name -eq 'APPDATA' }
            Mock Get-LcaEnvironmentVariable { 'C:\Users\u\AppData\Local' } -ParameterFilter { $Name -eq 'LOCALAPPDATA' }
            Get-LcaKnownFolder -Name Home | Should -Be 'C:\Users\u'
            Get-LcaKnownFolder -Name AppData | Should -Be 'C:\Users\u\AppData\Roaming'
            Get-LcaKnownFolder -Name LocalAppData | Should -Be 'C:\Users\u\AppData\Local'
            Get-LcaKnownFolder -Name XdgStateHome | Should -BeNullOrEmpty
        }
    }

    It 'returns the macOS Application Support folder only on macOS' {
        InModuleScope ListCodingAgents {
            Mock Get-LcaPlatform { 'macos' }
            Mock Get-LcaEnvironmentVariable { $null }
            Mock Get-LcaEnvironmentVariable { '/Users/u' } -ParameterFilter { $Name -eq 'HOME' }
            (Get-LcaKnownFolder -Name AppSupport).Replace('\', '/') | Should -Be '/Users/u/Library/Application Support'
        }
    }
}

Describe 'Get-LcaNow' {
    It 'returns LCA_FAKE_NOW when set' {
        InModuleScope ListCodingAgents {
            Mock Get-LcaEnvironmentVariable { '2026-01-02T03:04:05+02:00' } -ParameterFilter { $Name -eq 'LCA_FAKE_NOW' }
            $n = Get-LcaNow
            $n.Year | Should -Be 2026
            $n.Offset.TotalHours | Should -Be 2
        }
    }
    It 'falls back to the real clock' {
        InModuleScope ListCodingAgents {
            Mock Get-LcaEnvironmentVariable { $null } -ParameterFilter { $Name -eq 'LCA_FAKE_NOW' }
            ((Get-LcaNow) - [DateTimeOffset]::Now).TotalSeconds | Should -BeLessThan 5
        }
    }
}

Describe 'ConvertTo-LcaArgumentString' {
    It 'quotes <Case>' -TestCases @(
        @{ Case = 'plain'; In = @('a', 'b'); Out = 'a b' }
        @{ Case = 'spaces'; In = @('a b'); Out = '"a b"' }
        @{ Case = 'empty'; In = @(''); Out = '""' }
        @{ Case = 'quotes'; In = @('say "hi"'); Out = '"say \"hi\""' }
        @{ Case = 'trailing backslash'; In = @('C:\a b\'); Out = '"C:\a b\\"' }
        @{ Case = 'backslash before quote'; In = @('a\"b'); Out = '"a\\\"b"' }
    ) {
        param($Case, $In, $Out)
        InModuleScope ListCodingAgents -Parameters @{ In = $In; Out = $Out } {
            param($In, $Out)
            ConvertTo-LcaArgumentString -ArgumentList $In | Should -BeExactly $Out
        }
    }

    It 'round-trips through a real child process' {
        $echo = Join-Path $TestDrive 'echo-args.ps1'
        Set-Content -LiteralPath $echo -Value '$args | ForEach-Object { "[$_]" }' -Encoding Ascii
        InModuleScope ListCodingAgents -Parameters @{ Echo = $echo } {
            param($Echo)
            $args2 = @('plain', 'with space', 'quote"inside', 'trail\', '@scope/pkg@latest', 'a\\"b')
            $exe = Get-LcaPowerShellPath
            $r = Invoke-LcaProcess -FilePath $exe -ArgumentList (@('-NoProfile', '-NonInteractive', '-File', $Echo) + $args2) -TimeoutSec 60
            $r.Failed | Should -BeFalse -Because $r.StdErr
            $lines = @($r.StdOut -split "`r?`n" | Where-Object { $_ })
            $lines | Should -Be @('[plain]', '[with space]', '[quote"inside]', '[trail\]', '[@scope/pkg@latest]', '[a\\"b]')
        }
    }
}

Describe 'Test-LcaSafeBatchArgument' {
    It 'accepts package tokens and rejects shell metacharacters' {
        InModuleScope ListCodingAgents {
            Test-LcaSafeBatchArgument -ArgumentList @('i', '-g', '@anthropic-ai/claude-code@latest') | Should -BeTrue
            foreach ($bad in @('a&b', 'a|b', 'a>b', '%PATH%', 'a"b', 'x^y', "a`nb", '!x!', '(x)')) {
                Test-LcaSafeBatchArgument -ArgumentList @('ok', $bad) | Should -BeFalse -Because $bad
            }
        }
    }
}

Describe 'Invoke-LcaProcess' {
    BeforeAll {
        $fx = New-LcaFixture -Root (Join-Path $TestDrive 'proc')
        [void](New-LcaFixtureCommand -Fixture $fx -Name 'verout' -VersionOutput "verout 1.2.3`n")
        [void](New-LcaFixtureCommand -Fixture $fx -Name 'vererr' -VersionOutput '' -VersionStdErr "vererr version 4.5.6`n")
        [void](New-LcaShim -Fixture $fx -Name 'failer')
        Set-LcaShimResponse -Fixture $fx -Tool 'failer' -Arguments '*' -StdOut 'partial' -ExitCode 3
        [void](New-LcaShim -Fixture $fx -Name 'sleeper')
        Set-LcaShimResponse -Fixture $fx -Tool 'sleeper' -Arguments '*' -StdOut 'late' -SleepSec 30
        [void](New-LcaShim -Fixture $fx -Name 'envdump')
    }

    It 'captures stdout and the exit code' {
        Use-LcaFixture -Fixture $fx {
            InModuleScope ListCodingAgents {
                $r = Invoke-LcaProcess -FilePath 'verout' -ArgumentList @('--version') -TimeoutSec 60
                $r.ExitCode | Should -Be 0
                $r.Failed | Should -BeFalse
                $r.StdOut | Should -Match '1\.2\.3'
            }
        }
    }

    It 'captures stderr (some CLIs print their version there; v1 dropped it)' {
        Use-LcaFixture -Fixture $fx {
            InModuleScope ListCodingAgents {
                $r = Invoke-LcaProcess -FilePath 'vererr' -ArgumentList @('--version') -TimeoutSec 60
                $r.StdErr | Should -Match '4\.5\.6'
            }
        }
    }

    It 'reports a non-zero exit code as failed but keeps the output' {
        Use-LcaFixture -Fixture $fx {
            InModuleScope ListCodingAgents {
                $r = Invoke-LcaProcess -FilePath 'failer' -TimeoutSec 60
                $r.Failed | Should -BeTrue
                $r.ExitCode | Should -Be 3
                $r.StdOut | Should -Be 'partial'
            }
        }
    }

    It 'enforces a hard timeout and kills the whole process tree (defect 9)' {
        $pidFile = Join-Path $TestDrive 'tree.pids'
        [void](New-LcaShim -Fixture $fx -Name 'treesleeper')
        Set-LcaShimResponse -Fixture $fx -Tool 'treesleeper' -Arguments '*' -StdOut 'late' -SleepSec 60 -PidFile $pidFile -SpawnChild
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Use-LcaFixture -Fixture $fx {
            InModuleScope ListCodingAgents { Invoke-LcaProcess -FilePath 'treesleeper' -TimeoutSec 4 }
        }
        $sw.Stop()
        $r.TimedOut | Should -BeTrue
        $r.Failed | Should -BeTrue
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 12
        Test-Path -LiteralPath $pidFile | Should -BeTrue -Because 'the shim must have started before the timeout'
        $pids = @(([System.IO.File]::ReadAllText($pidFile)).Split(',') | ForEach-Object { [int]$_ })
        $pids.Count | Should -Be 2
        $alive = @()
        for ($i = 0; $i -lt 20; $i++) {
            $alive = @($pids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
            if (-not $alive.Count) { break }
            Start-Sleep -Milliseconds 250
        }
        $alive.Count | Should -Be 0 -Because "process(es) $($alive -join ',') survived the timeout"
    }

    It 'skips stale PATH entries without errors' {
        $fx3 = New-LcaFixture -Root (Join-Path $TestDrive 'stale')
        $p = New-LcaShim -Fixture $fx3 -Name 'npm'
        $missing = Join-Path $TestDrive 'does/not/exist'
        if ($IsWin) { $missing = 'Q:\nope\bin' }
        $fx3.PathDirs.Insert(0, $missing)
        Use-LcaFixture -Fixture $fx3 {
            InModuleScope ListCodingAgents -Parameters @{ P = $p } {
                param($P)
                $ErrorActionPreference = 'Stop'
                Find-LcaExecutable -Name 'npm' | Should -Be $P
            }
        }
    }

    It 'never throws for a missing command' {
        InModuleScope ListCodingAgents {
            $r = Invoke-LcaProcess -FilePath 'definitely-not-a-real-command-lca' -TimeoutSec 5
            $r.Failed | Should -BeTrue
            $r.Error | Should -Match 'not found'
        }
    }

    It 'sets CI, NO_COLOR and TERM for children and closes stdin' {
        InModuleScope ListCodingAgents {
            $exe = Get-LcaPowerShellPath
            $cmd = '"$env:CI|$env:NO_COLOR|$env:TERM"; $x = [Console]::In.ReadToEnd(); "stdin=[" + $x + "]"'
            $r = Invoke-LcaProcess -FilePath $exe -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $cmd) -TimeoutSec 60
            $r.StdOut | Should -Match '1\|1\|dumb'
            # .NET Framework writes a BOM into the child's stdin when the console
            # input code page is UTF-8 (documented limitation in Open-LcaProcess)
            $r.StdOut | Should -Match ('stdin=\[' + [char]0xFEFF + '?\]')
        }
    }
}

Describe 'Find-LcaExecutable' {
    It 'finds a command on the fixture PATH and returns $null for unknown names' {
        $fx2 = New-LcaFixture -Root (Join-Path $TestDrive 'find')
        $p = New-LcaShim -Fixture $fx2 -Name 'npm'
        Use-LcaFixture -Fixture $fx2 {
            InModuleScope ListCodingAgents -Parameters @{ P = $p } {
                param($P)
                Find-LcaExecutable -Name 'npm' | Should -Be $P
                Find-LcaExecutable -Name 'nope-lca' | Should -BeNullOrEmpty
            }
        }
    }
}

Describe 'Invoke-LcaParallel' {
    It 'returns results in input order with a bounded pool' {
        InModuleScope ListCodingAgents {
            $r = @(Invoke-LcaParallel -InputObject @(1, 2, 3, 4, 5, 6) -ThrottleLimit 3 -ScriptBlock { param($x) Start-Sleep -Milliseconds (60 - 10 * $x); $x * 10 })
            ($r | ForEach-Object { $_.Output }) | Should -Be @(10, 20, 30, 40, 50, 60)
            @($r | Where-Object { $_.Error }).Count | Should -Be 0
        }
    }

    It 'makes named module functions available inside the runspaces' {
        InModuleScope ListCodingAgents {
            $r = @(Invoke-LcaParallel -InputObject @('1.2', 'x 3.4.5 y') -ThrottleLimit 2 -FunctionName 'Get-LcaVersionFromText' -ScriptBlock { param($t) Get-LcaVersionFromText -Text $t })
            ($r | ForEach-Object { $_.Output }) | Should -Be @('1.2', '3.4.5')
        }
    }

    It 'captures errors per item' {
        InModuleScope ListCodingAgents {
            $r = @(Invoke-LcaParallel -InputObject @(1, 2) -ThrottleLimit 2 -ScriptBlock { param($x) if ($x -eq 2) { throw 'boom' }; $x })
            $r[0].Output | Should -Be 1
            $r[1].Error | Should -Match 'boom'
        }
    }

    It 'runs inline with a throttle of 1' {
        InModuleScope ListCodingAgents {
            $r = @(Invoke-LcaParallel -InputObject @('a') -ThrottleLimit 1 -ScriptBlock { param($x) "$x!" })
            $r[0].Output | Should -Be 'a!'
        }
    }
}

Describe 'Get-LcaUninstallEntry / Get-LcaFileVersionInfo' {
    It 'returns nothing off Windows' -Skip:$IsWin {
        InModuleScope ListCodingAgents { @(Get-LcaUninstallEntry).Count | Should -Be 0 }
    }
    It 'reads real Uninstall keys on Windows' -Skip:(-not $IsWin) {
        InModuleScope ListCodingAgents {
            $e = @(Get-LcaUninstallEntry)
            $e.Count | Should -BeGreaterThan 0
            $e[0].PSObject.Properties.Name | Should -Contain 'QuietUninstallString'
        }
    }
    It 'ignores non-exe paths' {
        InModuleScope ListCodingAgents { Get-LcaFileVersionInfo -Path '/tmp/x.sh' | Should -BeNullOrEmpty }
    }
}

Describe 'Split-LcaCommandLine' {
    It 'splits <Case>' -TestCases @(
        @{ Case = 'quoted exe'; In = '"C:\Program Files\App\uninst.exe" /S'; Out = @('C:\Program Files\App\uninst.exe', '/S') }
        @{ Case = 'msiexec'; In = 'MsiExec.exe /X{12345678-1234-1234-1234-123456789012}'; Out = @('MsiExec.exe', '/X{12345678-1234-1234-1234-123456789012}') }
        @{ Case = 'quoted args'; In = 'C:\x\u.exe --dir "C:\a b" --q'; Out = @('C:\x\u.exe', '--dir', 'C:\a b', '--q') }
        @{ Case = 'escaped quote'; In = 'u.exe "a \"b\" c"'; Out = @('u.exe', 'a "b" c') }
    ) {
        param($Case, $In, $Out)
        InModuleScope ListCodingAgents -Parameters @{ In = $In; Out = $Out } {
            param($In, $Out)
            @(Split-LcaCommandLine -CommandLine $In) | Should -Be $Out
        }
    }
    It 'returns nothing for an empty string' {
        InModuleScope ListCodingAgents { Split-LcaCommandLine -CommandLine '  ' | Should -BeNullOrEmpty }
    }
}

Describe 'Invoke-LcaParallel error, timeout and diagnostics handling' {
    It 'captures non-terminating errors even when the item also produced output' {
        InModuleScope ListCodingAgents {
            $r = @(Invoke-LcaParallel -InputObject @(1, 2) -ThrottleLimit 2 -ScriptBlock { param($x) Write-Error "bad $x"; $x })
            $r[0].Error | Should -Match 'bad 1'
            @($r[0].Output) | Should -Be @(1)
        }
    }
    It 'returns Output as an array in both modes' {
        InModuleScope ListCodingAgents {
            $inline = @(Invoke-LcaParallel -InputObject @(1) -ThrottleLimit 1 -ScriptBlock { param($x) })
            $pool = @(Invoke-LcaParallel -InputObject @(1, 2) -ThrottleLimit 2 -ScriptBlock { param($x) })
            , $inline[0].Output | Should -BeOfType [object[]]
            , $pool[0].Output | Should -BeOfType [object[]]
            @($inline[0].Output).Count | Should -Be 0
            @($pool[0].Output).Count | Should -Be 0
        }
    }
    It 'enforces TimeoutSec without waiting for the hung item' {
        InModuleScope ListCodingAgents {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $r = @(Invoke-LcaParallel -InputObject @(1, 2) -ThrottleLimit 2 -TimeoutSec 1 -ScriptBlock { param($x) if ($x -eq 2) { Start-Sleep -Seconds 20 }; $x })
            $sw.Stop()
            $sw.Elapsed.TotalSeconds | Should -BeLessThan 6
            $r[1].TimedOut | Should -BeTrue
            @($r[0].Output) | Should -Be @(1)
        }
    }
    It 'merges diagnostics recorded inside work items' {
        InModuleScope ListCodingAgents {
            Clear-LcaDiagnostic
            [void](Invoke-LcaParallel -InputObject @('a', 'b') -ThrottleLimit 2 -ScriptBlock { param($x) Add-LcaDiagnostic -Source 'par' -Level 'info' -Message "item $x" })
            @(Get-LcaDiagnostic | Where-Object { $_.Source -eq 'par' }).Count | Should -Be 2
        }
    }
}
