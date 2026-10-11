# Pulls the helper functions + lexicon variables out of list-coding-agents.ps1
# WITHOUT running the scan, so the tests can poke at them one at a time.
# Dot-source it from a test:   . "$PSScriptRoot\Import-ScriptFunctions.ps1"
param(
    [string]$ScriptPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'list-coding-agents.ps1')
)
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
if ($errors -and $errors.Count) { throw "cannot parse $ScriptPath : $($errors[0].Message)" }

# script-level variables the functions read (the lexicons and regexes up top)
$wanted = 'KnownCli', 'AmbiguousCli', 'PathSignatures', 'AiVendors', 'AiSdkDep',
          'BrandWords', 'BrandCmdRx', 'AgentPhrase', 'HardExclude'
foreach ($st in $ast.EndBlock.Statements) {
    if ($st -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
        . ([scriptblock]::Create($st.Extent.Text))
        continue
    }
    if ($st -is [System.Management.Automation.Language.AssignmentStatementAst]) {
        $v = $st.Left.Extent.Text.TrimStart('$')
        if ($wanted -contains $v) { . ([scriptblock]::Create($st.Extent.Text)) }
    }
}
