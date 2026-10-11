# End-to-end in THIS process (so it counts for coverage): the CLI entry
# point against a fixture machine.

BeforeDiscovery {
    $IsWin = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
}

BeforeAll {
    . (Join-Path $PSScriptRoot '../Helpers/Bootstrap.ps1')
    $fx = New-LcaFixture -Root (Join-Path $TestDrive 'pipe')
    [void](Add-LcaFixtureNpmPackage -Fixture $fx -Name '@anthropic-ai/claude-code' -Version '1.0.9' -Description 'Agentic coding tool that lives in your terminal' -Keywords @('claude', 'anthropic') -Bin @{ claude = 'cli.js' })
    [void](Add-LcaFixtureNpmPackage -Fixture $fx -Name 'eslint' -Version '9.0.0' -Description 'An AST-based pattern checker for JavaScript.' -Bin @{ eslint = 'bin/eslint.js' })
    $local = Add-LcaFixturePathDir -Fixture $fx -Path (Join-FixturePath -Base $fx.Home -Relative '.local/bin')
    [void](New-LcaFixtureCommand -Fixture $fx -Name 'aider' -Dir $local -VersionOutput "aider 0.86.1`n")
    [void](New-LcaFixtureCommand -Fixture $fx -Name 'sg' -Dir $local -VersionOutput "ast-grep 0.39.0`n")
    $claudeDir = Join-Path $fx.Home '.claude'
    [void](New-Item -ItemType Directory -Path (Join-Path $claudeDir 'projects') -Force)
    Set-Content -LiteralPath (Join-Path $claudeDir 'projects/s1.jsonl') -Value '{}'
    Set-Content -LiteralPath (Join-Path $fx.Home '.claude.json') -Value '{"mcpServers":{"github":{"command":"x","env":{"GITHUB_TOKEN":"ghp_FAKE0000"}},"fs":{"command":"y"}},"apiKey":"sk-ant-FAKE-0000"}'
    $script:ScriptRoot = Join-Path $fx.Root 'scriptroot'
    $script:Out = Join-Path $fx.Root 'out'
    [void](New-Item -ItemType Directory -Path $script:ScriptRoot, $script:Out -Force)

    function Invoke-TestCli {
        param([hashtable]$Bound)
        Use-LcaFixture -Fixture $fx {
            InModuleScope ListCodingAgents -Parameters @{ B = $Bound; R = $script:ScriptRoot } {
                param($B, $R)
                $o = Invoke-LcaCli -BoundParameters $B -ScriptRoot $R 6>&1
                [pscustomobject]@{ Output = @($o); Exit = $script:LcaLastExitCode }
            }
        }
    }
}

