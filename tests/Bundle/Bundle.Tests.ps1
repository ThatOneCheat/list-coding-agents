# The single-file bundle: deterministic build, no drift from the committed
# copy, and smoke runs as a file and as a script block (irm | iex).

BeforeAll {
    . (Join-Path $PSScriptRoot '../Helpers/Bootstrap.ps1')
    $bundle = Join-Path $RepoRoot 'list-coding-agents.ps1'
    $buildScript = Join-Path $RepoRoot 'build.ps1'
    $hostExe = (Get-Process -Id $PID).Path
    function Invoke-TestBuild {
        param([string]$Out)
        $o = & $hostExe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $buildScript -OutputPath $Out 2>&1
        if ($LASTEXITCODE -ne 0) { throw "build failed: $o" }
    }
    function Get-TestHash { param([string]$Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
}

Describe 'build.ps1' {
    It 'is deterministic and matches the committed bundle' {
        $a = Join-Path $TestDrive 'a.ps1'
        $b = Join-Path $TestDrive 'b.ps1'
        Invoke-TestBuild -Out $a
        Invoke-TestBuild -Out $b
        Get-TestHash $a | Should -Be (Get-TestHash $b)
        Get-TestHash $a | Should -Be (Get-TestHash $bundle) -Because 'list-coding-agents.ps1 must be rebuilt (./build.ps1) and committed'
    }

    It 'produces an ASCII, LF-only bundle that parses' {
        $bytes = [System.IO.File]::ReadAllBytes($bundle)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        [System.IO.File]::ReadAllText($bundle).Contains("`r") | Should -BeFalse
        $errors = $null; $tokens = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($bundle, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }

    It 'keeps comment-based help for every parameter' {
        $help = Get-Help $bundle -Full
        $params = (Get-Command $bundle).Parameters.Keys | Where-Object { $_ -notin [System.Management.Automation.PSCmdlet]::CommonParameters -and $_ -notin [System.Management.Automation.PSCmdlet]::OptionalCommonParameters }
        foreach ($p in $params) {
            $h = $help.parameters.parameter | Where-Object { $_.name -eq $p }
            ($h.description | Out-String).Trim() | Should -Not -BeNullOrEmpty -Because "-$p needs help text"
        }
    }

    It 'keeps every v1 switch' {
        $keys = (Get-Command $bundle).Parameters.Keys
        foreach ($p in 'IncludeEditors', 'ShowReasons', 'NoHtml', 'SkipWinget', 'CheckUpdates', 'UpdateAll', 'Json') {
            $keys | Should -Contain $p
            (Get-Command $bundle).Parameters[$p].SwitchParameter | Should -BeTrue
        }
    }
}

Describe 'Bundle smoke' {
    BeforeAll {
        $fx = New-LcaFixture -Root (Join-Path $TestDrive 'smoke')
        [void](Add-LcaFixtureNpmPackage -Fixture $fx -Name '@anthropic-ai/claude-code' -Version '1.0.9' -Description 'Agentic coding tool that lives in your terminal' -Keywords @('claude', 'anthropic', 'agentic', 'coding') -Bin @{ claude = 'cli.js' })
        [void](New-Item -ItemType Directory -Path (Join-Path $fx.Home '.claude') -Force)
        $runDir = Join-Path $fx.Root 'run'
        $out = Join-Path $fx.Root 'out'
        [void](New-Item -ItemType Directory -Path $runDir, $out -Force)
        Copy-Item -LiteralPath $bundle -Destination (Join-Path $runDir 'list-coding-agents.ps1')
        $script:RunBundle = Join-Path $runDir 'list-coding-agents.ps1'
        $script:Out = $out
    }

    It 'runs as a file: -NoOpen -Json -OutDir' {
        $r = Invoke-LcaFixtureScript -Fixture $fx -Path $script:RunBundle -ArgumentList @('-NoOpen', '-Json', '-OutDir', $script:Out)
        $r.ExitCode | Should -Be 0 -Because $r.StdErr
        $r.StdErr | Should -BeNullOrEmpty
        $j = Get-Content -LiteralPath (Join-Path $script:Out 'coding-agents.json') -Raw | ConvertFrom-Json
        $j.schemaVersion | Should -Be 2
        @($j.agents | Where-Object { $_.name -eq 'claude' -and $_.tier -eq 'detected' }).Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path $script:Out 'coding-agents.html') | Should -BeTrue
    }

    It 'runs as a script block without $PSScriptRoot (irm | iex)' {
        $out2 = Join-Path $TestDrive 'iex-out'
        [void](New-Item -ItemType Directory -Path $out2 -Force)
        $r = Invoke-LcaFixtureScript -Fixture $fx -Path $script:RunBundle -AsScriptBlock -ArgumentList @('-NoOpen', '-Json', '-OutDir', $out2)
        $r.StdErr | Should -BeNullOrEmpty
        $j = Get-Content -LiteralPath (Join-Path $out2 'coding-agents.json') -Raw | ConvertFrom-Json
        @($j.agents | Where-Object { $_.name -eq 'claude' }).Count | Should -Be 1
    }

    It 'prints its version' {
        $r = Invoke-LcaFixtureScript -Fixture $fx -Path $script:RunBundle -ArgumentList @('-Version')
        $r.ExitCode | Should -Be 0
        $r.StdOut | Should -Match 'list-coding-agents 2\.\d+\.\d+'
    }

    It '-UpdateAll -WhatIf changes nothing' {
        Set-LcaShimResponse -Fixture $fx -Tool 'npm' -Arguments 'outdated -g --json' -ExitCode 1 -StdOut '{"@anthropic-ai/claude-code":{"current":"1.0.9","wanted":"1.0.9","latest":"1.1.0"}}'
        Set-LcaShimResponse -Fixture $fx -Tool 'npm' -Arguments '*' -StdOut 'SHOULD NOT RUN' -ExitCode 0
        if (Test-Path -LiteralPath $fx.ShimLog) { Remove-Item -LiteralPath $fx.ShimLog }
        $r = Invoke-LcaFixtureScript -Fixture $fx -Path $script:RunBundle -ArgumentList @('-UpdateAll', '-WhatIf', '-NoHtml')
        $r.ExitCode | Should -Be 0 -Because $r.StdErr
        $calls = @(Get-LcaShimLog -Fixture $fx | Where-Object { $_.tool -eq 'npm' } | ForEach-Object { ($_.args -join ' ') })
        $calls | Should -Contain 'outdated -g --json'
        @($calls | Where-Object { $_ -match '^(i|install|update|rm|uninstall)\b' }).Count | Should -Be 0
    }
}
