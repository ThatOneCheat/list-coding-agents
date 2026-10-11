# Pester 5 tests for the pure helpers in list-coding-agents.ps1.
# Run:  Invoke-Pester -Path .\tests
BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-ScriptFunctions.ps1')
}

Describe 'Get-AgentScore' {
    It 'auto-detects an exact known CLI name on the name alone' {
        $s = Get-AgentScore -Text 'claude' -Deps @() -Publisher '' -Name 'claude' -Path 'C:\x\claude.exe'
        $s.Score | Should -BeGreaterOrEqual 4
        $s.Why | Should -Match 'known CLI name'
    }
    It 'only nudges an ambiguous name (ast-grep sg) into the review tier' {
        $s = Get-AgentScore -Text 'sg' -Deps @() -Publisher '' -Name 'sg' -Path 'C:\x\sg.exe'
        $s.Score | Should -BeGreaterOrEqual 2
        $s.Score | Should -BeLessThan 4
    }
    It 'throws out mcp utilities' {
        $s = Get-AgentScore -Text 'some mcp server' -Deps @('@modelcontextprotocol/sdk') -Publisher '' -Name 'foo-mcp-server' -Path 'C:\x\foo-mcp-server.cmd'
        $s.Score | Should -BeLessThan 0
    }
    It 'throws out package managers' {
        $s = Get-AgentScore -Text 'npm a package manager for JavaScript' -Deps @() -Publisher '' -Name 'npm' -Path 'C:\x\npm.cmd'
        $s.Score | Should -BeLessThan 0
    }
    It 'throws out helper binaries next to an agent' {
        $s = Get-AgentScore -Text 'claude helper' -Deps @() -Publisher '' -Name 'claude-helper' -Path 'C:\x\claude-helper.exe'
        $s.Score | Should -BeLessThan 0
    }
    It 'notices an AI SDK dependency' {
        $s = Get-AgentScore -Text 'mytool' -Deps @('openai', 'chalk') -Publisher '' -Name 'mytool' -Path 'C:\x\mytool.cmd'
        $s.Why | Should -Match 'AI SDK dependency'
    }
    It 'does not treat the mcp sdk alone as an agent signal' {
        $s = Get-AgentScore -Text 'mytool' -Deps @('@modelcontextprotocol/sdk') -Publisher '' -Name 'mytool' -Path 'C:\x\mytool.cmd'
        $s.Why | Should -Not -Match 'AI SDK dependency'
    }
    It 'scores brand-cli names like the bare brand' {
        $s = Get-AgentScore -Text 'kimi-cli' -Deps @() -Publisher '' -Name 'kimi-cli' -Path 'C:\x\kimi-cli.exe'
        $s.Why | Should -Match 'brand command'
    }
    It 'gives a plain tool with no signals a zero' {
        $s = Get-AgentScore -Text 'ffmpeg' -Deps @() -Publisher '' -Name 'ffmpeg' -Path 'C:\x\ffmpeg.exe'
        $s.Score | Should -Be 0
    }
    It 'does not let a sibling tool inherit brand words from its folder' {
        $s = Get-AgentScore -Text 'fd' -Deps @() -Publisher '' -Name 'fd' -Path 'C:\Users\x\.kimi-code\bin\fd.exe'
        $s.Score | Should -Be 0
    }
}

Describe 'Get-McpCountFromRaw' {
    It 'counts the entries directly inside an mcpServers block' {
        $raw = '{"mcpServers":{"a":{"command":"x","args":["--p","{"]},"b":{"url":"http://x"}},"other":{"c":1}}'
        Get-McpCountFromRaw $raw | Should -Be 2
    }
    It 'ignores braces inside strings' {
        Get-McpCountFromRaw '{"mcpServers":{"a":{"note":"}}}"}}}' | Should -Be 1
    }
    It 'counts toml [mcp_servers.x] sections' {
        $raw = "[mcp_servers.one]`ncommand = 'x'`n[mcp_servers.two]`ncommand = 'y'`n"
        Get-McpCountFromRaw $raw | Should -Be 2
    }
    It 'returns 0 for empty input' {
        Get-McpCountFromRaw '' | Should -Be 0
    }
}