Describe 'CLI pipeline (in-process)' {
    It 'scans, prints, writes JSON + HTML and keeps secrets out' {
        $r = Invoke-TestCli -Bound @{ NoOpen = [switch]$true; Json = [switch]$true; OutDir = $script:Out; ShowReasons = [switch]$true }
        $r.Exit | Should -Be 0
        $text = ($r.Output | ForEach-Object { "$_" }) -join "`n"
        $text | Should -Match 'Auto-detected coding agents'
        $text | Should -Match 'claude'
        $json = Get-Content -LiteralPath (Join-Path $script:Out 'coding-agents.json') -Raw
        $html = Get-Content -LiteralPath (Join-Path $script:Out 'coding-agents.html') -Raw
        foreach ($blob in @($text, $json, $html)) {
            $blob | Should -Not -Match 'sk-ant-FAKE-0000'
            $blob | Should -Not -Match 'ghp_FAKE0000'
        }
        $j = $json | ConvertFrom-Json
        $claude = @($j.agents | Where-Object { $_.name -eq 'claude' })[0]
        $claude.tier | Should -Be 'detected'
        $claude.version | Should -Be '1.0.9'
        $claude.mcpServers | Should -Be 2
        $claude.loggedIn | Should -BeTrue
        @($j.agents | Where-Object { $_.name -eq 'eslint' }).Count | Should -Be 0
        @($j.agents | Where-Object { $_.name -eq 'sg' -and $_.tier -eq 'possible' }).Count | Should -Be 1
    }

    It 'honours -Quiet, -PassThru and -Format json' {
        $r = Invoke-TestCli -Bound @{ NoHtml = [switch]$true; Quiet = [switch]$true; PassThru = [switch]$true; Format = 'json' }
        $r.Exit | Should -Be 0
        $agents = @($r.Output | Where-Object { $_.PSObject.TypeNames -contains 'ListCodingAgents.Agent' })
        @($agents | Where-Object { $_.Name -eq 'claude' }).Count | Should -Be 1
        $jsonText = @($r.Output | Where-Object { $_ -is [string] -and $_.TrimStart().StartsWith('{') })
        $jsonText.Count | Should -Be 1
        ($jsonText[0] | ConvertFrom-Json).schemaVersion | Should -Be 2
    }

    It 'reports outdated agents with -CheckUpdates and never installs anything' {
        Set-LcaShimResponse -Fixture $fx -Tool 'npm' -Arguments 'outdated -g --json' -ExitCode 1 -StdOut '{"@anthropic-ai/claude-code":{"current":"1.0.9","wanted":"1.0.9","latest":"1.1.0"}}'
        $r = Invoke-TestCli -Bound @{ NoHtml = [switch]$true; CheckUpdates = [switch]$true }
        ($r.Output | ForEach-Object { "$_" }) -join "`n" | Should -Match 'Updates available'
        $calls = @(Get-LcaShimLog -Fixture $fx | Where-Object { $_.tool -eq 'npm' } | ForEach-Object { $_.args -join ' ' })
        @($calls | Where-Object { $_ -match '^(i|install|update|rm|uninstall)\b' }).Count | Should -Be 0
    }

    It 'prints the version' {
        $r = Invoke-TestCli -Bound @{ Version = [switch]$true }
        $r.Output | Should -Contain 'list-coding-agents 2.0.0'
    }
}

Describe 'Public cmdlets (in-process)' {
    It 'Get-CodingAgent emits Agent objects and -AsScan a Scan' {
        Use-LcaFixture -Fixture $fx {
            $a = @(Get-CodingAgent -NoProbe)
            @($a | Where-Object { $_.Name -eq 'claude' }).Count | Should -Be 1
            @(Get-CodingAgent -Name 'cl*' -NoProbe).Count | Should -Be 1
            $s = Get-CodingAgent -AsScan -NoProbe -IncludePossible
            $s.PSObject.TypeNames[0] | Should -Be 'ListCodingAgents.Scan'
        }
    }
    It 'Export-CodingAgentReport writes both formats' {
        $dir = Join-Path $TestDrive 'export'
        [void](New-Item -ItemType Directory -Path $dir -Force)
        Use-LcaFixture -Fixture $fx {
            $files = @(Get-CodingAgent -AsScan -NoProbe | Export-CodingAgentReport -OutDir $dir -Format html, json -PassThru -Redact)
            $files.Count | Should -Be 2
        }
        (Get-Content -LiteralPath (Join-Path $dir 'coding-agents.json') -Raw | ConvertFrom-Json).host | Should -BeNullOrEmpty
    }
    It 'Update-CodingAgent -WhatIf runs nothing' {
        Set-LcaShimResponse -Fixture $fx -Tool 'npm' -Arguments 'outdated -g --json' -ExitCode 1 -StdOut '{"@anthropic-ai/claude-code":{"current":"1.0.9","wanted":"1.0.9","latest":"1.1.0"}}'
        if (Test-Path -LiteralPath $fx.ShimLog) { Remove-Item -LiteralPath $fx.ShimLog }
        Use-LcaFixture -Fixture $fx { Update-CodingAgent -WhatIf }
        $calls = @(Get-LcaShimLog -Fixture $fx | Where-Object { $_.tool -eq 'npm' } | ForEach-Object { $_.args -join ' ' })
        @($calls | Where-Object { $_ -match '^(i|install)\b' }).Count | Should -Be 0
    }
}
