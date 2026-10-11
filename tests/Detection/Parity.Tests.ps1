# Parity with v1 (tests/fixtures/v1/list-coding-agents.v1.ps1, frozen at
# 8d05c16). v1's scorer, lexicons and Get-Method / Get-Kind are loaded
# straight out of the v1 script with the AST and run side by side with v2
# over a grid of inputs.
#
# Contract: a command that is NOT in the v2 catalog must score exactly as
# v1 scored it (same score, same reasons). Catalog commands may score
# differently only where $IntentionalTierChanges says why - those are
# deliberate false-positive / false-negative fixes listed in CHANGELOG.md.

BeforeAll {
    . (Join-Path $PSScriptRoot '../Helpers/Bootstrap.ps1')
    $v1Path = Join-Path $RepoRoot 'tests/fixtures/v1/list-coding-agents.v1.ps1'
    $tokens = $null; $errors = $null
    $v1Ast = [System.Management.Automation.Language.Parser]::ParseFile($v1Path, [ref]$tokens, [ref]$errors)
    $want = 'KnownCli', 'AmbiguousCli', 'PathSignatures', 'AiVendors', 'AiSdkDep', 'BrandWords', 'BrandCmdRx', 'AgentPhrase', 'HardExclude'
    $assigns = $v1Ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $n.Left.VariablePath.UserPath -in $want -and $n.Parent.Parent -eq $v1Ast
        }, $true)
    $fns = $v1Ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in 'Get-AgentScore', 'Get-Method', 'Get-Kind'
        }, $true)
    $v1Code = (@($assigns | ForEach-Object { $_.Extent.Text }) + @($fns | ForEach-Object { $_.Extent.Text })) -join "`n"
    # One closure holds v1's lexicons and functions.
    $script:V1 = New-Module -Name LcaV1Parity -ScriptBlock ([scriptblock]::Create($v1Code + "`nExport-ModuleMember -Function * -Variable *"))

    # Inputs: names x texts x deps x publishers x Windows paths.
    $script:Names = @(
        'claude', 'codex', 'gemini', 'goose', 'copilot', 'kilo', 'mux', 'hermes', 'cursor-agent', 'windsurf', 'kiro', 'trae',
        'sg', 'src', 'amp', 'pi', 'vibe', 'continue', 'roo',
        'kimi-cli', 'claude-code', 'qwen-code', 'gemini-agent', 'codex_cli', 'grok-cli', 'cursor', 'antigravity', 'gpt', 'llm',
        'eslint', 'prettier', 'tsc', 'ts-node', 'nodemon', 'serve', 'http-server', 'playwright', 'pnpm', 'yarn', 'corepack', 'chromedriver',
        'gh', 'az', 'aws', 'gcloud', 'docker', 'kubectl', 'terraform', 'forge', 'ollama', 'agy', 'cn', 'q', 'aider-chat',
        'mcp-server-git', 'foo-mcp', 'mcp', 'claude-launcher', 'codex-updater', 'sg-updater', 'amp-mcp-server', 'uninstall', 'node', 'bun',
        'my-agent', 'devagent', 'ai', 'agent', 'helper'
    )
    $script:Texts = @(
        '',
        'An agentic coding tool that lives in your terminal',
        'AI coding agent for the terminal',
        'Claude Code CLI',
        'Model Context Protocol server for git',
        'CLI to install the claude skill for agents',
        'A fast linter for JavaScript',
        'deployment tool',
        'AI pair programming in your terminal',
        'terminal agent for devs',
        'OpenAI Codex CLI',
        'Sourcegraph code search',
        'ai cli helper'
    )
    $script:DepSets = @(
        , @()
        , @('@anthropic-ai/sdk')
        , @('openai', 'chalk')
        , @('@modelcontextprotocol/sdk')
        , @('langchain')
        , @('ai')
    )
    $script:Publishers = @('', 'Anthropic PBC', 'OpenAI', 'Node.js', 'Microsoft Corporation', 'Oven', 'Sourcegraph')
    $script:Paths = @(
        '',
        'C:\Users\u\AppData\Roaming\npm\{0}.cmd',
        'C:\Users\u\.local\bin\{0}.exe',
        'C:\Users\u\.local\bin\claude.exe',
        'C:\Users\u\AppData\Local\Programs\cursor\resources\app\bin\{0}.cmd',
        'C:\Users\u\.kimi-code\bin\{0}.exe',
        'C:\Program Files\OpenAI\Codex\{0}.exe',
        'C:\Users\u\scoop\shims\{0}.exe',
        'C:\Users\u\.cargo\bin\{0}.exe',
        'C:\Users\u\.bun\bin\{0}.exe',
        'C:\Users\u\AppData\Local\Microsoft\WindowsApps\{0}.exe',
        'C:\Users\u\AppData\Roaming\Python\Python312\Scripts\{0}.exe',
        'C:\Users\u\pipx\venvs\x\{0}.exe',
        'C:\tools\anthropic\{0}.exe',
        'Anthropic.Claude'
    )

    # Catalog commands whose tier may differ from v1, and why. Every entry
    # here must also be explained in CHANGELOG.md.
    $script:IntentionalTierChanges = @{}

    $script:CatalogCommands = InModuleScope ListCodingAgents {
        $m = Get-LcaScoringModel -Catalog (Get-LcaCatalog) -Force
        @($m.KnownCommands) + @($m.AmbiguousCommands)
    }
}

