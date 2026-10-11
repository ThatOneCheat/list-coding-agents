<#
.SYNOPSIS
    Builds, lints and tests list-coding-agents.

.DESCRIPTION
    Build (default): bundles src/ListCodingAgents (code, data/catalog.json and
    the report assets) into the single self-contained list-coding-agents.ps1
    at the repository root. The output is deterministic - same input, same
    bytes, on every OS and PowerShell edition - so CI can fail when the
    committed bundle differs from a fresh build.

    Lint: PSScriptAnalyzer with PSScriptAnalyzerSettings.psd1 over src/,
    build.ps1 and the bundle. Fails on any finding.

    Test: Pester (tests/). -Coverage adds line coverage for src/ and fails
    under 80%.

.PARAMETER Task
    Build, Lint, Test or All (Build, Lint, Test). Several tasks may be given
    as a comma-separated list.

.PARAMETER Coverage
    With Test: measure line coverage of src/ and enforce the 80% floor.

.PARAMETER OutputPath
    Where to write the bundle. Defaults to ./list-coding-agents.ps1.

.EXAMPLE
    pwsh -NoProfile -File ./build.ps1

.EXAMPLE
    pwsh -NoProfile -File ./build.ps1 -Task All -Coverage
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleCommands', '',
    Justification = 'build.ps1 is a development tool that requires the Pester module; it is not part of the shipped bundle.')]