Describe 'ConvertFrom-WingetRow' {
    It 'skips the header, the separator, spinner noise and blank lines' {
        ConvertFrom-WingetRow 'Name                 Id                  Version    Available  Source' | Should -BeNullOrEmpty
        ConvertFrom-WingetRow '-----------------------------------------------' | Should -BeNullOrEmpty
        ConvertFrom-WingetRow '   -   ' | Should -BeNullOrEmpty
        ConvertFrom-WingetRow '' | Should -BeNullOrEmpty
    }
    It 'splits a proper Publisher.Product id' {
        $w = ConvertFrom-WingetRow 'Claude Code                Anthropic.ClaudeCode           1.0.5      1.0.6     winget'
        $w.Name | Should -Be 'Claude Code'
        $w.Publisher | Should -Be 'Anthropic'
        $w.Product | Should -Be 'ClaudeCode'
        $w.Version | Should -Be '1.0.5'
        $w.Kind | Should -Be 'cli'
    }
    It 'reads an MSIX store package as a gui app' {
        $w = ConvertFrom-WingetRow 'ChatGPT                    MSIX\OpenAI.Codex_26.1007.2314.0_x64__2p2nqsd0c76g0      26.1007.2314.0'
        $w.Publisher | Should -Be 'OpenAI'
        $w.Product | Should -Be 'Codex'
        $w.Version | Should -Be '26.1007.2314.0'
        $w.Kind | Should -Be 'app'
    }
    It 'reads an ARP fallback id with no publisher' {
        $w = ConvertFrom-WingetRow 'Copilot                    ARP\Machine\X86\Microsoft Copilot        155.0.4283.45'
        $w.Publisher | Should -Be ''
        $w.Product | Should -Be 'Microsoft Copilot'
        $w.Kind | Should -Be 'app'
    }
    It 'calls cursor an editor' {
        (ConvertFrom-WingetRow 'Cursor                     Anysphere.Cursor                 1.2.3    winget').Kind | Should -Be 'editor'
    }
    It 'keeps a cli-looking product a cli' {
        (ConvertFrom-WingetRow 'Gemini CLI                 Google.GeminiCLI                 0.9.0    winget').Kind | Should -Be 'cli'
    }
    It 'treats an Unknown version as blank' {
        (ConvertFrom-WingetRow 'Google Cloud SDK           Google.CloudSDK                  Unknown    588.0.0   winget').Version | Should -Be ''
    }
    It 'does not turn the Microsoft Copilot app into the copilot CLI' {
        foreach ($line in @('Copilot                    ARP\Machine\X86\Microsoft Copilot        155.0.4283.45',
                            'Copilot                    Microsoft.365Copilot                     155.0.4283.45   winget')) {
            $w = ConvertFrom-WingetRow $line
            $s = Get-AgentScore -Text "$($w.Name) $($w.Id)" -Deps @() -Publisher $w.Publisher -Name $w.Product -Path $w.Id
            $s.Score | Should -BeLessThan 2
        }
    }
    It 'still detects the Codex package by the product half of its id' {
        $w = ConvertFrom-WingetRow 'ChatGPT                    MSIX\OpenAI.Codex_26.1007.2314.0_x64__2p2nqsd0c76g0      26.1007.2314.0'
        $s = Get-AgentScore -Text "$($w.Name) $($w.Id)" -Deps @() -Publisher $w.Publisher -Name $w.Product -Path $w.Id
        $s.Score | Should -BeGreaterOrEqual 4
    }
}