Describe 'Scorer parity with v1' {
    It 'scores every non-catalog input exactly like v1' {
        # names x texts x paths, cycling dependencies and publishers; both
        # scorers run in one batch each (InModuleScope per call is slow).
        $inputs = New-Object System.Collections.Generic.List[object]
        $i = 0
        foreach ($n in $script:Names) {
            if ($script:CatalogCommands -contains $n) { continue }
            foreach ($t in $script:Texts) {
                foreach ($pt in $script:Paths) {
                    $inputs.Add([pscustomobject]@{
                            Name = $n; Text = $t; Path = ($pt -f $n)
                            Deps = @($script:DepSets[$i % $script:DepSets.Count])
                            Publisher = $script:Publishers[[int][math]::Floor($i / 3) % $script:Publishers.Count]
                        })
                    $i++
                }
            }
        }
        $v1 = & $script:V1 {
            param($In)
            foreach ($x in $In) { Get-AgentScore -Text $x.Text -Deps $x.Deps -Publisher $x.Publisher -Name $x.Name -Path $x.Path }
        } $inputs
        $v2 = & (Get-Module ListCodingAgents) {
            param($In)
            $m = Get-LcaScoringModel -Catalog (Get-LcaCatalog)
            foreach ($x in $In) { Get-LcaAgentScore -Text $x.Text -Deps $x.Deps -Publisher $x.Publisher -Name $x.Name -Path $x.Path -Model $m }
        } $inputs
        $v1 = @($v1); $v2 = @($v2)
        $v1.Count | Should -Be $inputs.Count
        $v2.Count | Should -Be $inputs.Count
        $inputs.Count | Should -BeGreaterThan 5000
        $mismatch = New-Object System.Collections.Generic.List[string]
        for ($k = 0; $k -lt $inputs.Count; $k++) {
            if ($v1[$k].Score -ne $v2[$k].Score -or $v1[$k].Why -ne $v2[$k].Why) {
                $x = $inputs[$k]
                $mismatch.Add("$($x.Name) | $($x.Text) | $($x.Deps -join ',') | $($x.Publisher) | $($x.Path) :: v1=$($v1[$k].Score) [$($v1[$k].Why)] v2=$($v2[$k].Score) [$($v2[$k].Why)]")
            }
        }
        $mismatch.Count | Should -Be 0 -Because (($mismatch | Select-Object -First 5) -join "`n")
    }

    It 'keeps the v1 tier for catalog commands unless the change is intentional' {
        $model = InModuleScope ListCodingAgents { Get-LcaScoringModel -Catalog (Get-LcaCatalog) }
        $diffs = New-Object System.Collections.Generic.List[string]
        foreach ($n in $script:CatalogCommands) {
            foreach ($t in @('', 'AI coding agent for the terminal', 'A fast linter for JavaScript')) {
                foreach ($pt in @('', 'C:\Users\u\AppData\Roaming\npm\{0}.cmd', 'C:\Users\u\.local\bin\{0}.exe')) {
                    $path = $pt -f $n
                    $v1 = & $script:V1 { param($a, $c, $e) Get-AgentScore -Text $a -Deps @() -Publisher '' -Name $c -Path $e } $t $n $path
                    $v2 = InModuleScope ListCodingAgents -Parameters @{ T = $t; N = $n; Pa = $path; M = $model } {
                        param($T, $N, $Pa, $M)
                        $s = Get-LcaAgentScore -Text $T -Deps @() -Publisher '' -Name $N -Path $Pa -Model $M
                        Get-LcaTier -Score $s.Score -Model $M
                    }
                    $v1Tier = if ($v1.Score -ge 4) { 'detected' } elseif ($v1.Score -ge 2) { 'possible' } else { 'excluded' }
                    if ($v1Tier -ne $v2 -and -not $script:IntentionalTierChanges.ContainsKey($n)) {
                        $diffs.Add("$n | $t | $path :: v1=$v1Tier v2=$v2")
                    }
                }
            }
        }
        $diffs.Count | Should -Be 0 -Because (($diffs | Select-Object -First 5) -join "`n")
    }
}

Describe 'Install channel and kind parity with v1' {
    It 'labels Windows install paths like v1' {
        $diffs = New-Object System.Collections.Generic.List[string]
        foreach ($pt in $script:Paths) {
            foreach ($n in @('claude', 'cursor', 'tool')) {
                $path = $pt -f $n
                $v1m = & $script:V1 { param($p) Get-Method -Path $p } $path
                $v1k = & $script:V1 { param($p, $n2) Get-Kind -Path $p -Name $n2 } $path $n
                $v2 = InModuleScope ListCodingAgents -Parameters @{ P = $path; N = $n } {
                    param($P, $N)
                    [pscustomobject]@{ Method = (Get-LcaInstallChannel -Path $P).Method; Kind = (Get-LcaAgentKind -Path $P -Name $N) }
                }
                if ($v1m -ne $v2.Method -or $v1k -ne $v2.Kind) { $diffs.Add("$path ($n) :: v1=$v1m/$v1k v2=$($v2.Method)/$($v2.Kind)") }
            }
        }
        $diffs.Count | Should -Be 0 -Because (($diffs | Select-Object -First 5) -join "`n")
    }
}