[CmdletBinding()]
param(
    [string[]]$Task = @('Build'),
    [switch]$Coverage,
    [string]$OutputPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = $PSScriptRoot
$src = Join-Path -Path $repo -ChildPath 'src'
$moduleDir = Join-Path -Path $src -ChildPath 'ListCodingAgents'
if (-not $OutputPath) { $OutputPath = Join-Path -Path $repo -ChildPath 'list-coding-agents.ps1' }

function Get-RepoRelativePath {
    param([string]$Base, [string]$Path)
    $Path.Substring($Base.TrimEnd('\', '/').Length + 1).Replace('\', '/')
}

function Read-SourceText {
    <# UTF-8 text with LF line endings; fails on any non-ASCII character. #>
    param([string]$Path, [string]$Label)
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $text = $text.TrimStart([char]0xFEFF).Replace("`r`n", "`n")
    $bad = [regex]::Match($text, '[^\x09\x0A\x20-\x7E]')
    if ($bad.Success) {
        $line = ($text.Substring(0, $bad.Index) -split "`n").Count
        throw ("{0}:{1}: non-ASCII or control character U+{2:X4} (source files must be ASCII; use escapes)" -f $Label, $line, [int]$bad.Value[0])
    }
    if (-not $text.EndsWith("`n")) { $text += "`n" }
    $text
}

function Get-OrderedFile {
    <# Module files in load order: Private/** then Public/*, ordinal by relative path. #>
    param([string]$ModuleDir)
    $all = @(Get-ChildItem -LiteralPath (Join-Path -Path $ModuleDir -ChildPath 'Private') -Filter '*.ps1' -Recurse -File) +
    @(Get-ChildItem -LiteralPath (Join-Path -Path $ModuleDir -ChildPath 'Public') -Filter '*.ps1' -File)
    $items = foreach ($f in $all) {
        $rel = Get-RepoRelativePath -Base $ModuleDir -Path $f.FullName
        $rank = '1'
        if ($rel.StartsWith('Private/')) { $rank = '0' }
        [pscustomobject]@{ Key = ($rank + '|' + $rel.ToLowerInvariant()); Rel = $rel; Path = $f.FullName }
    }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($i in $items) { $list.Add($i) }
    $list.Sort([System.Comparison[object]] { param($a, $b) [string]::CompareOrdinal($a.Key, $b.Key) })
    $list.ToArray()
}

function Assert-InlinableFile {
    <#
    Module files are pasted into one New-Module script block: a top-level
    return / exit would stop loading the rest of the bundle, and param /
    using / #requires are only legal at the start of a file.
    #>
    param([string]$Path, [string]$Label)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count) { throw "${Label}: does not parse: $($errors[0].Message)" }
    if ($ast.ParamBlock) { throw "${Label}: top-level param() is not allowed in module files" }
    if ($ast.UsingStatements -and $ast.UsingStatements.Count) { throw "${Label}: top-level using statements are not allowed in module files" }
    if ($ast.ScriptRequirements) { throw "${Label}: #requires is not allowed in module files" }
    $blocks = @($ast.BeginBlock, $ast.ProcessBlock, $ast.EndBlock) | Where-Object { $_ }
    foreach ($b in $blocks) {
        foreach ($st in $b.Statements) {
            if ($st -is [System.Management.Automation.Language.ReturnStatementAst] -or $st -is [System.Management.Automation.Language.ExitStatementAst]) {
                throw ("{0}:{1}: top-level return/exit would stop the bundle from loading" -f $Label, $st.Extent.StartLineNumber)
            }
        }
    }
}

function ConvertTo-HereString {
    param([string]$Text, [string]$Label)
    foreach ($l in ($Text -split "`n")) {
        if ($l -match "^\s*'@") { throw "${Label}: a line starts with '@ and would end the embedding here-string" }
    }
    "@'`n" + $Text.TrimEnd("`n") + "`n'@"
}

function Invoke-Build {
    $entryPath = Join-Path -Path $src -ChildPath 'list-coding-agents.ps1'
    $entry = Read-SourceText -Path $entryPath -Label 'src/list-coding-agents.ps1'
    $startMarker = '#region LCA-MODULE'
    $endMarker = '#endregion LCA-MODULE'
    $s = $entry.IndexOf($startMarker)
    $e = $entry.IndexOf($endMarker)
    if ($s -lt 0 -or $e -lt $s) { throw 'entry script: LCA-MODULE region markers not found' }
    $head = $entry.Substring(0, $s)
    $tail = $entry.Substring($e + $endMarker.Length)

    $manifest = Import-PowerShellDataFile -Path (Join-Path -Path $moduleDir -ChildPath 'ListCodingAgents.psd1')
    $version = [string]$manifest.ModuleVersion

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append($head)
    [void]$sb.Append($startMarker + "`n")
    [void]$sb.Append("# list-coding-agents $version - generated by build.ps1 from src/ListCodingAgents.`n")
    [void]$sb.Append("# Do not edit this region by hand: edit src/ and run ./build.ps1.`n")
    [void]$sb.Append('$lcaModule = New-Module -Name ListCodingAgents -ScriptBlock {' + "`n")
    [void]$sb.Append("Set-StrictMode -Version Latest`n")
    [void]$sb.Append('$script:LcaModuleRoot = $null' + "`n")
    [void]$sb.Append('$script:LcaEmbeddedAssets = @{}' + "`n")
    [void]$sb.Append('$script:LcaEmbeddedBinary = @{}' + "`n")

    # text assets
    $textAssets = @('data/catalog.json', 'report/template.html', 'report/report.css', 'report/report.js', 'ListCodingAgents.format.ps1xml')
    foreach ($rel in $textAssets) {
        $p = Join-Path -Path $moduleDir -ChildPath $rel
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "missing asset $rel" }
        $t = Read-SourceText -Path $p -Label $rel
        [void]$sb.Append('$script:LcaEmbeddedAssets[''' + $rel + '''] = ' + (ConvertTo-HereString -Text $t -Label $rel) + "`n")
    }
    # binary assets (fonts), base64 wrapped at 120 columns
    $fontDir = Join-Path -Path $moduleDir -ChildPath 'report/fonts'
    if (Test-Path -LiteralPath $fontDir) {
        $fontList = New-Object System.Collections.Generic.List[object]
        foreach ($ff in @(Get-ChildItem -LiteralPath $fontDir -Filter '*.woff2' -File)) { $fontList.Add($ff) }
        $fontList.Sort([System.Comparison[object]] { param($a, $b) [string]::CompareOrdinal($a.Name, $b.Name) })
        foreach ($f in $fontList) {
            $rel = 'report/fonts/' + $f.Name
            $b64 = [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($f.FullName))
            $lines = New-Object System.Collections.Generic.List[string]
            for ($i = 0; $i -lt $b64.Length; $i += 120) { $lines.Add($b64.Substring($i, [Math]::Min(120, $b64.Length - $i))) }
            [void]$sb.Append('$script:LcaEmbeddedBinary[''' + $rel + '''] = ' + (ConvertTo-HereString -Text ($lines -join "`n") -Label $rel) + "`n")
        }
    }

    foreach ($f in Get-OrderedFile -ModuleDir $moduleDir) {
        $code = Read-SourceText -Path $f.Path -Label ('src/ListCodingAgents/' + $f.Rel)
        Assert-InlinableFile -Path $f.Path -Label ('src/ListCodingAgents/' + $f.Rel)
        [void]$sb.Append("# ---- " + $f.Rel + " ----`n")
        [void]$sb.Append($code)
    }
    [void]$sb.Append("Export-ModuleMember -Function @()`n")
    [void]$sb.Append("}`n")
    [void]$sb.Append($endMarker)
    [void]$sb.Append($tail)

    $out = $sb.ToString()
    $tmp = $OutputPath + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $out, (New-Object System.Text.UTF8Encoding($false)))
    # parse check before replacing the committed bundle
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($tmp, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count) {
        Remove-Item -LiteralPath $tmp -Force
        throw ('bundle does not parse: ' + ($errors | Select-Object -First 3 | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ')
    }
    Move-Item -LiteralPath $tmp -Destination $OutputPath -Force
    $kb = [math]::Round((Get-Item -LiteralPath $OutputPath).Length / 1KB, 1)
    Write-Output ("built {0} ({1} KB, version {2})" -f $OutputPath, $kb, $version)
}

function Invoke-Lint {
    $settings = Join-Path -Path $repo -ChildPath 'PSScriptAnalyzerSettings.psd1'
    $targets = @(
        @{ Path = $src; Recurse = $true },
        @{ Path = (Join-Path -Path $repo -ChildPath 'build.ps1'); Recurse = $false },
        @{ Path = $OutputPath; Recurse = $false }
    )
    $all = New-Object System.Collections.Generic.List[object]
    foreach ($t in $targets) {
        $r = @(Invoke-ScriptAnalyzer -Path $t.Path -Recurse:$t.Recurse -Settings $settings)
        foreach ($x in $r) { $all.Add($x) }
    }
    foreach ($x in $all) {
        Write-Output ("{0}:{1} [{2}] {3}: {4}" -f $x.ScriptPath, $x.Line, $x.Severity, $x.RuleName, $x.Message)
    }
    Write-Output ("lint: {0} finding(s)" -f $all.Count)
    if ($all.Count -gt 0) { throw "PSScriptAnalyzer reported $($all.Count) finding(s)" }
}

function Invoke-Test {
    param([bool]$WithCoverage)
    # test files manage their own strictness and error handling; do not leak
    # build.ps1's into them
    Set-StrictMode -Off
    $ErrorActionPreference = 'Continue'
    $cfg = New-PesterConfiguration
    $cfg.Run.Path = (Join-Path -Path $repo -ChildPath 'tests')
    $cfg.Run.Exit = $false
    $cfg.Run.PassThru = $true
    $cfg.Output.Verbosity = 'Normal'
    $cfg.TestResult.Enabled = $true
    $cfg.TestResult.OutputPath = (Join-Path -Path $repo -ChildPath 'testResults.xml')
    if ($WithCoverage) {
        $cfg.CodeCoverage.Enabled = $true
        $cfg.CodeCoverage.Path = @($moduleDir)
        $cfg.CodeCoverage.RecursePaths = $true
        $cfg.CodeCoverage.UseBreakpoints = $false
        $cfg.CodeCoverage.OutputPath = (Join-Path -Path $repo -ChildPath 'coverage.xml')
        $cfg.CodeCoverage.CoveragePercentTarget = 80
    }
    $result = Invoke-Pester -Configuration $cfg
    if ($result.FailedCount -gt 0 -or $result.Result -ne 'Passed') {
        throw ("Pester: {0} failed, {1} passed" -f $result.FailedCount, $result.PassedCount)
    }
    if ($WithCoverage) {
        $pct = [math]::Round($result.CodeCoverage.CoveragePercent, 1)
        Write-Output ("coverage: {0}% of src/" -f $pct)
        if ($pct -lt 80) { throw "line coverage $pct% is below 80%" }
    }
}

# "-Task Build,Lint" arrives as one string under pwsh -File
$plan = @($Task | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
foreach ($t in $plan) {
    if (@('Build', 'Lint', 'Test', 'All') -notcontains $t) { throw "unknown task '$t' (Build, Lint, Test, All)" }
}
if ($plan -contains 'All') { $plan = @('Build', 'Lint', 'Test') }
foreach ($t in $plan) {
    switch ($t) {
        'Build' { Invoke-Build }
        'Lint' { Invoke-Lint }
        'Test' { Invoke-Test -WithCoverage $Coverage.IsPresent }
    }
}
