@{
    RootModule           = 'ListCodingAgents.psm1'
    ModuleVersion        = '2.0.0'
    GUID                 = '6f2e4d0a-4c55-4f1e-9a8e-2b7c1d3e5a90'
    Author               = 'thatonecheat'
    CompanyName          = 'thatonecheat'
    Copyright            = '(c) thatonecheat. MIT License.'
    Description          = 'Finds the AI coding agents (Claude Code, Codex, Gemini CLI, Copilot CLI, aider, ...) installed on a machine: versions, install footprint, usage, updates, and a self-contained HTML report.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FormatsToProcess     = @('ListCodingAgents.format.ps1xml')
    FunctionsToExport    = @('Get-CodingAgent', 'Update-CodingAgent', 'Export-CodingAgentReport')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags         = @('ai', 'coding-agent', 'claude', 'codex', 'copilot', 'inventory', 'Windows', 'Linux', 'MacOS', 'PSEdition_Desktop', 'PSEdition_Core')
            LicenseUri   = 'https://github.com/thatonecheat/list-coding-agents/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/thatonecheat/list-coding-agents'
            ReleaseNotes = 'https://github.com/thatonecheat/list-coding-agents/blob/main/CHANGELOG.md'
        }
    }
}