Describe 'Get-ExeVersionProbe' {
    BeforeAll { $cmd = Join-Path $env:SystemRoot 'System32\cmd.exe' }
    It 'reads the version an exe prints' {
        Get-ExeVersionProbe -Path $cmd -Arguments @('/c', 'echo mytool v1.2.3') | Should -Be '1.2.3'
    }
    It 'also looks at stderr' {
        Get-ExeVersionProbe -Path $cmd -Arguments @('/c', 'echo 4.5.6 1>&2') | Should -Be '4.5.6'
    }
    It 'returns nothing for an exe that prints no version' {
        Get-ExeVersionProbe -Path $cmd -Arguments @('/c', 'echo hello') | Should -BeNullOrEmpty
    }
    It 'gives up on a hung exe and kills its whole tree' {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $v = Get-ExeVersionProbe -Path $cmd -Arguments @('/c', 'ping -n 30 127.0.0.1 >nul') -TimeoutSec 1
        $sw.Stop()
        $v | Should -BeNullOrEmpty
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 10
        # the ping child must go down with cmd, not linger for 30s
        $deadline = (Get-Date).AddSeconds(3)
        do {
            $left = @(Get-Process -Name ping -ErrorAction SilentlyContinue)
            if (-not $left.Count) { break }
            Start-Sleep -Milliseconds 200
        } while ((Get-Date) -lt $deadline)
        $left.Count | Should -Be 0
    }
}

Describe 'Format-Size' {
    It 'is blank for null' { Format-Size $null | Should -Be '' }
    It 'rounds tiny things to <0.1 MB' { Format-Size 0.05 | Should -Be '<0.1 MB' }
    It 'keeps one decimal under 10 MB' { Format-Size 5.2 | Should -Be '5.2 MB' }
    It 'drops the decimal from 10 MB up' { Format-Size 15 | Should -Be '15 MB' }
    It 'switches to GB at 1024' { Format-Size 2048 | Should -Be '2.0 GB' }
}

Describe 'Format-Age' {
    It 'is blank for null' { Format-Age $null | Should -Be '' }
    It 'says today' { Format-Age (Get-Date) | Should -Be 'today' }
    It 'says yesterday' { Format-Age (Get-Date).AddDays(-1.5) | Should -Be 'yesterday' }
    It 'counts days under 60' { Format-Age (Get-Date).AddDays(-10) | Should -Be '10d ago' }
    It 'counts months under a year' { Format-Age (Get-Date).AddDays(-100) | Should -Be '3mo ago' }
    It 'counts years' { Format-Age (Get-Date).AddDays(-400) | Should -Be '1y ago' }
}

Describe 'Get-Method' {
    It 'spots npm' { Get-Method 'C:\Users\x\AppData\Roaming\npm\claude.cmd' | Should -Be 'npm' }
    It 'spots winget' { Get-Method 'C:\Users\x\AppData\Local\Microsoft\WindowsApps\codex.exe' | Should -Be 'winget' }
    It 'spots pip / uv' { Get-Method 'C:\Users\x\AppData\Local\Programs\Python\Python311\Scripts\aider.exe' | Should -Be 'pip / uv' }
    It 'spots scoop' { Get-Method 'C:\Users\x\scoop\shims\goose.exe' | Should -Be 'scoop' }
    It 'spots cargo' { Get-Method 'C:\Users\x\.cargo\bin\crush.exe' | Should -Be 'cargo' }
    It 'spots bun' { Get-Method 'C:\Users\x\.bun\bin\opencode.exe' | Should -Be 'bun' }
    It 'calls ~/.local/bin a standalone installer' { Get-Method 'C:\Users\x\.local\bin\claude.exe' | Should -Be 'standalone installer' }
    It 'is unknown for an empty path' { Get-Method '' | Should -Be 'unknown' }
}

Describe 'Get-Kind' {
    It 'calls the cursor launcher an editor' {
        Get-Kind -Path 'C:\Users\x\AppData\Local\Programs\cursor\resources\app\bin\cursor.cmd' -Name 'cursor' | Should -Be 'editor'
    }
    It 'calls windsurf an editor by name' { Get-Kind -Path 'C:\x\windsurf.exe' -Name 'windsurf' | Should -Be 'editor' }
    It 'calls claude a cli' { Get-Kind -Path 'C:\x\claude.exe' -Name 'claude' | Should -Be 'cli' }
}
