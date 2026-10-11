# Windows only: run the REAL v1 script and the v2 bundle against the same
# fixture machine (fake npm / winget shims, fake HOME) and compare what they
# detect. Off Windows, v1 cannot run (it splits PATH on ';' and needs
# PATHEXT); parity there is covered by tests/Detection/Parity.Tests.ps1.

BeforeDiscovery {
    $script:OnWindows = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
}

Describe 'v1 vs v2 on the same fixture machine' -Skip:(-not $script:OnWindows) {
    BeforeAll {
        . (Join-Path $PSScriptRoot '../Helpers/Bootstrap.ps1')
        $fx = New-LcaFixture -Root (Join-Path $TestDrive 'v1v2')
        [void](Add-LcaFixtureNpmPackage -Fixture $fx -Name '@anthropic-ai/claude-code' -Version '1.0.9' -Description 'Agentic coding tool that lives in your terminal' -Keywords @('claude', 'anthropic', 'agentic') -Bin @{ claude = 'cli.js' })
        [void](Add-LcaFixtureNpmPackage -Fixture $fx -Name 'eslint' -Version '9.0.0' -Description 'An AST-based pattern checker for JavaScript.' -Bin @{ eslint = 'bin/eslint.js' })
        [void](Add-LcaFixtureNpmPackage -Fixture $fx -Name '@google/gemini-cli' -Version '0.9.0' -Description 'Gemini CLI' -Bin @{ gemini = 'dist/index.js' } -Dependencies @('@google/genai'))
        $local = Add-LcaFixturePathDir -Fixture $fx -Path (Join-FixturePath -Base $fx.Home -Relative '.local/bin')
        [void](New-LcaFixtureCommand -Fixture $fx -Name 'aider' -Dir $local -VersionOutput "aider 0.86.1`n")
        [void](New-LcaFixtureCommand -Fixture $fx -Name 'sg' -Dir $local -VersionOutput "ast-grep 0.39.0`n")
        [void](New-LcaShim -Fixture $fx -Name 'winget')
        $table = @(
            'Name                     Id                       Version   Source',
            '-----------------------------------------------------------------',
            'Codex                    OpenAI.Codex             0.50.0    winget',
            'Git                      Git.Git                  2.51.0    winget',
            'Visual Studio Code       Microsoft.VisualStudioCode 1.105.0 winget'
        ) -join "`r`n"
        Set-LcaShimResponse -Fixture $fx -Tool 'winget' -Arguments 'list --disable-interactivity' -StdOut ($table + "`r`n")
        Set-LcaShimResponse -Fixture $fx -Tool 'winget' -Arguments '*' -StdOut ''
        [void](New-Item -ItemType Directory -Path (Join-Path $fx.Home '.claude') -Force)

        $v1Dir = Join-Path $fx.Root 'v1'
        $v2Dir = Join-Path $fx.Root 'v2'
        [void](New-Item -ItemType Directory -Path $v1Dir, $v2Dir -Force)
        Copy-Item -LiteralPath (Join-Path $RepoRoot 'tests/fixtures/v1/list-coding-agents.v1.ps1') -Destination (Join-Path $v1Dir 'list-coding-agents.ps1')
        Copy-Item -LiteralPath (Join-Path $RepoRoot 'list-coding-agents.ps1') -Destination (Join-Path $v2Dir 'list-coding-agents.ps1')

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r1 = Invoke-LcaFixtureScript -Fixture $fx -Path (Join-Path $v1Dir 'list-coding-agents.ps1') -ArgumentList @('-NoHtml', '-Json')
        $script:V1Ms = $sw.ElapsedMilliseconds
        $sw.Restart()
        $r2 = Invoke-LcaFixtureScript -Fixture $fx -Path (Join-Path $v2Dir 'list-coding-agents.ps1') -ArgumentList @('-NoHtml', '-NoOpen', '-Json', '-OutDir', $v2Dir)
        $script:V2Ms = $sw.ElapsedMilliseconds
        $script:R1 = $r1; $script:R2 = $r2
        # assign first: on 5.1 ConvertFrom-Json emits a top-level array as ONE object
        $j1 = ConvertFrom-Json -InputObject (Get-Content -LiteralPath (Join-Path $v1Dir 'coding-agents.json') -Raw)
        $script:J1 = @($j1)
        $script:J2 = (Get-Content -LiteralPath (Join-Path $v2Dir 'coding-agents.json') -Raw | ConvertFrom-Json).agents
        Write-Host ("v1 {0} ms, v2 {1} ms (fixture, default switches + -NoHtml -Json)" -f $script:V1Ms, $script:V2Ms)
    }

    It 'both runs succeed' {
        $script:R1.ExitCode | Should -Be 0 -Because $script:R1.StdErr
        $script:R2.ExitCode | Should -Be 0 -Because $script:R2.StdErr
    }

    It 'v1 itself found the fixture agents (the comparison is meaningful)' {
        $names = @($script:J1 | ForEach-Object { "$($_.name)=$($_.tier)" } | Sort-Object)
        $names | Should -Be @('aider=detected', 'claude=detected', 'Codex=detected', 'gemini=detected', 'sg=possible')
    }

    It 'v2 detects everything v1 detects, in the same tier' {
        foreach ($a in $script:J1) {
            $m = @($script:J2 | Where-Object { $_.name -eq $a.name })
            $m.Count | Should -Be 1 -Because "v1 found $($a.name) ($($a.tier))"
            $m[0].tier | Should -Be $a.tier -Because $a.name
        }
    }

    It 'v2 reports the same install method and version as v1' {
        foreach ($a in @($script:J1 | Where-Object { $_.tier -eq 'detected' })) {
            $m = @($script:J2 | Where-Object { $_.name -eq $a.name })[0]
            $m.method | Should -Be $a.method -Because $a.name
            if ($a.version) { $m.version | Should -Be $a.version -Because $a.name }
        }
    }
}
