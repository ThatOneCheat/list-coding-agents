# Guards that PSScriptAnalyzer cannot provide:
#  * Windows PowerShell 5.1 syntax/API gaps it misses (?. / ?[], multi-child
#    Join-Path, clean {}, $IsWindows, .NET Core-only members);
#  * the provider seam: only Private/Platform/ may read $env:, call Get-Date,
#    start processes or run package managers;
#  * every source file is ASCII (5.1 reads BOM-less files as ANSI).

BeforeDiscovery {
    $root = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '../..')).ProviderPath
    $codeFiles = @(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1') +
    @(Get-Item -LiteralPath (Join-Path $root 'build.ps1')) +
    @(Get-ChildItem -LiteralPath (Join-Path $root 'list-coding-agents.ps1') -ErrorAction SilentlyContinue)
    $script:CodeCases = @($codeFiles | ForEach-Object { @{ Path = $_.FullName; Rel = $_.FullName.Substring($root.Length + 1).Replace('\', '/') } })
    $seamFiles = @(Get-ChildItem -LiteralPath (Join-Path $root 'src/ListCodingAgents') -Recurse -File -Filter '*.ps1' |
            Where-Object { $_.FullName.Replace('\', '/') -notmatch '/Private/Platform/' })
    $script:SeamCases = @($seamFiles | ForEach-Object { @{ Path = $_.FullName; Rel = $_.FullName.Substring($root.Length + 1).Replace('\', '/') } })
    $textFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File |
            Where-Object {
                $rel = $_.FullName.Substring($root.Length + 1).Replace('\', '/')
                $rel -notmatch '^(\.git/|tests/report/node_modules/|docs/recon/)' -and
                $_.Extension -match '^\.(ps1|psm1|psd1|ps1xml|json|html|css|js|cmd|yml|yaml)$'
            })
    $script:AsciiCases = @($textFiles | ForEach-Object { @{ Path = $_.FullName; Rel = $_.FullName.Substring($root.Length + 1).Replace('\', '/') } })
}

BeforeAll {
    function Get-TestAst {
        param([string]$Path)
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        [pscustomobject]@{ Ast = $ast; Errors = @($errors) }
    }
    function Find-TestNode {
        param($Ast, [scriptblock]$Predicate)
        @($Ast.FindAll($Predicate, $true))
    }
    function Get-CommandNameOf {
        param($CommandAst)
        $n = $CommandAst.GetCommandName()
        if ($n) { return $n.ToLowerInvariant() }
        ''
    }
    function Test-HasParameter {
        param($CommandAst, [string[]]$Name)
        foreach ($e in $CommandAst.CommandElements) {
            if ($e -is [System.Management.Automation.Language.CommandParameterAst]) {
                foreach ($n in $Name) {
                    if ($n.StartsWith($e.ParameterName, [StringComparison]::OrdinalIgnoreCase) -and $e.ParameterName.Length -ge 3) { return $true }
                }
            }
        }
        $false
    }
    function Format-Hit {
        param($Nodes)
        (@($Nodes) | Where-Object { $_ } | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Extent.Text.Split("`n")[0])" }) -join '; '
    }
}

Describe 'Windows PowerShell 5.1 compatibility' {
    It '<Rel> parses' -TestCases $script:CodeCases {
        param($Path, $Rel)
        $r = Get-TestAst -Path $Path
        $r.Errors.Count | Should -Be 0 -Because ($r.Errors | Select-Object -First 1 | Out-String)
    }

    It '<Rel> uses no 7.x-only operators' -TestCases $script:CodeCases {
        param($Path, $Rel)
        $ast = (Get-TestAst -Path $Path).Ast
        $hits = @(Find-TestNode $ast {
            param($n)
            $t = $n.GetType().Name
            if ($t -eq 'TernaryExpressionAst' -or $t -eq 'PipelineChainAst') { return $true }
            if ($n -is [System.Management.Automation.Language.BinaryExpressionAst] -and "$($n.Operator)" -eq 'QuestionQuestion') { return $true }
            if ($n -is [System.Management.Automation.Language.AssignmentStatementAst] -and "$($n.Operator)" -eq 'QuestionQuestionEquals') { return $true }
            $nc = $n.PSObject.Properties['NullConditional']
            if ($nc -and $nc.Value) { return $true }
            if ($n -is [System.Management.Automation.Language.NamedBlockAst] -and "$($n.BlockKind)" -eq 'Clean') { return $true }
            $false
        })
        $hits.Count | Should -Be 0 -Because (Format-Hit $hits)
    }

    It '<Rel> avoids 7.x-only cmdlet parameters' -TestCases $script:CodeCases {
        param($Path, $Rel)
        $ast = (Get-TestAst -Path $Path).Ast
        $hits = @(Find-TestNode $ast {
            param($n)
            if ($n -isnot [System.Management.Automation.Language.CommandAst]) { return $false }
            $c = Get-CommandNameOf $n
            switch ($c) {
                { $_ -in 'foreach-object', '%', 'foreach' } { return (Test-HasParameter $n 'Parallel') }
                'convertfrom-json' { return (Test-HasParameter $n 'AsHashtable', 'Depth', 'NoEnumerate') }
                'convertto-json' { return (Test-HasParameter $n 'AsArray', 'EnumsAsStrings', 'EscapeHandling') }
                'get-content' { return (Test-HasParameter $n 'AsByteStream') }
                'join-path' {
                    if (Test-HasParameter $n 'AdditionalChildPath') { return $true }
                    $positional = @($n.CommandElements | Select-Object -Skip 1 | Where-Object { $_ -isnot [System.Management.Automation.Language.CommandParameterAst] })
                    $named = @($n.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] })
                    return ($positional.Count - $named.Count) -gt 2
                }
                { $_ -in 'test-json', 'start-threadjob', 'get-error', 'foreach-object -parallel' } { return $true }
                default {
                    if ($c -in 'out-file', 'set-content', 'add-content') {
                        return ($n.Extent.Text -match '(?i)-Encoding\s+[''"]?(utf8NoBOM|utf8BOM)')
                    }
                    return $false
                }
            }
        })
        $hits.Count | Should -Be 0 -Because (Format-Hit $hits)
    }

    It '<Rel> avoids variables and .NET members missing on 5.1' -TestCases $script:CodeCases {
        param($Path, $Rel)
        $ast = (Get-TestAst -Path $Path).Ast
        $hits = @(Find-TestNode $ast {
            param($n)
            if ($n -is [System.Management.Automation.Language.VariableExpressionAst]) {
                return ($n.VariablePath.UserPath -in 'IsWindows', 'IsLinux', 'IsMacOS', 'IsCoreCLR', 'PSStyle')
            }
            if ($n -is [System.Management.Automation.Language.MemberExpressionAst] -and $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $m = $n.Member.Value
                if ($m -eq 'ArgumentList' -and -not $n.Static) { return $true }       # ProcessStartInfo.ArgumentList (.NET Core)
                if ($m -eq 'GetRelativePath' -and $n.Static) { return $true }
                if ($m -eq 'Kill' -and $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Arguments -and $n.Arguments.Count -gt 0) { return $true }
            }
            $false
        })
        $hits.Count | Should -Be 0 -Because (Format-Hit $hits)
    }
}

Describe 'Provider seam' {
    It '<Rel> reads the outside world only through Private/Platform' -TestCases $script:SeamCases {
        param($Path, $Rel)
        $ast = (Get-TestAst -Path $Path).Ast
        $tools = @('npm', 'pnpm', 'bun', 'pipx', 'uv', 'pip', 'pip3', 'cargo', 'brew', 'scoop', 'choco', 'winget', 'code', 'git', 'taskkill', 'cmd', 'powershell', 'pwsh')
        $hits = @(Find-TestNode $ast {
            param($n)
            if ($n -is [System.Management.Automation.Language.VariableExpressionAst]) {
                return ($n.VariablePath.DriveName -eq 'env')
            }
            if ($n -is [System.Management.Automation.Language.CommandAst]) {
                $c = Get-CommandNameOf $n
                if ($c -in 'get-date', 'start-process', 'start-job', 'invoke-expression', 'iex', 'invoke-webrequest', 'invoke-restmethod') { return $true }
                if ($c -in $tools -or ($c -match '\.(exe|cmd|bat)$')) { return $true }
                if ($n.InvocationOperator -ne 'Unknown' -and $n.CommandElements[0] -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                    $n.CommandElements[0].Value.ToLowerInvariant() -in $tools) { return $true }
                return $false
            }
            if ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Static -and $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $type = $n.Expression.Extent.Text
                $m = $n.Member.Value
                if ($type -match '(?i)Environment\]$' -and $m -match '^(GetEnvironmentVariable|GetEnvironmentVariables|GetFolderPath)$') { return $true }
                if ($type -match '(?i)Diagnostics\.Process\]$' -and $m -eq 'Start') { return $true }
                if ($type -match '(?i)(DateTime|DateTimeOffset)\]$' -and $m -match '^(get_)?(Now|UtcNow)$') { return $true }
            }
            if ($n -is [System.Management.Automation.Language.MemberExpressionAst] -and $n.Static -and $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $type = $n.Expression.Extent.Text
                if ($type -match '(?i)(DateTime|DateTimeOffset)\]$' -and $n.Member.Value -match '^(Now|UtcNow|Today)$') { return $true }
            }
            $false
        })
        $hits.Count | Should -Be 0 -Because (Format-Hit $hits)
    }
}

Describe 'Source encoding' {
    It '<Rel> is ASCII' -TestCases $script:AsciiCases {
        param($Path, $Rel)
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $bad = -1
        for ($i = 0; $i -lt $bytes.Length; $i++) { if ($bytes[$i] -gt 127) { $bad = $i; break } }
        $bad | Should -Be -1 -Because "byte offset $bad is not ASCII"
    }
}
