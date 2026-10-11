<#
.SYNOPSIS
    Finds the AI coding agents installed on this machine - Claude Code, Codex,
    Gemini CLI, Copilot CLI, aider, opencode and friends - and reports their
    versions, disk footprint, usage and available updates.

.DESCRIPTION
    No hand-maintained product list is required: a catalog of known agents is
    combined with heuristics, so new agents are recognised as long as they
    leave a normal trace (package metadata, embedded version info, a winget
    publisher, a recognisable name).

    Sources: every command on PATH, npm / pnpm / bun global packages, pipx /
    uv / pip user installs, cargo, Homebrew, scoop, choco, winget, the Windows
    Uninstall registry and VS Code-family extension folders. Windows-only
    sources switch off on macOS and Linux.

    Results are tiered by confidence:
      DETECTED  (score >= 4) - high confidence, grouped by install channel
      POSSIBLE  (score 2-3)  - weak signal, listed for you to review

    Each agent is enriched with its installed version, install and data
    footprint, last use, MCP servers (names only), whether credentials exist
    (file and key NAMES only - secret values are never read out), PATH
    conflicts, and with -CheckUpdates the latest version plus the exact
    update command.

    The script remembers previous scans in a state directory (Windows:
    %LOCALAPPDATA%\list-coding-agents, macOS: ~/Library/Application
    Support/list-coding-agents, Linux: ${XDG_STATE_HOME:-~/.local/state}/
    list-coding-agents): it reports new and removed agents and version bumps
    and draws a trend line in the HTML report.

    Override lists, one command name per line, '#' starts a comment. They are
    read from next to this script and from the config directory (Windows:
    %APPDATA%\list-coding-agents, macOS: ~/Library/Application
    Support/list-coding-agents, Linux: ${XDG_CONFIG_HOME:-~/.config}/
    list-coding-agents):
      agents-extra.txt    force a name IN  (agents no heuristic can see)
      agents-exclude.txt  force a name OUT (false positives; wins over extra)

    Exit codes: 0 success, 1 unexpected error, 2 invalid arguments,
    3 a -FailOn condition matched, 4 an update failed (-UpdateAll).

.PARAMETER IncludeEditors
    Also include GUI AI editors (Cursor, Windsurf, Kiro, Trae, Zed ...).

.PARAMETER ShowReasons
    Print the signals that triggered each detection.

.PARAMETER NoHtml
    Skip writing (and opening) the HTML report.

.PARAMETER SkipWinget
    Skip the winget package scan (faster when you already know it adds
    nothing). This makes the run a partial scan: winget-only agents are
    carried over from the last full scan rather than reported as removed,
    and no trend point is recorded (its totals would understate the fleet).

.PARAMETER CheckUpdates
    Ask each agent's package manager (npm, pnpm, bun, pipx, uv, pip, cargo,
    scoop, choco, winget, brew) for newer versions and show the update
    command. Status is current, outdated or unknown (with the reason).

.PARAMETER UpdateAll
    Implies -CheckUpdates, then runs every update command. Asks for
    confirmation unless -Force is given; supports -WhatIf and -Confirm.
    Prints each agent's version before -> after.

.PARAMETER Json
    Also write the full result set to coding-agents.json in -OutDir
    (schema: schema/coding-agents.schema.json).

.PARAMETER IncludeExtensions
    Also include AI coding extensions installed in VS Code-family editors
    (VS Code, Insiders, VSCodium, Cursor, Windsurf ...).

.PARAMETER All
    Same as -IncludeEditors -IncludeExtensions.

.PARAMETER Explain
    Print the full scoring breakdown for one command or package name,
    including why it was excluded.

.PARAMETER NoProbe
    Never run "<agent> --version" to discover a version.

.PARAMETER NoOpen
    Write the HTML report but do not open it (CI, SSH, headless runs).

.PARAMETER OutDir
    Folder for coding-agents.html and coding-agents.json. Defaults to the
    current directory.

.PARAMETER PassThru
    Also emit one ListCodingAgents.Agent object per agent to the pipeline.

.PARAMETER Format
    Write the results to stdout as table, json, csv or markdown (the
    coloured terminal report is skipped).

.PARAMETER Quiet
    Print nothing except errors (and -Format / -PassThru output).

.PARAMETER NoColor
    Plain terminal output without colours. The NO_COLOR environment
    variable has the same effect.

.PARAMETER Redact
    Strip your user name and host name from the generated JSON and HTML,
    for sharing the files.

.PARAMETER FailOn
    Exit with code 3 when any listed condition is present: outdated, stale,
    conflict, new. For CI.

.PARAMETER Version
    Print the list-coding-agents version and exit.

.PARAMETER Force
    With -UpdateAll: run the updates without asking (non-interactive runs).

.EXAMPLE
    .\list-coding-agents.ps1

.EXAMPLE
    .\list-coding-agents.ps1 -CheckUpdates -NoOpen

.EXAMPLE
    .\list-coding-agents.ps1 -UpdateAll -WhatIf

.EXAMPLE
    .\list-coding-agents.ps1 -Explain sg

.EXAMPLE
    .\list-coding-agents.ps1 -Format json -Quiet | ConvertFrom-Json

.LINK
    https://github.com/thatonecheat/list-coding-agents
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium', PositionalBinding = $false)]
param(
    [switch]$IncludeEditors,
    [switch]$ShowReasons,
    [switch]$NoHtml,
    [switch]$SkipWinget,
    [switch]$CheckUpdates,
    [switch]$UpdateAll,
    [switch]$Json,
    [switch]$IncludeExtensions,
    [switch]$All,
    [string]$Explain,
    [switch]$NoProbe,
    [switch]$NoOpen,
    [string]$OutDir,
    [switch]$PassThru,
    [string]$Format,
    [switch]$Quiet,
    [switch]$NoColor,
    [switch]$Redact,
    [string[]]$FailOn,
    [switch]$Version,
    [switch]$Force
)

#region LCA-MODULE
# Development entry point: loads the module from src/. build.ps1 replaces
# this region with the whole module inlined, so the released script is a
# single self-contained file.
$lcaModule = Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'ListCodingAgents/ListCodingAgents.psd1') -Force -PassThru
#endregion LCA-MODULE

# No ValidateSet attributes above: under "irm ... | iex" PowerShell assigns
# each parameter its default and then applies the attributes, so a
# ValidateSet would reject the empty default and abort the whole run.
# -Format / -FailOn are validated inside (bad values exit with code 2).
$lcaBound = @{}
foreach ($lcaKey in $PSBoundParameters.Keys) { $lcaBound[$lcaKey] = $PSBoundParameters[$lcaKey] }
if ($WhatIfPreference -and -not $lcaBound.ContainsKey('WhatIf')) { $lcaBound['WhatIf'] = [switch]$true }
& $lcaModule { param($b, $r) Invoke-LcaCli -BoundParameters $b -ScriptRoot $r } $lcaBound $PSScriptRoot
$lcaExit = & $lcaModule { $script:LcaLastExitCode }
Remove-Variable -Name lcaModule, lcaBound, lcaKey -ErrorAction Ignore
# Under "irm ... | iex" there is no script file: never call exit there, it
# would close the user's shell.
if ($PSCommandPath -and $lcaExit -ne 0) { exit $lcaExit }
Remove-Variable -Name lcaExit -ErrorAction Ignore
