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
    [ValidateSet('table', 'json', 'csv', 'markdown')][string]$Format,
    [switch]$Quiet,
    [switch]$NoColor,
    [switch]$Redact,
    [ValidateSet('outdated', 'stale', 'conflict', 'new')][string[]]$FailOn,
    [switch]$Version,
    [switch]$Force
)

#region LCA-MODULE
# list-coding-agents 2.0.0 - generated by build.ps1 from src/ListCodingAgents.
# Do not edit this region by hand: edit src/ and run ./build.ps1.
$lcaModule = New-Module -Name ListCodingAgents -ScriptBlock {
Set-StrictMode -Version Latest
$script:LcaModuleRoot = $null
$script:LcaEmbeddedAssets = @{}
$script:LcaEmbeddedBinary = @{}
$script:LcaEmbeddedAssets['data/catalog.json'] = @'
{
  "catalogVersion": 1,
  "scoring": {
    "thresholds": {
      "detected": 4,
      "possible": 2
    },
    "weights": {
      "knownCommand": 6,
      "ambiguousCommand": 2,
      "pathSignature": 3,
      "agentPhrase": 4,
      "aiVendor": 3,
      "aiSdkDependency": 3,
      "agentPlusCode": 2,
      "brandName": 1,
      "brandPlusCli": 2,
      "brandCommand": 2,
      "aiPlusCode": 1,
      "extraOverride": 5,
      "excluded": -99
    },
    "lexicons": {
      "aiVendors": "anthropic|openai|moonshot|mistral|cohere|sourcegraph|augment(code)?|codeium|anysphere|factory|\\bsst\\b|kilocode|perplexity|deepseek|\\bxai\\b|bytedance|tencent|all[- ]?hands|nous(\\s?research)?|letta",
      "aiSdkDependency": "(?i)@anthropic-ai/|(^|/)openai(@|/|$)|@google/genai|generative-ai|langchain|ollama|@ai-sdk/|^ai$|mistralai|@google/generative-ai",
      "brandWords": "claude|gemini|copilot|codex|aider|cody|goose|opencode|openclaw|cline|roo[- ]?code|droid|crush|qwen|grok|kimi|antigravity|blackbox|windsurf|cursor|kiro|mimo|jcode|vibe|\\bgpt\\b|\\bllm\\b|kilocode|factory|openhands|codebuddy|iflow|mux|trae|zencoder|hermes|letta",
      "brandCommandSuffix": "(?:[-_]?(?:cli|code|agent))?",
      "agentPhrase": "coding[- ]?agent|code[- ]?agent|agentic|ai[- ]?coding|ai pair|pair program|autonomous (coding|software|dev)|ai software engineer|terminal.*agent|ai[- ]?powered coding|coding assistant",
      "hardExclude": "(?i)install .*skill|skill for|\\bdeploy(ment)?\\b|package manager|boilerplate|scaffold|video extension|image extension|redistributable|driver|\\bmcp[- ]?server\\b|^mcp\\b|\\bmodel context protocol\\b",
      "skillInstaller": "(?i)install .*skill|skill for",
      "mcpUtilityName": "(?i)(^|-)mcp($|-)|-mcp-server$|^mcp-",
      "helperName": "(?i)(launcher|host|helper|shim|wrapper|updater|unins)",
      "vendorPublisherIgnore": "(?i)^(Node\\.js|Oven|Microsoft Corporation)$",
      "agentWord": "\\bagent\\b",
      "agentContext": "code|coding|cli|terminal|dev",
      "brandContext": "cli|code|coding|terminal|assistant",
      "aiToken": "(^|[^a-z])ai([^a-z]|$)",
      "aiContext": "code|coding|cli|agent|assistant"
    }
  },
  "agents": [
    {
      "id": "claude",
      "displayName": "claude",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "claude"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [
        "/\\.local/bin/claude",
        "/anthropic/",
        "/Claude/"
      ],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "codex",
      "displayName": "codex",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "codex"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [
        "/OpenAI/Codex/"
      ],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "gemini",
      "displayName": "gemini",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "gemini"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [
        "/gemini-cli/"
      ],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "grok",
      "displayName": "grok",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "grok"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [
        "/\\.grok/bin/"
      ],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "kimi",
      "displayName": "kimi",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "kimi"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [
        "/\\.kimi-code/"
      ],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "opencode",
      "displayName": "opencode",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "opencode"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [
        "/opencode"
      ],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "openclaw",
      "displayName": "openclaw",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "openclaw"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "qwen",
      "displayName": "qwen",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "qwen"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "jcode",
      "displayName": "jcode",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "jcode"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [
        "/jcode/bin/"
      ],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "mimo",
      "displayName": "mimo",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "mimo"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [
        "/\\.mimocode/"
      ],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "aider",
      "displayName": "aider",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "aider"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "cody",
      "displayName": "cody",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "cody"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "crush",
      "displayName": "crush",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "crush"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "droid",
      "displayName": "droid",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "droid"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "goose",
      "displayName": "goose",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "goose"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "cline",
      "displayName": "cline",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "cline"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "kilocode",
      "displayName": "kilocode",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "kilocode"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "kilo",
      "displayName": "kilo",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "kilo"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "factory",
      "displayName": "factory",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "factory"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "blackbox",
      "displayName": "blackbox",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "blackbox"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "auggie",
      "displayName": "auggie",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "auggie"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "cursor-agent",
      "displayName": "cursor-agent",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "cursor-agent"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "windsurf",
      "displayName": "windsurf",
      "vendor": null,
      "kind": "editor",
      "commands": [
        "windsurf"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [
        "/Programs/Windsurf/"
      ],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "kiro",
      "displayName": "kiro",
      "vendor": null,
      "kind": "editor",
      "commands": [
        "kiro"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "roo-code",
      "displayName": "roo-code",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "roo-code"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "continue-cli",
      "displayName": "continue-cli",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "continue-cli"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "copilot",
      "displayName": "copilot",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "copilot"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "gh-copilot",
      "displayName": "gh-copilot",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "gh-copilot"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "openhands",
      "displayName": "openhands",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "openhands"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [
        "/\\.openhands/"
      ],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "codebuddy",
      "displayName": "codebuddy",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "codebuddy"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "iflow",
      "displayName": "iflow",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "iflow"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "mux",
      "displayName": "mux",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "mux"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "zencoder",
      "displayName": "zencoder",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "zencoder"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "hermes",
      "displayName": "hermes",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "hermes"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [
        "/\\.hermes/"
      ],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "hermes-agent",
      "displayName": "hermes-agent",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "hermes-agent"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "letta",
      "displayName": "letta",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "letta"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "trae",
      "displayName": "trae",
      "vendor": null,
      "kind": "editor",
      "commands": [
        "trae"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [
        "/Programs/(trae|Trae CN)/"
      ],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "trae-cn",
      "displayName": "trae-cn",
      "vendor": null,
      "kind": "editor",
      "commands": [
        "trae-cn"
      ],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $KnownCli"
    },
    {
      "id": "sg",
      "displayName": "sg",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "sg"
      ],
      "ambiguous": true,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $AmbiguousCli"
    },
    {
      "id": "src",
      "displayName": "src",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "src"
      ],
      "ambiguous": true,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $AmbiguousCli"
    },
    {
      "id": "amp",
      "displayName": "amp",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "amp"
      ],
      "ambiguous": true,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $AmbiguousCli"
    },
    {
      "id": "pi",
      "displayName": "pi",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "pi"
      ],
      "ambiguous": true,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $AmbiguousCli"
    },
    {
      "id": "vibe",
      "displayName": "vibe",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "vibe"
      ],
      "ambiguous": true,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $AmbiguousCli"
    },
    {
      "id": "continue",
      "displayName": "continue",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "continue"
      ],
      "ambiguous": true,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $AmbiguousCli"
    },
    {
      "id": "roo",
      "displayName": "roo",
      "vendor": null,
      "kind": "cli",
      "commands": [
        "roo"
      ],
      "ambiguous": true,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $AmbiguousCli"
    },
    {
      "id": "cursor",
      "displayName": "cursor",
      "vendor": null,
      "kind": "editor",
      "commands": [],
      "ambiguous": false,
      "packages": {
        "npm": [],
        "pypi": [],
        "cargo": [],
        "brew": [],
        "scoop": [],
        "choco": [],
        "winget": [],
        "vscode": []
      },
      "pathSignatures": [
        "/Programs/cursor/"
      ],
      "configDirs": {
        "all": [],
        "windows": [],
        "macos": [],
        "linux": []
      },
      "versionArgs": [
        "--version"
      ],
      "homepage": null,
      "repo": null,
      "sources": [],
      "verified": false,
      "notes": "seeded from v1 $PathSignatures; v1 never listed \"cursor\" as a known CLI name, so it has no command here"
    }
  ]
}
'@
$script:LcaEmbeddedAssets['report/template.html'] = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; font-src data:; img-src data: blob:; connect-src 'none'">
<meta name="referrer" content="no-referrer">
<title>Coding Agents // Fleet Manifest</title>
<style>
/*{{FONTS}}*/
/*{{CSS}}*/
</style>
</head>
<body>
<div class="wrap">
<div class="eyebrow">// agent fleet manifest</div>
<h1>CODING<br><em>AGENTS</em></h1>
<p class="meta" id="meta"></p>
<main id="app" aria-live="polite"></main>
<footer><span>generated by <span class="ac">list-coding-agents</span></span></footer>
</div>
<script type="application/json" id="lca-data">{{DATA}}</script>
<script>
/*{{JS}}*/
</script>
</body>
</html>
'@
$script:LcaEmbeddedAssets['report/report.css'] = @'
*{box-sizing:border-box;margin:0;padding:0}
:root{--bg:#08080a;--panel:#0d0d11;--line:#1c1c23;--ink:#eceae0;--mut:#8f8f84;--accent:#d4ff3f;--warn:#ffcf5a}
body{background:var(--bg);color:var(--ink);font-family:'JetBrains Mono',ui-monospace,monospace}
.wrap{max-width:1080px;margin:0 auto;padding:40px 16px}
.eyebrow{font-size:12px;letter-spacing:.3em;text-transform:uppercase;color:var(--accent)}
h1{font-family:'Syne',sans-serif;font-weight:800;font-size:clamp(48px,12vw,150px);line-height:.85}
h1 em{font-style:normal;color:var(--mut)}
.meta{color:var(--mut);font-size:13px;margin:12px 0 24px}
.unit{display:flex;gap:16px;padding:8px 0;border-bottom:1px solid var(--line);flex-wrap:wrap}
.unit .cmd{font-weight:700}
.unit .path{color:var(--mut);overflow-wrap:anywhere}
footer{margin-top:40px;color:var(--mut);font-size:12px}
footer .ac{color:var(--accent)}
'@
$script:LcaEmbeddedAssets['report/report.js'] = @'
(function () {
  'use strict';
  var el = document.getElementById('lca-data');
  var data = {};
  try { data = JSON.parse(el.textContent) || {}; } catch (e) { data = {}; }
  var agents = data.agents || [];
  var meta = document.getElementById('meta');
  var s = data.summary || {};
  meta.textContent = (s.detected || 0) + ' agents detected - ' + (s.rank || '') + ' - ' + (data.generatedAt || '');
  var app = document.getElementById('app');
  var list = document.createElement('ol');
  for (var i = 0; i < agents.length; i++) {
    var a = agents[i];
    var li = document.createElement('li');
    li.className = 'unit';
    var n = document.createElement('span');
    n.className = 'cmd';
    n.textContent = a.name + (a.version ? ' v' + a.version : '');
    var p = document.createElement('span');
    p.className = 'path';
    p.textContent = a.method + ' - ' + (a.source || '');
    li.appendChild(n);
    li.appendChild(p);
    list.appendChild(li);
  }
  app.appendChild(list);
})();
'@
$script:LcaEmbeddedAssets['ListCodingAgents.format.ps1xml'] = @'
<?xml version="1.0" encoding="utf-8"?>
<Configuration>
  <ViewDefinitions>
    <View>
      <Name>ListCodingAgents.Agent</Name>
      <ViewSelectedBy>
        <TypeName>ListCodingAgents.Agent</TypeName>
      </ViewSelectedBy>
      <TableControl>
        <TableHeaders>
          <TableColumnHeader><Label>Name</Label></TableColumnHeader>
          <TableColumnHeader><Label>Kind</Label></TableColumnHeader>
          <TableColumnHeader><Label>Method</Label></TableColumnHeader>
          <TableColumnHeader><Label>Version</Label></TableColumnHeader>
          <TableColumnHeader><Label>Update</Label></TableColumnHeader>
          <TableColumnHeader><Label>Usage</Label></TableColumnHeader>
          <TableColumnHeader><Label>SizeMB</Label><Alignment>Right</Alignment></TableColumnHeader>
        </TableHeaders>
        <TableRowEntries>
          <TableRowEntry>
            <TableColumnItems>
              <TableColumnItem><PropertyName>Name</PropertyName></TableColumnItem>
              <TableColumnItem><PropertyName>Kind</PropertyName></TableColumnItem>
              <TableColumnItem><PropertyName>Method</PropertyName></TableColumnItem>
              <TableColumnItem><PropertyName>Version</PropertyName></TableColumnItem>
              <TableColumnItem>
                <ScriptBlock>if ($_.UpdateStatus -eq 'outdated') { '-> ' + $_.Latest } else { $_.UpdateStatus }</ScriptBlock>
              </TableColumnItem>
              <TableColumnItem><PropertyName>Usage</PropertyName></TableColumnItem>
              <TableColumnItem><PropertyName>InstallSizeMB</PropertyName></TableColumnItem>
            </TableColumnItems>
          </TableRowEntry>
        </TableRowEntries>
      </TableControl>
    </View>
  </ViewDefinitions>
</Configuration>
'@
# ---- Private/Console/Invoke-LcaCli.ps1 ----
# The list-coding-agents.ps1 entry point. The script's param block (see
# src/list-coding-agents.ps1) forwards $PSBoundParameters here. Returns the
# process exit code; the script decides whether to call exit.

$script:LcaLastExitCode = 0
$script:LcaExitCode = @{
    Ok           = 0
    Error        = 1
    BadArguments = 2
    FailOn       = 3
    UpdateFailed = 4
}

function Get-LcaCliOption {
    <#
    Merges bound parameters over config.json "defaults" (a switch given on
    the command line always wins) and returns a hashtable of every option.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([hashtable]$BoundParameters = @{}, [hashtable]$ConfigDefaults = @{})
    $names = @('IncludeEditors', 'ShowReasons', 'NoHtml', 'SkipWinget', 'CheckUpdates', 'UpdateAll', 'Json',
        'IncludeExtensions', 'All', 'NoProbe', 'NoOpen', 'PassThru', 'Quiet', 'NoColor', 'Redact', 'Version', 'Force')
    $opt = @{}
    foreach ($n in $names) {
        $v = $false
        if ($ConfigDefaults.ContainsKey($n)) { $v = [bool]$ConfigDefaults[$n] }
        if ($BoundParameters.ContainsKey($n)) { $v = [bool]$BoundParameters[$n] }
        $opt[$n] = $v
    }
    foreach ($n in @('Explain', 'OutDir', 'Format', 'FailOn', 'WhatIf', 'Confirm')) {
        $opt[$n] = $null
        if ($BoundParameters.ContainsKey($n)) { $opt[$n] = $BoundParameters[$n] }
    }
    if ($opt['UpdateAll']) { $opt['CheckUpdates'] = $true }
    $opt
}

function Invoke-LcaCli {
    <#
    Runs the CLI. Pipeline output (-PassThru objects, -Format text,
    -Version) is written to the output stream; the process exit code is left
    in $script:LcaLastExitCode for the entry script.
    #>
    [CmdletBinding()]
    param(
        [hashtable]$BoundParameters = @{},
        [AllowEmptyString()][AllowNull()][string]$ScriptRoot
    )
    try {
        $probeCtx = [pscustomobject]@{ ConfigDir = (Get-LcaConfigDirectory) }
        $cfg = Get-LcaConfig -Context $probeCtx
        $opt = Get-LcaCliOption -BoundParameters $BoundParameters -ConfigDefaults $cfg.Defaults
        $script:LcaLastExitCode = $script:LcaExitCode.Ok
        if ($opt.Version) {
            Write-Output ('list-coding-agents {0}' -f $script:LcaToolVersion)
            return
        }
        $ctxOptions = @{
            IncludeEditors = $opt.IncludeEditors; IncludeExtensions = $opt.IncludeExtensions; All = $opt.All
            SkipWinget = $opt.SkipWinget; CheckUpdates = $opt.CheckUpdates; NoProbe = $opt.NoProbe
            Explain = $opt.Explain; ShowReasons = $opt.ShowReasons; Redact = $opt.Redact
        }
        $ctx = New-LcaContext -Options $ctxOptions -ScriptRoot $ScriptRoot
        $ctx.Data['quiet'] = [bool]$opt.Quiet
        $scan = Invoke-LcaScan -Context $ctx

        if ($opt.Explain) {
            foreach ($l in (Get-LcaExplanation -Context $ctx -Scan $scan -Name $opt.Explain).Lines) { Write-LcaConsoleLine $l }
        } elseif (-not $opt.Quiet -and -not $opt.Format) {
            Write-LcaConsoleReport -Context $ctx -Scan $scan
        }

        $exit = $script:LcaExitCode.Ok
        if ($opt.UpdateAll) {
            $res = @(Invoke-LcaUpdateAll -Context $ctx -Scan $scan -Force:$opt.Force -DryRun:([bool]$opt.WhatIf) -AskConfirm:([bool]$opt.Confirm))
            if (@($res | Where-Object { $_.Status -eq 'failed' }).Count) { $exit = $script:LcaExitCode.UpdateFailed }
        }
        if ($opt.FailOn) {
            $failed = @(Test-LcaFailOn -Context $ctx -Scan $scan -FailOn $opt.FailOn)
            if ($failed.Count -and $exit -eq $script:LcaExitCode.Ok) {
                $exit = $script:LcaExitCode.FailOn
                if (-not $opt.Quiet) { Write-LcaConsoleLine ('-FailOn matched: ' + ($failed -join ', ')) 'Red' }
            }
        }

        Save-LcaState -Context $ctx -Scan $scan

        $outDir = $opt.OutDir
        if (-not $outDir) { $outDir = (Get-Location).ProviderPath }
        $scan.Diagnostics = @(Get-LcaDiagnostic)
        $export = ConvertTo-LcaExport -Scan $scan -Context $ctx -Redact:$opt.Redact
        if ($opt.Json) {
            $jsonPath = Join-Path -Path $outDir -ChildPath 'coding-agents.json'
            Write-LcaTextFile -Path $jsonPath -Content ((ConvertTo-LcaJson -InputObject $export) + "`n")
            if (-not $opt.Quiet) { Write-LcaConsoleLine "JSON export: $jsonPath" 'Green' }
        }
        if (-not $opt.NoHtml) {
            $htmlPath = Join-Path -Path $outDir -ChildPath 'coding-agents.html'
            Write-LcaTextFile -Path $htmlPath -Content (ConvertTo-LcaReportHtml -Export $export)
            if (-not $opt.Quiet) { Write-LcaConsoleLine "HTML report: $htmlPath" 'Green' }
            if (-not $opt.NoOpen) { Open-LcaReport -Path $htmlPath }
        }
        if ($opt.Format -eq 'json') { Write-Output (ConvertTo-LcaJson -InputObject $export) }
        if ($opt.PassThru) { Select-LcaAgentInScope -Context $ctx -Agent $scan.Agents | ForEach-Object { Write-Output $_ } }
        $script:LcaLastExitCode = $exit
    } catch {
        $script:LcaLastExitCode = $script:LcaExitCode.Error
        Write-Error -ErrorRecord $_
    }
}

function Open-LcaReport {
    <# Opens the report with the platform's default handler; never fatal. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        switch (Get-LcaPlatform) {
            'windows' { Invoke-Item -LiteralPath $Path }
            'macos' { [void](Open-LcaProcess -FilePath 'open' -ArgumentList @($Path)) }
            default { [void](Open-LcaProcess -FilePath 'xdg-open' -ArgumentList @($Path)) }
        }
    } catch {
        Add-LcaDiagnostic -Source 'report' -Level 'info' -Message "could not open $Path" -ErrorRecord $_
    }
}
# ---- Private/Console/Progress.ps1 ----
# Progress reporting for the scan phases. Workstream D owns the rendering.

function Write-LcaProgress {
    <#
    Reports scan progress (Write-Progress) unless the context says to stay
    quiet. -Completed clears the bar.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [string]$Status = '',
        [int]$PercentComplete = -1,
        [switch]$Completed
    )
    if ($Context.Data.ContainsKey('quiet') -and $Context.Data['quiet']) { return }
    if ($Completed) { Write-Progress -Activity 'list-coding-agents' -Completed; return }
    Write-Progress -Activity 'list-coding-agents' -Status $Status -PercentComplete $PercentComplete
}
# ---- Private/Console/Write-LcaConsoleReport.ps1 ----
# Terminal report (ported from v1). Workstream D replaces this with a
# width-aware, colour/NO_COLOR-aware renderer with an ASCII fallback.

function Write-LcaConsoleLine {
    <# The single place that writes coloured text to the console. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Console renderer: this is human-facing terminal output, not pipeline data.')]
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text = '', [string]$Color)
    if ($Color) { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text }
}

function Write-LcaConsoleReport {
    <# Prints the scan the way v1 did. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)]$Scan)
    $now = $Context.Now
    $o = $Context.Options
    $h = $Scan.Health
    $agents = @($Scan.Agents)
    $detected = @(Select-LcaAgentInScope -Context $Context -Agent $agents -Tier 'detected')
    $possible = @(Select-LcaAgentInScope -Context $Context -Agent $agents -Tier 'possible')
    $stale = @($detected | Where-Object { $_.Usage -eq 'stale' })
    $conflicted = @(@($detected) + @($possible) | Where-Object { @($_.Shadows).Count -gt 0 })
    $updates = @($detected | Where-Object { $_.UpdateStatus -eq 'outdated' })

    Write-LcaConsoleLine
    $disk = Format-LcaSize -Mb $h.TotalMB
    Write-LcaConsoleLine ("Auto-detected coding agents ({0} detected, {1} possible, {2} on disk)" -f $detected.Count, $possible.Count, $disk) 'Cyan'
    $reclaimLabel = Format-LcaSize -Mb $h.ReclaimMB
    if (-not $reclaimLabel -or $h.ReclaimMB -le 0) { $reclaimLabel = 'none' }
    Write-LcaConsoleLine ("fleet rank: {0} (lv {1}) | {2}/{1} used this month | dead weight: {3}" -f $h.Rank, $h.DetectedCount, $h.Active30, $reclaimLabel) 'Magenta'
    if (-not $o.IncludeEditors) { Write-LcaConsoleLine '(GUI editors hidden - use -IncludeEditors)' 'DarkGray' }
    if ($Scan.Scope.Partial) {
        $carried = "$(@($Scan.Changes.Unscanned).Count) carried over from last full scan"
        if (-not $Scan.Changes.WriteState) { $carried = 'baseline left untouched' }
        Write-LcaConsoleLine ("(partial scan: {0} - winget packages not checked, {1})" -f $Scan.Scope.PartialReason, $carried) 'DarkGray'
    }
    $prevDate = $Scan.Changes.PreviousDate
    if (@($Scan.Changes.New).Count) { Write-LcaConsoleLine ("+ new since last scan ({0}): {1}" -f $prevDate, ($Scan.Changes.New -join ', ')) 'Green' }
    if (@($Scan.Changes.Gone).Count) { Write-LcaConsoleLine ("- gone since last scan ({0}): {1}" -f $prevDate, ($Scan.Changes.Gone -join ', ')) 'DarkGray' }

    foreach ($grp in @($detected | Group-Object -Property Method | Sort-Object -Property @{ Expression = { Get-LcaChannelOrder -Channel $_.Name } })) {
        Write-LcaConsoleLine
        Write-LcaConsoleLine ("== Installed via {0} ({1}) ==" -f $grp.Name, $grp.Count) 'Yellow'
        $cols = @(
            @{ n = 'Agent'; e = { $_.Name } },
            @{ n = 'Version'; e = { $_.Version } },
            @{ n = 'Size'; e = { Format-LcaSize -Mb $_.InstallSizeMB } },
            @{ n = 'Used'; e = { Format-LcaAge -Date $_.LastUsed -Now $now } },
            @{ n = '30d'; e = { if ($_.Sessions30d) { "$($_.Sessions30d)x" } } },
            @{ n = 'MCP'; e = { if ($_.McpCount) { $_.McpCount } } },
            @{ n = 'Auth'; e = { if ($_.LoggedIn) { 'yes' } } },
            @{ n = 'Source'; e = { $_.Source } }
        )
        if ($o.ShowReasons) { $cols += @{ n = 'Why'; e = { $_.Why } } }
        $table = $grp.Group | Sort-Object -Property Name | Format-Table -Property $cols -AutoSize | Out-String -Width 4096
        Write-LcaConsoleLine $table.TrimEnd()
    }

    if ($conflicted.Count) {
        Write-LcaConsoleLine
        Write-LcaConsoleLine '== PATH conflicts (same command, multiple installs) ==' 'Yellow'
        foreach ($r in $conflicted | Sort-Object -Property Name) {
            Write-LcaConsoleLine ("  {0}: wins -> {1}" -f $r.Name, $r.Source) 'White'
            foreach ($sPath in $r.Shadows) { Write-LcaConsoleLine ("  {0}  shadowed -> {1}" -f (' ' * $r.Name.Length), $sPath) 'DarkGray' }
        }
    }

    if ($stale.Count) {
        Write-LcaConsoleLine
        Write-LcaConsoleLine ("== dead weight (untouched > {0}d) - reclaim ~{1} ==" -f $Context.Config.StaleDays, $reclaimLabel) 'Yellow'
        foreach ($r in $stale | Sort-Object -Property @{ Expression = { $_.InstallSizeMB } } -Descending) {
            $ageTxt = 'never seen used'
            if ($r.LastUsed) { $ageTxt = "last used $(Format-LcaAge -Date $r.LastUsed -Now $now)" }
            $szTxt = Format-LcaSize -Mb $r.InstallSizeMB
            if (-not $szTxt) { $szTxt = '?' }
            $cmd = ''
            if ($r.UninstallCommand) { $cmd = $r.UninstallCommand.Display }
            Write-LcaConsoleLine ("  {0,-18} {1,-9} {2,-18} {3}" -f $r.Name, $szTxt, $ageTxt, $cmd) 'White'
        }
    }

    if ($possible.Count) {
        Write-LcaConsoleLine
        Write-LcaConsoleLine '== Possible (weak signal - review) ==' 'DarkYellow'
        $table = $possible | Sort-Object -Property Name | Format-Table -Property @{ n = 'Agent'; e = { $_.Name } }, @{ n = 'Source'; e = { $_.Source } }, @{ n = 'Why'; e = { $_.Why } } -AutoSize | Out-String -Width 4096
        Write-LcaConsoleLine $table.TrimEnd()
    }

    if ($o.CheckUpdates) {
        Write-LcaConsoleLine
        if ($updates.Count) {
            Write-LcaConsoleLine "== Updates available ($($updates.Count)) ==" 'Yellow'
            foreach ($r in $updates | Sort-Object -Property Name) {
                Write-LcaConsoleLine ("  {0,-18} {1,-12} ->  {2,-12} {3}" -f $r.Name, $r.Version, $r.Latest, $r.UpdateCommand.Display) 'White'
            }
        } else {
            Write-LcaConsoleLine '== Everything is up to date ==' 'Green'
        }
    } else {
        Write-LcaConsoleLine '(tip: -CheckUpdates shows which agents are outdated + the update command, -UpdateAll runs them)' 'DarkGray'
    }
    Write-LcaConsoleLine
}
# ---- Private/Core/Assets.ps1 ----
# Module assets (data/catalog.json, report/*). In the module they are files
# next to the code; in the single-file bundle build.ps1 embeds them in
# $script:LcaEmbeddedAssets (text) and $script:LcaEmbeddedBinary (base64).

if (-not (Get-Variable -Name 'LcaEmbeddedAssets' -Scope Script -ErrorAction Ignore)) { $script:LcaEmbeddedAssets = $null }
if (-not (Get-Variable -Name 'LcaEmbeddedBinary' -Scope Script -ErrorAction Ignore)) { $script:LcaEmbeddedBinary = $null }
if (-not (Get-Variable -Name 'LcaModuleRoot' -Scope Script -ErrorAction Ignore)) { $script:LcaModuleRoot = $null }
$script:LcaCatalogCache = $null

function Get-LcaAsset {
    <#
    Returns a text asset by its module-relative path ('data/catalog.json'),
    or with -AsBase64 a binary asset as a base64 string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Name, [switch]$AsBase64)
    $key = $Name.Replace('\', '/')
    if ($AsBase64) {
        if ($null -ne $script:LcaEmbeddedBinary) {
            if (-not $script:LcaEmbeddedBinary.ContainsKey($key)) { throw "embedded asset not found: $key" }
            return ($script:LcaEmbeddedBinary[$key] -replace '\s', '')
        }
    } elseif ($null -ne $script:LcaEmbeddedAssets) {
        if (-not $script:LcaEmbeddedAssets.ContainsKey($key)) { throw "embedded asset not found: $key" }
        return $script:LcaEmbeddedAssets[$key]
    }
    if (-not $script:LcaModuleRoot) { throw 'module root unknown' }
    $p = $script:LcaModuleRoot
    foreach ($seg in $key.Split('/')) { $p = Join-Path -Path $p -ChildPath $seg }
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "asset not found: $key" }
    if ($AsBase64) { return [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($p)) }
    (Read-LcaTextFile -Path $p) -replace "`r`n", "`n"
}

function Test-LcaAsset {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$Name, [switch]$Binary)
    $key = $Name.Replace('\', '/')
    if ($Binary -and $null -ne $script:LcaEmbeddedBinary) { return $script:LcaEmbeddedBinary.ContainsKey($key) }
    if (-not $Binary -and $null -ne $script:LcaEmbeddedAssets) { return $script:LcaEmbeddedAssets.ContainsKey($key) }
    if (-not $script:LcaModuleRoot) { return $false }
    $p = $script:LcaModuleRoot
    foreach ($seg in $key.Split('/')) { $p = Join-Path -Path $p -ChildPath $seg }
    Test-Path -LiteralPath $p -PathType Leaf
}

function Get-LcaCatalog {
    <# The parsed agent catalog (data/catalog.json), cached per session. #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([switch]$Force)
    if ($script:LcaCatalogCache -and -not $Force) { return $script:LcaCatalogCache }
    $script:LcaCatalogCache = ConvertFrom-LcaJson -Text (Get-LcaAsset -Name 'data/catalog.json')
    $script:LcaCatalogCache
}

function Get-LcaToolVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $script:LcaToolVersion
}
# ---- Private/Core/Context.ps1 ----
# The scan context: options, platform, clock, config, catalog, override
# lists, caches, timings. Created once per scan by New-LcaContext and passed
# to every phase. FROZEN CONTRACT for Phase 2 workstreams.

$script:LcaToolVersion = '2.0.0'
$script:LcaSchemaVersion = 2

function New-LcaContext {
    <#
    Options (all optional): IncludeEditors, IncludeExtensions, All, SkipWinget,
    CheckUpdates, NoProbe, Explain, ShowReasons, Redact.
    ScriptRoot is the folder of the entry script (v1 read agents-extra.txt /
    agents-exclude.txt / last-scan.json from there); empty under irm | iex.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Constructor: builds an in-memory object and changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [hashtable]$Options = @{},
        [AllowEmptyString()][AllowNull()][string]$ScriptRoot
    )
    $opt = [ordered]@{
        IncludeEditors    = $false
        IncludeExtensions = $false
        All               = $false
        SkipWinget        = $false
        CheckUpdates      = $false
        NoProbe           = $false
        Explain           = $null
        ShowReasons       = $false
        Redact            = $false
    }
    foreach ($k in $Options.Keys) {
        if (-not $opt.Contains($k)) { throw "New-LcaContext: unknown option '$k'" }
        $v = $Options[$k]
        if ($v -is [System.Management.Automation.SwitchParameter]) { $v = $v.IsPresent }
        $opt[$k] = $v
    }
    if ($opt.All) { $opt.IncludeEditors = $true; $opt.IncludeExtensions = $true }

    $ctx = [pscustomobject]@{
        PSTypeName   = 'ListCodingAgents.Context'
        Options      = [pscustomobject]$opt
        Platform     = (Get-LcaPlatform)
        Now          = (Get-LcaNow)
        ScriptRoot   = $ScriptRoot
        StateDir     = $null
        ConfigDir    = $null
        Config       = $null
        Catalog      = $null
        Extra        = $null
        Exclude      = $null
        ProbeCache   = @{}
        Parallelism  = 4
        Timings      = [ordered]@{}
        Data         = @{}   # scratch space for cross-phase data (e.g. npm metadata)
    }
    $ctx.StateDir = Get-LcaStateDirectory
    $ctx.ConfigDir = Get-LcaConfigDirectory
    $ctx.Config = Get-LcaConfig -Context $ctx
    $ctx.Catalog = Get-LcaCatalog
    $ctx.Extra = Get-LcaNameList -Context $ctx -FileName 'agents-extra.txt'
    $ctx.Exclude = Get-LcaNameList -Context $ctx -FileName 'agents-exclude.txt'
    $cpu = [System.Environment]::ProcessorCount
    $ctx.Parallelism = [int][Math]::Max(2, [Math]::Min(8, $cpu))
    if ($ctx.Config.Parallelism) { $ctx.Parallelism = [int]$ctx.Config.Parallelism }
    $ctx
}

function Measure-LcaPhase {
    <#
    Runs one scan phase, records its wall-clock time in Context.Timings and
    prints it with -Verbose. Returns the script block's output.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $ScriptBlock
    } finally {
        $sw.Stop()
        $Context.Timings[$Name] = [int]$sw.ElapsedMilliseconds
        Write-Verbose ('phase {0}: {1} ms' -f $Name, $sw.ElapsedMilliseconds)
    }
}
# ---- Private/Core/Diagnostics.ps1 ----
# Diagnostics: every recoverable failure (a tool that is missing, a query that
# timed out, a file that could not be parsed) is recorded here, written to
# -Verbose, and exported in the JSON "diagnostics" array - never swallowed by
# an empty catch. Messages pass through Protect-LcaText so a parser error
# that quotes file content cannot carry a secret into any output.

$script:LcaDiagnostics = New-Object System.Collections.Generic.List[object]

function Clear-LcaDiagnostic {
    [CmdletBinding()]
    param()
    $script:LcaDiagnostics = New-Object System.Collections.Generic.List[object]
}

function Protect-LcaText {
    <# Masks anything that looks like a credential and caps the length. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Text, [int]$MaxLength = 300)
    if (-not $Text) { return $Text }
    $t = $Text
    $tokenPatterns = @(
        '(?i)\bsk-[A-Za-z0-9_\-]{4,}',
        '\bgh[pousr]_[A-Za-z0-9_]{4,}',
        '\bgithub_pat_[A-Za-z0-9_]{8,}',
        '\bxox[abprs]-[A-Za-z0-9\-]{6,}',
        '\bAKIA[0-9A-Z]{12,}',
        '\bAIza[0-9A-Za-z_\-]{12,}',
        '\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{4,}\.?[A-Za-z0-9_\-]*'
    )
    foreach ($p in $tokenPatterns) { $t = [regex]::Replace($t, $p, '<redacted>') }
    # "apiKey": "value" / token=value - keep the key name, drop the value
    $t = [regex]::Replace($t,
        '(?i)("?(api[_-]?key|access[_-]?token|refresh[_-]?token|secret|password|bearer|authorization)"?\s*[:=]\s*)("[^"]*"|\S+)',
        '$1<redacted>')
    if ($t.Length -gt $MaxLength) { $t = $t.Substring(0, $MaxLength) + '...' }
    $t
}

function Add-LcaDiagnostic {
    <#
    Records one diagnostic. -ErrorRecord adds the exception type and (unless
    -NoExceptionText) its scrubbed message. Use -NoExceptionText when the
    exception could quote the content of a config file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('info', 'warning', 'error')][string]$Level = 'warning',
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [switch]$NoExceptionText
    )
    $msg = $Message
    if ($ErrorRecord) {
        $ex = $ErrorRecord.Exception
        $msg += ' [' + $ex.GetType().Name
        if (-not $NoExceptionText) { $msg += ': ' + $ex.Message }
        $msg += ']'
    }
    $msg = Protect-LcaText -Text $msg
    $script:LcaDiagnostics.Add([pscustomobject]@{
            PSTypeName = 'ListCodingAgents.Diagnostic'
            Source     = $Source
            Level      = $Level
            Message    = $msg
        })
    Write-Verbose ("[{0}] {1}: {2}" -f $Level, $Source, $msg)
}

function Get-LcaDiagnostic {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    $script:LcaDiagnostics.ToArray()
}
# ---- Private/Core/Export.ps1 ----
# The ONE JSON export (schema/coding-agents.schema.json). coding-agents.json,
# -Format json and the HTML report's embedded data all come from
# ConvertTo-LcaExport, so they can never disagree.

function ConvertTo-LcaCommandExport {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([AllowNull()]$Command)
    if ($null -eq $Command) { return $null }
    [ordered]@{ exe = $Command.Exe; args = @($Command.Arguments); display = $Command.Display }
}

function ConvertTo-LcaAgentExport {
    <# One agent as an ordered dictionary with the schema's camelCase keys. #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory = $true)]$Agent)
    $a = $Agent
    $upd = ''; if ($a.UpdateCommand) { $upd = $a.UpdateCommand.Display }
    $unin = ''; if ($a.UninstallCommand) { $unin = $a.UninstallCommand.Display }
    [ordered]@{
        id               = $a.Id
        name             = $a.Name
        displayName      = $a.DisplayName
        vendor           = $a.Vendor
        homepage         = $a.Homepage
        catalogId        = $a.CatalogId
        verified         = [bool]$a.Verified
        tier             = $a.Tier
        kind             = $a.Kind
        score            = [int]$a.Score
        why              = $a.Why
        evidence         = @($a.Evidence | ForEach-Object {
                [ordered]@{ signal = $_.Signal; label = $_.Label; weight = [int]$_.Weight; source = $_.Source; detail = $_.Detail }
            })
        command          = $a.Command
        source           = $a.Source
        path             = $a.Path
        method           = $a.Method
        channel          = $a.Channel
        package          = $a.Package
        packageDir       = $a.PackageDir
        sources          = @($a.Sources)
        shadowedBy       = @($a.Shadows)
        version          = $a.Version
        versionSource    = $a.VersionSource
        previousVersion  = $a.PreviousVersion
        latest           = $a.Latest
        updateStatus     = $a.UpdateStatus
        updateReason     = $a.UpdateReason
        updateCmd        = $upd
        updateCommand    = (ConvertTo-LcaCommandExport -Command $a.UpdateCommand)
        uninstallCmd     = $unin
        uninstallCommand = (ConvertTo-LcaCommandExport -Command $a.UninstallCommand)
        uninstallNote    = $a.UninstallNote
        sizeMB           = (ConvertTo-LcaRoundedNumber -Value $a.InstallSizeMB -Digits 2)
        installRoot      = $a.InstallRoot
        installSizeMB    = (ConvertTo-LcaRoundedNumber -Value $a.InstallSizeMB -Digits 2)
        dataDirs         = @($a.DataDirs)
        dataSizeMB       = (ConvertTo-LcaRoundedNumber -Value $a.DataSizeMB -Digits 2)
        lastUsed         = (ConvertTo-LcaIsoString -Value $a.LastUsed)
        usage            = $a.Usage
        stale            = ($a.Usage -eq 'stale')
        sessions30d      = [int]$a.Sessions30d
        mcpServers       = [int]$a.McpCount
        mcp              = @($a.McpServers | ForEach-Object { [ordered]@{ name = $_.Name; transport = $_.Transport } })
        loggedIn         = [bool]$a.LoggedIn
        isNew            = [bool]$a.IsNew
    }
}

function ConvertTo-LcaExport {
    <#
    Scan -> ordered dictionary matching schema/coding-agents.schema.json.
    Agents are the display-scope rows (as v1's -Json: editors only with
    -IncludeEditors). -Redact strips the user name and host name.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory = $true)]$Scan, [Parameter(Mandatory = $true)]$Context, [switch]$Redact)
    $inScope = @(Select-LcaAgentInScope -Context $Context -Agent $Scan.Agents)
    $sorted = @($inScope | Sort-Object -Property @{ Expression = { if ($_.Tier -eq 'detected') { 0 } else { 1 } } }, @{ Expression = { $_.Name } })
    $h = $Scan.Health
    $c = $Scan.Changes
    $export = [ordered]@{
        schemaVersion = [int]$Scan.SchemaVersion
        tool          = [ordered]@{ name = 'list-coding-agents'; version = $Scan.ToolVersion }
        generatedAt   = (ConvertTo-LcaIsoString -Value $Scan.GeneratedAt)
        host          = $Scan.HostName
        user          = $Scan.UserName
        platform      = $Scan.Platform
        powershell    = $Scan.PowerShell
        redacted      = [bool]$Redact
        scope         = [ordered]@{
            includeEditors    = [bool]$Scan.Scope.IncludeEditors
            includeExtensions = [bool]$Scan.Scope.IncludeExtensions
            wingetScanned     = [bool]$Scan.Scope.WingetScanned
            partial           = [bool]$Scan.Scope.Partial
            partialReason     = $Scan.Scope.PartialReason
        }
        summary       = [ordered]@{
            detected   = [int]$h.DetectedCount
            possible   = [int]$h.PossibleCount
            channels   = [int]$h.Channels
            totalMB    = [double]$h.TotalMB
            reclaimMB  = [double]$h.ReclaimMB
            active30   = [int]$h.Active30
            rank       = $h.Rank
            deadWeight = @($h.DeadWeight)
            conflicts  = @($h.Conflicts)
            outdated   = @($h.Outdated)
        }
        changes       = [ordered]@{
            previousScan   = $(if ($c.PreviousDate) { [string]$c.PreviousDate } else { $null })
            new            = @($c.New)
            gone           = @($c.Gone)
            versionChanges = @($c.VersionChanges | ForEach-Object { [ordered]@{ name = $_.Name; from = $_.From; to = $_.To } })
        }
        history       = @($Scan.History | ForEach-Object {
                $e = [ordered]@{ d = [string]$_.d; c = [int]$_.c; mb = [double]$_.mb }
                $v = Get-LcaProperty -InputObject $_ -Name 'v'
                if ($v) { $e['v'] = $v }
                $e
            })
        agents        = @($sorted | ForEach-Object { ConvertTo-LcaAgentExport -Agent $_ })
        diagnostics   = @($Scan.Diagnostics | ForEach-Object { [ordered]@{ source = $_.Source; level = $_.Level; message = $_.Message } })
    }
    if ($Redact) {
        $export = ConvertTo-LcaRedacted -InputObject $export -HomeDir $Scan.HomeDir -UserName $Scan.UserName
        $export['host'] = $null
        $export['user'] = $null
        $export['redacted'] = $true
    }
    $export
}

function ConvertTo-LcaRedacted {
    <#
    Deep copy with every string scrubbed: the home directory becomes '~' and
    any remaining occurrence of the user name becomes '<user>'.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([AllowNull()]$InputObject, [AllowNull()][string]$HomeDir, [AllowNull()][string]$UserName)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string]) {
        $s = $InputObject
        if ($HomeDir -and $HomeDir.Length -gt 1) {
            $s = [regex]::Replace($s, ('(?i)' + [regex]::Escape($HomeDir.TrimEnd('\', '/'))), '~')
            $alt = $HomeDir.TrimEnd('\', '/').Replace('\', '/')
            $s = [regex]::Replace($s, ('(?i)' + [regex]::Escape($alt)), '~')
        }
        if ($UserName -and $UserName.Length -ge 2) {
            $s = [regex]::Replace($s, ('(?i)(?<![A-Za-z0-9])' + [regex]::Escape($UserName) + '(?![A-Za-z0-9])'), '<user>')
        }
        return $s
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $o = [ordered]@{}
        foreach ($k in @($InputObject.Keys)) { $o[$k] = ConvertTo-LcaRedacted -InputObject $InputObject[$k] -HomeDir $HomeDir -UserName $UserName }
        return $o
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $list = @(foreach ($i in $InputObject) { , (ConvertTo-LcaRedacted -InputObject $i -HomeDir $HomeDir -UserName $UserName) })
        return , $list
    }
    if ($InputObject -is [pscustomobject]) {
        $o = [ordered]@{}
        foreach ($p in $InputObject.PSObject.Properties) { $o[$p.Name] = ConvertTo-LcaRedacted -InputObject $p.Value -HomeDir $HomeDir -UserName $UserName }
        return $o
    }
    $InputObject
}
# ---- Private/Core/FileIO.ps1 ----
# File output is always BOM-less UTF-8 with LF line endings, on every
# edition. v1 used Out-File -Encoding utf8, which writes a BOM on Windows
# PowerShell 5.1 and none on 7; Python's json and Node's JSON.parse reject
# the BOM.

function Write-LcaTextFile {
    <#
    Writes text as BOM-less UTF-8. Writes to a temp file in the same folder
    first and then moves it into place, so an interrupted run never leaves a
    half-written state file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $dir -Force)
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    $tmp = $Path + '.' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $Content, $enc)
    try {
        if ([System.IO.File]::Exists($Path)) {
            [System.IO.File]::Replace($tmp, $Path, $null)
        } else {
            [System.IO.File]::Move($tmp, $Path)
        }
    } catch {
        # File.Replace is unsupported on some file systems; fall back to copy.
        Write-Debug "atomic replace failed for ${Path}: $($_.Exception.Message)"
        [System.IO.File]::Copy($tmp, $Path, $true)
        [System.IO.File]::Delete($tmp)
    }
}

function Read-LcaTextFile {
    <# Reads a text file (BOM or not) as UTF-8. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Path)
    [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function ConvertTo-LcaJson {
    <#
    Serializes with enough depth and without unrolling: a one-element or
    empty array stays an array (v1 wrote an object for one agent and an
    empty file for none).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$InputObject, [switch]$Compress)
    if ($null -eq $InputObject) { return 'null' }
    if (($InputObject -is [array]) -and $InputObject.Count -eq 0) { return '[]' }
    $json = ConvertTo-Json -InputObject $InputObject -Depth 12 -Compress:$Compress
    $json -replace "`r`n", "`n"
}

function ConvertFrom-LcaJson {
    <#
    Parses JSON text. Strips a UTF-8 BOM and works around 5.1 emitting a
    top-level array as a single object.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $t = $Text.TrimStart([char]0xFEFF)
    if (-not $t.Trim()) { throw 'empty JSON document' }
    ConvertFrom-Json -InputObject $t
}

function Get-LcaProperty {
    <#
    StrictMode-safe property read for objects from ConvertFrom-Json (missing
    properties throw under StrictMode).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([AllowNull()]$InputObject, [Parameter(Mandatory = $true)][string]$Name, [AllowNull()]$Default = $null)
    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $Default
    }
    $p = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    $p.Value
}
# ---- Private/Core/Format.ps1 ----
# Small formatting helpers shared by the terminal renderer, the JSON export
# and the report. Invariant culture everywhere so output does not change with
# the user's locale ("2,5 GB" vs "2.5 GB").

function Format-LcaSize {
    <#
    Formats megabytes. $null -> '' (unknown); 0 -> '0 MB' (v1 printed
    '<0.1 MB' for an empty fleet); otherwise MB/GB like v1.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$Mb)
    if ($null -eq $Mb -or "$Mb" -eq '') { return '' }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $v = [double]$Mb
    if ($v -le 0) { return '0 MB' }
    if ($v -lt 0.1) { return '<0.1 MB' }
    if ($v -ge 1024) { return ($v / 1024).ToString('N1', $inv) + ' GB' }
    if ($v -ge 10) { return $v.ToString('N0', $inv) + ' MB' }
    $v.ToString('N1', $inv) + ' MB'
}

function Format-LcaAge {
    <# 'today', 'yesterday', '12d ago', '3mo ago', '2y ago' relative to Now. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$Date, [Parameter(Mandatory = $true)][System.DateTimeOffset]$Now)
    if ($null -eq $Date) { return '' }
    $d = ConvertTo-LcaDateTimeOffset -Value $Date
    if ($null -eq $d) { return '' }
    $days = ($Now - $d).TotalDays
    if ($days -lt 1) { return 'today' }
    if ($days -lt 2) { return 'yesterday' }
    if ($days -lt 60) { return ('{0}d ago' -f [int][math]::Floor($days)) }
    if ($days -lt 365) { return ('{0}mo ago' -f [int][math]::Floor($days / 30)) }
    ('{0}y ago' -f [int][math]::Floor($days / 365))
}

function ConvertTo-LcaDateTimeOffset {
    <# Accepts DateTimeOffset, DateTime or an ISO string; returns $null otherwise. #>
    [CmdletBinding()]
    [OutputType([System.DateTimeOffset])]
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.DateTimeOffset]) { return $Value }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [System.DateTimeKind]::Unspecified) { return New-Object System.DateTimeOffset ([datetime]::SpecifyKind($Value, [System.DateTimeKind]::Local)) }
        return New-Object System.DateTimeOffset ($Value)
    }
    $parsed = [System.DateTimeOffset]::MinValue
    if ([System.DateTimeOffset]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeLocal, [ref]$parsed)) {
        return $parsed
    }
    $null
}

function ConvertTo-LcaIsoString {
    <# ISO 8601 with UTC offset (v1 exported local time without one). #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$Value)
    $d = ConvertTo-LcaDateTimeOffset -Value $Value
    if ($null -eq $d) { return $null }
    $d.ToString('yyyy-MM-ddTHH:mm:sszzz', [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-LcaRoundedNumber {
    [CmdletBinding()]
    [OutputType([double])]
    param([AllowNull()]$Value, [int]$Digits = 1)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    [math]::Round([double]$Value, $Digits)
}
# ---- Private/Core/Model.ps1 ----
# The one result model. Every scanner produces ListCodingAgents.Agent objects
# through New-LcaAgent so that every property always exists (StrictMode) and
# the JSON export, the terminal renderer and the HTML report all read the
# same shape. FROZEN CONTRACT: add a property only through a contract change.

$script:LcaAgentDefaults = [ordered]@{
    # identity / detection
    Id            = $null      # catalog id, else the lowercase name
    Name          = $null      # command basename, package display name, extension id ...
    DisplayName   = $null      # catalog displayName, else Name
    Vendor        = $null
    Homepage      = $null
    CatalogId     = $null      # set when a catalog entry matched
    Verified      = $false     # catalog entry is verified against primary sources
    Command       = $null      # basename found on PATH ($null for winget/registry/extension-only rows)
    Kind          = 'cli'      # cli | editor | extension
    Tier          = 'possible' # detected | possible | excluded (excluded only kept for -Explain)
    Score         = 0
    Evidence      = @()        # ListCodingAgents.Evidence objects
    Why           = ''         # v1-style comma-separated signal labels (-ShowReasons)
    # install
    Channel       = 'unknown'  # npm pnpm bun pipx uv pip cargo brew scoop choco winget vscode registry standalone unknown
    Method        = 'unknown'  # display label for Channel ('standalone installer', 'pip / uv' ...)
    Source        = ''         # what was found: a path, a winget id, an extension folder
    Path          = $null      # resolved command path when on PATH
    Package       = $null      # package name / id in its channel
    PackageDir    = $null      # package directory when known (npm, pipx venv, extension dir ...)
    Sources       = @()        # scanners that saw it: path npm winget registry pipx uv cargo brew scoop choco vscode ...
    ChannelData   = $null      # hashtable of channel-specific facts for later phases (registry UninstallString,
                               # InstallLocation, pipx venv, brew formula, winget Available ...). Not exported.
    Shadows       = @()        # later PATH entries with the same command name
    # versions / updates
    Version       = $null
    VersionSource = $null      # package | pe | probe | probe-cache | winget | registry | manifest
    PreviousVersion = $null    # version recorded by the previous scan when it changed
    Latest        = $null
    UpdateStatus  = 'unknown'  # current | outdated | unknown
    UpdateReason  = 'not checked'  # why the status is unknown
    UpdateCommand = $null      # ListCodingAgents.Command (Exe, Arguments, Display)
    UninstallCommand = $null   # ListCodingAgents.Command or $null
    UninstallNote = $null      # e.g. 'no safe uninstall command known'
    # footprint / usage
    InstallRoot   = $null
    InstallSizeMB = $null
    DataDirs      = @()
    DataSizeMB    = $null
    LastUsed      = $null      # [DateTimeOffset] or $null
    Usage         = 'unknown'  # active | stale | unknown
    Sessions30d   = 0
    McpCount      = 0
    McpServers    = @()        # { Name, Transport } - names only, never config values
    LoggedIn      = $false     # credential FILE or KEY NAME present; values are never read out
    IsNew         = $false
}

function New-LcaAgent {
    <# Creates a ListCodingAgents.Agent with every property defaulted. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Constructor: builds an in-memory object and changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([hashtable]$Property = @{})
    $o = [ordered]@{ PSTypeName = 'ListCodingAgents.Agent' }
    foreach ($k in $script:LcaAgentDefaults.Keys) {
        $v = $script:LcaAgentDefaults[$k]
        if ($v -is [array]) { $v = @() }
        if ($k -eq 'ChannelData') { $v = @{} }
        $o[$k] = $v
    }
    foreach ($k in $Property.Keys) {
        if (-not $script:LcaAgentDefaults.Contains($k)) { throw "New-LcaAgent: unknown property '$k'" }
        $o[$k] = $Property[$k]
    }
    if (-not $o['DisplayName']) { $o['DisplayName'] = $o['Name'] }
    if (-not $o['Id'] -and $o['Name']) { $o['Id'] = ([string]$o['Name']).ToLowerInvariant() }
    [pscustomobject]$o
}

function New-LcaEvidence {
    <#
    One scoring signal: Signal (machine id), Label (human text, as v1 printed
    it), Weight, Source (where the signal came from: name, path, npm, pe,
    winget, catalog:<id> ...) and an optional Detail.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Constructor: builds an in-memory object and changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$Signal,
        [Parameter(Mandatory = $true)][string]$Label,
        [int]$Weight = 0,
        [string]$Source = '',
        [string]$Detail = ''
    )
    [pscustomobject]@{
        PSTypeName = 'ListCodingAgents.Evidence'
        Signal     = $Signal
        Label      = $Label
        Weight     = $Weight
        Source     = $Source
        Detail     = $Detail
    }
}

function ConvertTo-LcaDisplayArgument {
    <# Quotes one token for copy/paste into PowerShell or a POSIX shell. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Token)
    if ($Token -eq '') { return "''" }
    if ($Token -match '^[A-Za-z0-9@%+=:,./_\-]+$') { return $Token }
    "'" + $Token.Replace("'", "''") + "'"
}

function New-LcaCommand {
    <#
    A command the user (or Update-CodingAgent) can run: an executable plus an
    argument ARRAY - never a string that gets re-parsed. Display is a
    copy/paste-safe rendering.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Constructor: builds an in-memory object and changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [AllowEmptyCollection()][string[]]$Arguments = @()
    )
    $disp = @((ConvertTo-LcaDisplayArgument -Token $Exe)) + @($Arguments | ForEach-Object { ConvertTo-LcaDisplayArgument -Token $_ })
    [pscustomobject]@{
        PSTypeName = 'ListCodingAgents.Command'
        Exe        = $Exe
        Arguments  = @($Arguments)
        Display    = ($disp -join ' ')
    }
}

function Get-LcaChannelLabel {
    <# Human label for a channel id; keeps v1's labels where v1 had them. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Channel)
    switch ($Channel) {
        'standalone' { return 'standalone installer' }
        'pip' { return 'pip' }
        'registry' { return 'installed app' }
        'vscode' { return 'editor extension' }
        { -not $_ } { return 'unknown' }
        default { return $Channel }
    }
}

function Get-LcaChannelOrder {
    <# Sort order of channels in reports (v1 order first). #>
    [CmdletBinding()]
    [OutputType([int])]
    param([string]$Channel)
    $order = @('npm', 'winget', 'pip / uv', 'pipx', 'uv', 'pip', 'scoop', 'cargo', 'bun', 'pnpm', 'brew', 'choco',
        'standalone', 'standalone installer', 'registry', 'installed app', 'vscode', 'editor extension', 'unknown')
    $i = [array]::IndexOf($order, $Channel)
    if ($i -lt 0) { return 50 }
    $i
}
# ---- Private/Core/Scan.ps1 ----
# Scan orchestrator and fleet health. One function per workstream entry point:
#   Find-LcaAgent        (A Detection)  -> rows
#   Add-LcaEnrichment    (B Enrichment) -> sizes, usage, probes
#   Add-LcaUpdateInfo    (C Updates)    -> update status, update/uninstall commands
#   Read-LcaState / Get-LcaHistoryChange (D State) -> new / gone / trend

function Select-LcaAgentInScope {
    <#
    Display scope: CLIs always; editors with IncludeEditors; extensions with
    IncludeExtensions. Optional -Tier filter. Never used for history.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [AllowEmptyCollection()][object[]]$Agent = @(),
        [ValidateSet('detected', 'possible', 'any')][string]$Tier = 'any'
    )
    $o = $Context.Options
    $out = foreach ($a in @($Agent)) {
        if ($a.Tier -eq 'excluded') { continue }
        if ($Tier -ne 'any' -and $a.Tier -ne $Tier) { continue }
        if ($a.Kind -eq 'editor' -and -not $o.IncludeEditors) { continue }
        if ($a.Kind -eq 'extension' -and -not $o.IncludeExtensions) { continue }
        $a
    }
    @($out)
}

function Get-LcaFleetRank {
    [CmdletBinding()]
    [OutputType([string])]
    param([int]$Count)
    if ($Count -le 2) { return 'MINIMALIST' }
    if ($Count -le 5) { return 'COLLECTOR' }
    if ($Count -le 9) { return 'ENTHUSIAST' }
    if ($Count -le 13) { return 'CERTIFIED HOARDER' }
    'AGENT SINGULARITY'
}

function Get-LcaFleetHealth {
    <#
    Fleet numbers. The headline count, rank, disk total and trend use DETECTED
    CLIs only so they stay comparable between runs whatever the display
    switches; dead weight / conflicts / outdated cover the display scope.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)]$Context, [AllowEmptyCollection()][object[]]$Agent = @())
    $cli = @($Agent | Where-Object { $_.Tier -eq 'detected' -and $_.Kind -eq 'cli' })
    $scopeDetected = @(Select-LcaAgentInScope -Context $Context -Agent $Agent -Tier 'detected')
    $scopeAll = @(Select-LcaAgentInScope -Context $Context -Agent $Agent)
    $scopePossible = @($scopeAll | Where-Object { $_.Tier -eq 'possible' })
    $total = 0.0
    foreach ($a in $cli) { if ($a.InstallSizeMB) { $total += [double]$a.InstallSizeMB } }
    $dead = @($scopeDetected | Where-Object { $_.Usage -eq 'stale' })
    $reclaim = 0.0
    foreach ($a in $dead) { if ($a.InstallSizeMB) { $reclaim += [double]$a.InstallSizeMB } }
    $active = @($cli | Where-Object { $_.LastUsed -and ($Context.Now - $_.LastUsed).TotalDays -le 30 }).Count
    $channels = @($scopeDetected | ForEach-Object { $_.Method } | Select-Object -Unique).Count
    [pscustomobject]@{
        PSTypeName    = 'ListCodingAgents.FleetHealth'
        DetectedCount = $cli.Count
        ScopeDetected = $scopeDetected.Count
        PossibleCount = $scopePossible.Count
        Channels      = $channels
        TotalMB       = [math]::Round($total, 1)
        ReclaimMB     = [math]::Round($reclaim, 1)
        Active30      = $active
        Rank          = (Get-LcaFleetRank -Count $cli.Count)
        DeadWeight    = @($dead | ForEach-Object { $_.Id })
        Conflicts     = @($scopeAll | Where-Object { @($_.Shadows).Count -gt 0 } | ForEach-Object { $_.Id })
        Outdated      = @($scopeAll | Where-Object { $_.UpdateStatus -eq 'outdated' } | ForEach-Object { $_.Id })
    }
}

function Invoke-LcaScan {
    <#
    Runs a full scan and returns a ListCodingAgents.Scan:
    { SchemaVersion, ToolVersion, GeneratedAt, HostName, UserName, Platform,
      PowerShell, Options, Scope, Agents, Changes, Health, History,
      Diagnostics, Timings, Config }
    Agents holds every row that reached a tier, all kinds (display scope is
    applied by the renderers via Select-LcaAgentInScope).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)]$Context)
    Clear-LcaDiagnostic
    $state = Measure-LcaPhase -Context $Context -Name 'state-read' -ScriptBlock { Read-LcaState -Context $Context }
    foreach ($k in $state.Probes.Keys) { $Context.ProbeCache[$k] = $state.Probes[$k] }

    Write-LcaProgress -Context $Context -Status 'detecting agents' -PercentComplete 5
    $agents = Measure-LcaPhase -Context $Context -Name 'detect' -ScriptBlock { Find-LcaAgent -Context $Context }
    $agents = @($agents)
    Write-LcaProgress -Context $Context -Status 'sizes, usage, versions' -PercentComplete 45
    Measure-LcaPhase -Context $Context -Name 'enrich' -ScriptBlock { Add-LcaEnrichment -Context $Context -Agent $agents }
    Write-LcaProgress -Context $Context -Status 'update information' -PercentComplete 75
    Measure-LcaPhase -Context $Context -Name 'updates' -ScriptBlock { Add-LcaUpdateInfo -Context $Context -Agent $agents }
    Write-LcaProgress -Context $Context -Completed
    $health = Get-LcaFleetHealth -Context $Context -Agent $agents
    $changes = Measure-LcaPhase -Context $Context -Name 'history' -ScriptBlock {
        Get-LcaHistoryChange -Context $Context -State $state -Agent $agents -TotalMB $health.TotalMB
    }
    # Partial = winget exists but was not read (skipped or failed). A machine
    # without winget is fully scanned: there are no winget-only agents to miss
    # (v1 treated it as partial forever, so it never recorded a trend - N6).
    $wingetScanned = [bool]$Context.Data['wingetScanned']
    $partialReason = $null
    if ($Context.Data['wingetAvailable'] -and -not $wingetScanned) {
        $partialReason = 'winget query failed'
        if ($Context.Options.SkipWinget) { $partialReason = '-SkipWinget' }
    }
    $edition = 'Desktop'
    if (-not (Test-LcaDesktopEdition)) { $edition = 'Core' }
    [pscustomobject]@{
        PSTypeName    = 'ListCodingAgents.Scan'
        SchemaVersion = $script:LcaSchemaVersion
        ToolVersion   = $script:LcaToolVersion
        GeneratedAt   = $Context.Now
        HostName      = (Get-LcaHostName)
        UserName      = (Get-LcaUserName)
        HomeDir       = (Get-LcaKnownFolder -Name 'Home')
        Platform      = $Context.Platform
        PowerShell    = ('{0} {1}' -f $PSVersionTable.PSVersion, $edition)
        Options       = $Context.Options
        Scope         = [pscustomobject]@{
            IncludeEditors    = [bool]$Context.Options.IncludeEditors
            IncludeExtensions = [bool]$Context.Options.IncludeExtensions
            WingetScanned     = $wingetScanned
            Partial           = [bool]$partialReason
            PartialReason     = $partialReason
        }
        Agents        = $agents
        Changes       = $changes
        Health        = $health
        History       = @($changes.History)
        Diagnostics   = @(Get-LcaDiagnostic)
        Timings       = $Context.Timings
        Config        = $Context.Config
    }
}
# ---- Private/Detection/Classify.ps1 ----
# Install channel, kind and version-info text for a PATH candidate
# (ported from v1 Get-Method / Get-Kind / Get-PeText). Paths are normalised
# to '/' before matching so the same rules work on every platform.

function Get-LcaInstallChannel {
    <#
    Returns { Channel, Method } for a command path. Channel is the machine id,
    Method the display label v1 used.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()][AllowEmptyString()][string]$Path)
    $mk = { param($c, $m) [pscustomobject]@{ Channel = $c; Method = $m } }
    if (-not $Path) { return (& $mk 'unknown' 'unknown') }
    $p = ConvertTo-LcaSignaturePath -Path $Path
    if ($p -match '(?i)/AppData/Roaming/npm/|/node_modules/') { return (& $mk 'npm' 'npm') }
    if ($p -match '(?i)/WindowsApps/|/WinGet/') { return (& $mk 'winget' 'winget') }
    if ($p -match '(?i)/Python/.*/Scripts/|/uv/|/pipx/') { return (& $mk 'pip' 'pip / uv') }
    if ($p -match '(?i)/scoop/') { return (& $mk 'scoop' 'scoop') }
    if ($p -match '(?i)/\.cargo/bin/') { return (& $mk 'cargo' 'cargo') }
    if ($p -match '(?i)/\.bun/bin/') { return (& $mk 'bun' 'bun') }
    # v1 had a separate '\.local\bin\|\Programs\' branch with the same result.
    & $mk 'standalone' 'standalone installer'
}

function Get-LcaAgentKind {
    <# 'editor' for GUI editor launchers, else 'cli' (v1 Get-Kind). #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Path, [AllowNull()][AllowEmptyString()][string]$Name)
    $p = ConvertTo-LcaSignaturePath -Path $Path
    if ($p -match '(?i)/Programs/(cursor|windsurf|kiro|trae|trae-cn)/' -or
        $Name -match '^(cursor|windsurf|kiro|trae|trae-cn)$') { return 'editor' }
    'cli'
}

function Get-LcaPeText {
    <#
    Version-info text of an .exe: { Text, Publisher, Version }. Node/Bun
    runtime wrappers are noise for classification and their version is not
    the agent's version, so they contribute nothing.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()][AllowEmptyString()][string]$Path)
    $empty = [pscustomobject]@{ Text = ''; Publisher = ''; Version = '' }
    if (-not $Path -or $Path -notmatch '(?i)\.exe$') { return $empty }
    $vi = Get-LcaFileVersionInfo -Path $Path
    if (-not $vi) { return $empty }
    if ($vi.CompanyName -match '(?i)^(Node\.js|Oven)$' -or $vi.ProductName -match '(?i)^(Node\.js|Bun)$') { return $empty }
    $ver = $vi.ProductVersion
    if (-not $ver) { $ver = $vi.FileVersion }
    [pscustomobject]@{
        Text      = (@($vi.ProductName, $vi.FileDescription) -join ' ').Trim()
        Publisher = [string]$vi.CompanyName
        Version   = [string]$ver
    }
}
# ---- Private/Detection/Explain.ps1 ----
# -Explain <name>: the full scoring breakdown for one command or package,
# including why it was excluded. Workstream A owns the content.

function Get-LcaExplanation {
    <#
    Returns { Name, Found, Lines } where Lines is the human-readable
    breakdown the CLI prints verbatim. Found is $false when nothing by that
    name was seen by any source.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Scan,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $hits = @($Scan.Agents | Where-Object { $_.Name -eq $Name -or $_.Command -eq $Name -or $_.Id -eq $Name -or $_.Package -eq $Name })
    $lines = New-Object System.Collections.Generic.List[string]
    $t = $Context.Catalog.scoring.thresholds
    $lines.Add(("tiers: detected >= {0}, possible >= {1}" -f $t.detected, $t.possible))
    if (-not $hits.Count) {
        $lines.Add(("{0}: not found by any source (not on PATH, not a known package)" -f $Name))
    }
    foreach ($a in $hits) {
        $lines.Add(("{0}: score {1} -> {2} ({3}, {4})" -f $a.Name, $a.Score, $a.Tier, $a.Kind, $a.Method))
        foreach ($e in @($a.Evidence)) {
            $lines.Add(("  {0,4}  {1} [{2}]" -f $e.Weight, $e.Label, $e.Source))
        }
    }
    [pscustomobject]@{ Name = $Name; Found = [bool]$hits.Count; Lines = $lines.ToArray() }
}
# ---- Private/Detection/Find-LcaAgent.ps1 ----
# Detection entry point: every source -> scored ListCodingAgents.Agent rows.
# Returns ALL rows that reached a tier (detected / possible), regardless of
# kind. Display scope (-IncludeEditors etc.) is applied by consumers, never
# here, so history always sees the unfiltered set.

function Find-LcaAgent {
    <#
    Runs every detection source and returns Agent rows with Tier 'detected'
    or 'possible' (plus 'excluded' rows for the -Explain target only).
    Side data for later phases goes to $Context.Data (contract):
      npm             command -> npm package metadata
      npmRoot         npm global root
      wingetAvailable winget is installed
      wingetScanned   the winget list was read (a full scan)
      wingetPackages  every parsed winget row { Name, Id, Version, Available, Source }
                      (C reads Available from here: one winget call per scan)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param([Parameter(Mandatory = $true)]$Context)
    $model = Get-LcaScoringModel -Catalog $Context.Catalog
    $rows = New-Object System.Collections.Generic.List[object]
    $have = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    $explain = $Context.Options.Explain
    $detectedAt = [int]$model.Thresholds.detected

    $npm = Measure-LcaPhase -Context $Context -Name 'npm-metadata' -ScriptBlock { Get-LcaNpmPackageMap -Context $Context }
    $Context.Data['npm'] = $npm

    $candidates = Measure-LcaPhase -Context $Context -Name 'path-scan' -ScriptBlock { Get-LcaPathCandidate -Context $Context }
    foreach ($c in @($candidates)) {
        $name = $c.Command; $path = $c.Path
        # Skip hidden/backup/old launcher basenames (e.g. .jcode-launcher-old-...).
        if ($name.StartsWith('.')) { continue }

        $text = $name; $deps = @(); $publisher = ''
        $version = $null; $verSrc = $null; $package = $null; $pkgDir = $null
        $ch = Get-LcaInstallChannel -Path $path
        $channel = $ch.Channel; $method = $ch.Method
        $kind = Get-LcaAgentKind -Path $path -Name $name
        $sources = @('path')

        if ($npm.ContainsKey($name)) {
            $m = $npm[$name]
            $text = $m.Text; $deps = $m.Deps; $channel = 'npm'; $method = 'npm'
            if ($m.Version) { $version = $m.Version; $verSrc = 'package' }
            $package = $m.Package; $pkgDir = $m.Dir
            $sources += 'npm'
        }

        $pe = Get-LcaPeText -Path $path
        if ($pe.Text) { $text = (@($text, $pe.Text) -join ' ').Trim() }
        if ($pe.Publisher) { $publisher = $pe.Publisher }
        if (-not $version -and $pe.Version -match '(\d+(\.\d+)+)') { $version = $Matches[1]; $verSrc = 'pe' }

        $s = Get-LcaAgentScore -Text $text -Deps $deps -Publisher $publisher -Name $name -Path $path -Model $model
        $score = $s.Score; $evidence = $s.Evidence; $why = $s.Why
        if ($Context.Extra.Contains($name) -and $score -lt $detectedAt) {
            $score = [int]$model.Weights.extraOverride
            $evidence = @(New-LcaEvidence -Signal 'override-extra' -Label 'agents-extra.txt override' -Weight $score -Source 'agents-extra.txt')
            $why = 'agents-extra.txt override'
        }
        # exclude wins over extra - it is the user's last word on a false positive
        if ($Context.Exclude.Contains($name)) {
            $score = [int]$model.Weights.excluded
            $evidence = @(New-LcaEvidence -Signal 'override-exclude' -Label 'agents-exclude.txt override' -Weight $score -Source 'agents-exclude.txt')
            $why = 'agents-exclude.txt override'
        }
        $tier = Get-LcaTier -Score $score -Model $model
        if ($tier -eq 'excluded' -and -not ($explain -and $explain -eq $name)) { continue }

        if ($tier -ne 'excluded') { [void]$have.Add($name) }
        $rows.Add((New-LcaAgent -Property @{
                    Name = $name; Command = $name; Source = $path; Path = $path
                    Channel = $channel; Method = $method; Kind = $kind
                    Score = $score; Tier = $tier; Evidence = @($evidence); Why = $why
                    Version = $version; VersionSource = $verSrc; Package = $package; PackageDir = $pkgDir
                    Sources = $sources; Shadows = @($c.Shadows)
                }))
    }

    # winget packages (catches agents that aren't on PATH, e.g. Codex).
    # wingetScanned drives the partial-scan handling: a run that never looked
    # at winget must not claim winget-only agents disappeared.
    $Context.Data['wingetScanned'] = $false
    $Context.Data['wingetAvailable'] = [bool](Find-LcaExecutable -Name 'winget')
    if (-not $Context.Options.SkipWinget -and $Context.Data['wingetAvailable']) {
        $wg = Measure-LcaPhase -Context $Context -Name 'winget' -ScriptBlock { Get-LcaWingetPackage }
        if ($wg.Scanned) {
            $Context.Data['wingetScanned'] = $true
            foreach ($p in @($wg.Packages)) {
                $pkgName = $p.Name; $id = $p.Id
                $publisher = ($id -split '\.')[0]
                $key = (($pkgName -split '\s+')[0]).ToLowerInvariant()
                if ($have.Contains($key)) { continue }    # already found on PATH
                # match agents-exclude.txt on the display name or its first word,
                # since winget rows are keyed on "Codex"-style names, not basenames
                if ($Context.Exclude.Contains($key) -or $Context.Exclude.Contains($pkgName.ToLowerInvariant())) { continue }
                $s = Get-LcaAgentScore -Text ("$pkgName $id") -Deps @() -Publisher $publisher -Name $pkgName -Path $id -Model $model
                $tier = Get-LcaTier -Score $s.Score -Model $model
                if ($tier -eq 'excluded') { continue }
                $ver = $null
                if ($p.Version -match '^(\d+(\.\d+)+)') { $ver = $Matches[1] }
                elseif ($id -match '_(\d+(\.\d+)+)_') { $ver = $Matches[1] }
                [void]$have.Add($key)
                $rows.Add((New-LcaAgent -Property @{
                            Name = $pkgName; Command = $null; Source = $id
                            Channel = 'winget'; Method = 'winget'; Kind = 'cli'
                            Score = $s.Score; Tier = $tier; Evidence = @($s.Evidence); Why = $s.Why
                            Version = $ver; VersionSource = $(if ($ver) { 'winget' } else { $null }); Package = $id
                            Sources = @('winget')
                        }))
            }
        }
    }
    $rows.ToArray()
}
# ---- Private/Detection/NpmPackage.ps1 ----
# npm global packages: command -> rich metadata (ported from v1 Get-NpmMeta).

function Read-LcaPackageJsonMeta {
    <#
    Reads one package.json and returns
    { Package, Version, Dir, Text, Deps, Commands } or $null when the package
    has no bin.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][string]$Dir, [string]$Source = 'npm')
    $pj = Join-Path -Path $Dir -ChildPath 'package.json'
    if (-not (Test-Path -LiteralPath $pj -PathType Leaf)) { return $null }
    try {
        $j = ConvertFrom-LcaJson -Text (Read-LcaTextFile -Path $pj)
    } catch {
        Add-LcaDiagnostic -Source $Source -Level 'info' -Message "unreadable package.json in $Dir" -ErrorRecord $_ -NoExceptionText
        return $null
    }
    $bin = Get-LcaProperty -InputObject $j -Name 'bin'
    if (-not $bin) { return $null }
    $pkgName = [string](Get-LcaProperty -InputObject $j -Name 'name' -Default '')
    $cmds = @()
    if ($bin -is [string]) {
        $fallback = if ($pkgName) { ($pkgName -split '/')[-1] } else { Split-Path -Path $Dir -Leaf }
        $cmds = @($fallback)
    } else {
        $cmds = @($bin.PSObject.Properties | ForEach-Object { $_.Name })
    }
    $deps = New-Object System.Collections.Generic.List[string]
    foreach ($section in @('dependencies', 'optionalDependencies', 'peerDependencies')) {
        $block = Get-LcaProperty -InputObject $j -Name $section
        if ($block) {
            foreach ($p in $block.PSObject.Properties) { $deps.Add([string]$p.Name) }
        }
    }
    $kw = @()
    $kwRaw = Get-LcaProperty -InputObject $j -Name 'keywords'
    if ($kwRaw) { $kw = @($kwRaw | ForEach-Object { [string]$_ }) }
    $desc = [string](Get-LcaProperty -InputObject $j -Name 'description' -Default '')
    [pscustomobject]@{
        Package  = $pkgName
        Version  = [string](Get-LcaProperty -InputObject $j -Name 'version' -Default '')
        Dir      = $Dir
        Text     = ((@($pkgName, $desc) + $kw) -join ' ')
        Deps     = $deps.ToArray()
        Commands = @($cmds | Where-Object { $_ })
    }
}

function Get-LcaNpmPackageMap {
    <#
    Map of lowercase command name -> package metadata for every globally
    installed npm package with a bin. Empty when npm is missing or fails.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory = $true)]$Context)
    $map = @{}
    $npm = Find-LcaExecutable -Name 'npm'
    if (-not $npm) { return $map }
    $r = Invoke-LcaProcess -FilePath $npm -ArgumentList @('root', '-g') -TimeoutSec 30
    if ($r.Failed) {
        Add-LcaDiagnostic -Source 'npm' -Message ("npm root -g failed: {0}" -f $r.Error)
        return $map
    }
    $root = (($r.StdOut -split "`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
    if ($root) { $root = $root.Trim() }
    if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) {
        Add-LcaDiagnostic -Source 'npm' -Level 'info' -Message 'npm global root not found'
        return $map
    }
    $Context.Data['npmRoot'] = $root
    $pkgDirs = New-Object System.Collections.Generic.List[string]
    foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -like '@*') {
            foreach ($sub in @(Get-ChildItem -LiteralPath $d.FullName -Directory -ErrorAction SilentlyContinue)) { $pkgDirs.Add($sub.FullName) }
        } else {
            $pkgDirs.Add($d.FullName)
        }
    }
    foreach ($dir in $pkgDirs) {
        $meta = Read-LcaPackageJsonMeta -Dir $dir -Source 'npm'
        if (-not $meta) { continue }
        foreach ($c in $meta.Commands) { $map[$c.ToLowerInvariant()] = $meta }
    }
    $map
}
# ---- Private/Detection/PathScan.ps1 ----
# Candidate commands from PATH (ported from v1 Get-PathCandidates, now
# through the provider seam so PATH is split on the platform separator).

function Get-LcaPathCandidate {
    <#
    Every runnable file on PATH outside the OS directories, one entry per
    command name: { Command, Path, Shadows }. The first PATH entry wins; the
    same name in a LATER directory is recorded in Shadows (a PATH conflict).
    Windows: extensions from PATHEXT plus .PS1, %WINDIR% skipped except
    WindowsApps (winget shims live there). Elsewhere: files with an execute
    bit.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param([Parameter(Mandatory = $true)]$Context)
    $win = $Context.Platform -eq 'windows'
    $exts = @()
    if ($win) {
        $pathext = Get-LcaEnvironmentVariable -Name 'PATHEXT'
        if (-not $pathext) { $pathext = '.COM;.EXE;.BAT;.CMD' }
        $exts = @(@($pathext.Split(';') | Where-Object { $_ } | ForEach-Object { $_.ToUpperInvariant() }) + @('.PS1') | Select-Object -Unique)
    }
    $winDir = Get-LcaKnownFolder -Name 'WinDir'
    $seen = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::OrdinalIgnoreCase)

    foreach ($dir in Get-LcaPathEntry) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        # Skip pure Windows system dirs (keep WindowsApps for winget shims).
        if ($win -and $winDir -and $dir.StartsWith($winDir, [StringComparison]::OrdinalIgnoreCase) -and
            $dir -notmatch '(?i)\\WindowsApps$') { continue }
        $files = @()
        try { $files = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction Stop) } catch {
            Add-LcaDiagnostic -Source 'path' -Level 'info' -Message "cannot list PATH entry $dir" -ErrorRecord $_
            continue
        }
        foreach ($f in $files) {
            if ($win) {
                if ($exts -notcontains $f.Extension.ToUpperInvariant()) { continue }
                $name = $f.BaseName.ToLowerInvariant()
            } else {
                if (-not (Test-LcaUnixExecutable -Path $f.FullName)) { continue }
                $name = $f.Name.ToLowerInvariant()
            }
            if (-not $name) { continue }
            if (-not $seen.Contains($name)) {
                $seen[$name] = [pscustomobject]@{ Command = $name; Path = $f.FullName; Shadows = @() }
            } else {
                $first = $seen[$name]
                if ($first.Path -ne $f.FullName -and ((Split-Path -Path $first.Path -Parent) -ne (Split-Path -Path $f.FullName -Parent))) {
                    # same command name in a later PATH dir - it is shadowed
                    $first.Shadows = @($first.Shadows) + @($f.FullName)
                }
            }
        }
    }
    @($seen.Values)
}
# ---- Private/Detection/Scoring.ps1 ----
# Heuristic scorer (ported from v1 Get-AgentScore). Every weight, threshold
# and lexicon lives in ONE table: the "scoring" block of data/catalog.json.
# The scorer returns structured evidence ({Signal, Label, Weight, Source})
# instead of v1's comma-joined string; Why keeps v1's text for -ShowReasons.

$script:LcaScoringModelCache = $null

function Get-LcaScoringModel {
    <#
    Compiles the catalog's scoring table plus the command / path-signature
    sets derived from catalog entries:
      KnownCommands     - commands of non-ambiguous entries (v1 $KnownCli)
      AmbiguousCommands - commands of ambiguous entries     (v1 $AmbiguousCli)
      PathSignatures    - union of entry signatures, matched against paths
                          normalised to '/' (v1 $PathSignatures used '\')
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)]$Catalog, [switch]$Force)
    if ($script:LcaScoringModelCache -and -not $Force -and [object]::ReferenceEquals($script:LcaScoringModelCache.Catalog, $Catalog)) {
        return $script:LcaScoringModelCache
    }
    $cmp = [StringComparer]::OrdinalIgnoreCase
    $known = New-Object System.Collections.Generic.HashSet[string] ($cmp)
    $ambig = New-Object System.Collections.Generic.HashSet[string] ($cmp)
    $sigs = New-Object System.Collections.Generic.List[string]
    $byCommand = @{}
    foreach ($e in @($Catalog.agents)) {
        $isAmb = [bool](Get-LcaProperty -InputObject $e -Name 'ambiguous' -Default $false)
        foreach ($c in @(Get-LcaProperty -InputObject $e -Name 'commands' -Default @())) {
            if (-not $c) { continue }
            $lc = ([string]$c).ToLowerInvariant()
            if ($isAmb) { [void]$ambig.Add($lc) } else { [void]$known.Add($lc) }
            if (-not $byCommand.ContainsKey($lc)) { $byCommand[$lc] = $e }
        }
        foreach ($s in @(Get-LcaProperty -InputObject $e -Name 'pathSignatures' -Default @())) {
            if ($s -and -not $sigs.Contains([string]$s)) { $sigs.Add([string]$s) }
        }
    }
    # a name listed both ways counts as known (v1: $isAmbig = -not $isKnown -and ...)
    $sc = $Catalog.scoring
    $lex = $sc.lexicons
    $model = [pscustomobject]@{
        Catalog           = $Catalog
        Weights           = $sc.weights
        Thresholds        = $sc.thresholds
        Lexicons          = $lex
        BrandCommandRegex = ('^(?:' + $lex.brandWords + ')' + $lex.brandCommandSuffix + '$')
        KnownCommands     = $known
        AmbiguousCommands = $ambig
        PathSignatures    = $sigs.ToArray()
        EntryByCommand    = $byCommand
    }
    $script:LcaScoringModelCache = $model
    $model
}

function ConvertTo-LcaSignaturePath {
    <# Normalises a path for signature matching: '\' -> '/'. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Path)
    if (-not $Path) { return '' }
    $Path.Replace('\', '/')
}

function Get-LcaAgentScore {
    <#
    Scores one candidate. Inputs mirror v1: Text (package description,
    keywords, version-info text), Deps (dependency names), Publisher,
    Name (command basename or package display name) and Path (used ONLY for
    install-path signatures - never folded into the scored text, so sibling
    tools in an agent's install dir do not inherit its brand).
    Returns { Score, Evidence, Why, Excluded }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [AllowNull()][AllowEmptyCollection()][string[]]$Deps,
        [AllowNull()][AllowEmptyString()][string]$Publisher,
        [AllowNull()][AllowEmptyString()][string]$Name,
        [AllowNull()][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory = $true)]$Model
    )
    $w = $Model.Weights
    $lex = $Model.Lexicons
    # NB: PowerShell variable names are case-insensitive - $name IS $Name, so
    # it must be computed in one expression from the parameter.
    $name = if ($Name) { $Name.ToLowerInvariant() } else { '' }
    if ($null -eq $Deps) { $Deps = @() }
    $t = (@($Text, ($Deps -join ' '), $Publisher, $name) -join ' ')
    $tLower = $t.ToLowerInvariant()
    $ev = New-Object System.Collections.Generic.List[object]

    $excluded = {
        param($signal, $label)
        $e = New-LcaEvidence -Signal $signal -Label $label -Weight $w.excluded -Source 'name'
        [pscustomobject]@{ Score = [int]$w.excluded; Evidence = @($e); Why = $label; Excluded = $true }
    }

    # Pure MCP utilities / non-agents bail early unless the name is a known
    # CLI. Ambiguous names deliberately do NOT get the bypass: an
    # "amp-mcp-server" or "sg-updater" is still filtered by the guards below.
    $isKnown = $Model.KnownCommands.Contains($name)
    $isAmbig = (-not $isKnown) -and $Model.AmbiguousCommands.Contains($name)
    if (-not $isKnown) {
        if ($name -match $lex.mcpUtilityName) { return (& $excluded 'excluded-mcp-utility' 'excluded (mcp utility)') }
        # "CLI to install <x> skill ..." is a skill installer, never an agent -
        # unconditional (loose phrases like "ai coding" would otherwise keep it
        # alive via the agent-phrase guard below).
        if ($tLower -match $lex.skillInstaller) { return (& $excluded 'excluded-skill-installer' 'excluded (skill installer)') }
        if ($tLower -match $lex.hardExclude -and $tLower -notmatch $lex.agentPhrase) {
            return (& $excluded 'excluded-non-agent-phrase' 'excluded (non-agent phrase)')
        }
        if ($name -match $lex.helperName) { return (& $excluded 'excluded-helper-binary' 'excluded (helper binary)') }
    }

    if ($isKnown) {
        $ev.Add((New-LcaEvidence -Signal 'known-command' -Label 'known CLI name' -Weight $w.knownCommand -Source 'name' -Detail $name))
    } elseif ($isAmbig) {
        # Enough for the review tier, never enough to auto-detect alone:
        # ast-grep's "sg" must not be announced as a coding agent on a machine
        # that has never installed one.
        $ev.Add((New-LcaEvidence -Signal 'ambiguous-command' -Label 'ambiguous CLI name (needs corroboration)' -Weight $w.ambiguousCommand -Source 'name' -Detail $name))
    }

    # Path signatures only boost the primary agent CLI, not sibling tools.
    if ($Path -and ($isKnown -or $isAmbig -or $name -match $Model.BrandCommandRegex)) {
        $np = ConvertTo-LcaSignaturePath -Path $Path
        foreach ($pat in $Model.PathSignatures) {
            if ($np -match ('(?i)' + $pat)) {
                $ev.Add((New-LcaEvidence -Signal 'path-signature' -Label 'install path signature' -Weight $w.pathSignature -Source 'path' -Detail $pat))
                break
            }
        }
    }

    if ($tLower -match $lex.agentPhrase) {
        $ev.Add((New-LcaEvidence -Signal 'agent-phrase' -Label 'coding-agent phrase' -Weight $w.agentPhrase -Source 'text' -Detail $Matches[0]))
    }

    # Vendor from version-info CompanyName / package text only (never path).
    $vendorText = (@($Publisher, $Text) -join ' ')
    if ($vendorText -match ('(?i)(' + $lex.aiVendors + ')')) {
        $vendorHit = $Matches[1]
        if ($Publisher -notmatch $lex.vendorPublisherIgnore) {
            $ev.Add((New-LcaEvidence -Signal 'ai-vendor' -Label 'AI vendor' -Weight $w.aiVendor -Source 'vendor' -Detail $vendorHit))
        }
    }

    $sdkHits = @($Deps | Where-Object { $_ -and ($_ -match $lex.aiSdkDependency) })
    if ($sdkHits.Count -gt 0) {
        $ev.Add((New-LcaEvidence -Signal 'ai-sdk' -Label 'AI SDK dependency' -Weight $w.aiSdkDependency -Source 'dependencies' -Detail ($sdkHits -join ' ')))
    }

    if ($tLower -match $lex.agentWord -and $tLower -match $lex.agentContext) {
        $ev.Add((New-LcaEvidence -Signal 'agent-code' -Label 'agent + code' -Weight $w.agentPlusCode -Source 'text'))
    }

    if ($tLower -match ('(?i)(' + $lex.brandWords + ')')) {
        $brandHit = $Matches[1]
        $ev.Add((New-LcaEvidence -Signal 'brand' -Label 'model/brand name' -Weight $w.brandName -Source 'text' -Detail $brandHit))
        if ($tLower -match $lex.brandContext) {
            $ev.Add((New-LcaEvidence -Signal 'brand-cli' -Label 'brand + cli/code' -Weight $w.brandPlusCli -Source 'text'))
        }
        # Basename is the brand word itself, with or without the usual agent
        # suffix - "kimi", "kimi-cli" and "claude-code" all qualify.
        if ($name -match $Model.BrandCommandRegex) {
            $ev.Add((New-LcaEvidence -Signal 'brand-command' -Label 'brand command' -Weight $w.brandCommand -Source 'name' -Detail $name))
        }
    }

    if ($tLower -match $lex.aiToken -and $tLower -match $lex.aiContext) {
        $ev.Add((New-LcaEvidence -Signal 'ai-code' -Label 'ai + code token' -Weight $w.aiPlusCode -Source 'text'))
    }

    $score = 0
    foreach ($e in $ev) { $score += $e.Weight }
    [pscustomobject]@{
        Score    = [int]$score
        Evidence = $ev.ToArray()
        Why      = (@($ev | ForEach-Object { $_.Label }) -join ', ')
        Excluded = $false
    }
}

function Get-LcaTier {
    <# 'detected' / 'possible' / 'excluded' from a score, using the table. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][int]$Score, [Parameter(Mandatory = $true)]$Model)
    if ($Score -ge [int]$Model.Thresholds.detected) { return 'detected' }
    if ($Score -ge [int]$Model.Thresholds.possible) { return 'possible' }
    'excluded'
}
# ---- Private/Detection/Winget.ps1 ----
# winget package list (ported from v1: split on 2+ spaces). Workstream A
# replaces the parser with column offsets / Microsoft.WinGet.Client.

function Get-LcaWingetPackage {
    <#
    Returns { Scanned, Packages } where Packages holds
    { Name, Id, Version, Available } per installed winget package. Scanned is
    $false when winget is missing or failed, so callers can tell "not
    scanned" from "scanned, nothing found".
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $res = [pscustomobject]@{ Scanned = $false; Packages = @() }
    $winget = Find-LcaExecutable -Name 'winget'
    if (-not $winget) { return $res }
    $r = Invoke-LcaProcess -FilePath $winget -ArgumentList @('list', '--disable-interactivity') -TimeoutSec 120
    if ($r.Failed -and -not $r.StdOut) {
        Add-LcaDiagnostic -Source 'winget' -Message ("winget list failed: {0}" -f $r.Error)
        return $res
    }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($line in ($r.StdOut -split "`r?`n")) {
        if ($line -notmatch '[A-Za-z]') { continue }   # progress bars / blank lines
        $parts = @($line -split '\s{2,}' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($parts.Count -lt 2) { continue }
        $pkgName = $parts[0]; $id = $parts[1]
        if ($pkgName -eq 'Name' -or $id -eq 'Id') { continue }
        if ($pkgName -match '^(The following|No installed|-{2,})') { continue }
        $ver = ''
        if ($parts.Count -ge 3) { $ver = $parts[2] }
        $out.Add([pscustomobject]@{ Name = $pkgName; Id = $id; Version = $ver; Available = $null })
    }
    $res.Scanned = $true
    $res.Packages = $out.ToArray()
    $res
}
# ---- Private/Enrichment/Add-LcaEnrichment.ps1 ----
# Enrichment entry point: sizes, usage intel, version probes.

function Add-LcaEnrichment {
    <#
    Fills InstallSizeMB, LastUsed, Sessions30d, McpCount, LoggedIn, DataDirs,
    Usage and (by probing) Version on the given rows. Mutates in place.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [AllowEmptyCollection()][object[]]$Agent = @()
    )
    $staleDays = [int]$Context.Config.StaleDays
    foreach ($r in @($Agent)) {
        if ($r.Tier -eq 'excluded') { continue }
        if ($r.Channel -eq 'npm' -and $r.PackageDir) { $r.InstallSizeMB = Get-LcaSizeMB -Path $r.PackageDir }
        elseif ($r.Source -match '(?i)\.exe$') { $r.InstallSizeMB = Get-LcaSizeMB -Path $r.Source }
        $dirs = @()
        if ($r.Command) { $dirs = @(Get-LcaConfigDirCandidate -Name $r.Command) }
        $intel = Get-LcaUsageIntel -Context $Context -Dirs $dirs
        $r.LastUsed = $intel.LastUsed
        $r.Sessions30d = $intel.Sessions30d
        $r.McpCount = $intel.McpCount
        $r.LoggedIn = $intel.LoggedIn
        $r.DataDirs = @($intel.DataDirs)
        # v1 semantics (defect 3, fixed by workstream B): no evidence = stale.
        $r.Usage = 'stale'
        if ($r.LastUsed -and ($Context.Now - $r.LastUsed).TotalDays -le $staleDays) { $r.Usage = 'active' }
    }
    if ($Context.Options.NoProbe) { return }
    foreach ($r in @($Agent | Where-Object { $_.Tier -eq 'detected' })) {
        if ($r.Version -or $r.Source -notmatch '(?i)\.exe$' -or $r.Channel -eq 'winget') { continue }
        # cache probe results per path+mtime so repeat scans skip the timeouts
        $key = Get-LcaProbeCacheKey -Path $r.Source
        if ($key -and $Context.ProbeCache.ContainsKey($key)) {
            $v = [string]$Context.ProbeCache[$key]
            if ($v -and $v -ne '?') { $r.Version = $v; $r.VersionSource = 'probe-cache' }
            continue
        }
        $v = Get-LcaVersionProbe -Path $r.Source -TimeoutSec ([double]$Context.Config.ProbeTimeoutSec)
        if ($v) { $r.Version = $v; $r.VersionSource = 'probe' }
        if ($key) { $Context.ProbeCache[$key] = $(if ($v) { $v } else { '?' }) }
    }
}
# ---- Private/Enrichment/Probe.ps1 ----
# Version probes: bare exes carry no metadata, so ask them (`<exe> --version`)
# through the process seam - stdin closed, stdout+stderr captured, hard
# timeout with a process-tree kill - and cache the answer by path + mtime.

function Get-LcaVersionFromText {
    <# First dotted version number in a CLI's --version output. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ($Text -and $Text -match '(\d+\.\d+(\.\d+)*)') { return $Matches[1] }
    $null
}

function Get-LcaProbeCacheKey {
    <# "<path>|<mtime ticks>" (v1 key format), or $null when unreadable. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $it = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return ('{0}|{1}' -f $Path, $it.LastWriteTimeUtc.Ticks)
    } catch {
        Add-LcaDiagnostic -Source 'probe' -Level 'info' -Message "cannot stat $Path" -ErrorRecord $_
        return $null
    }
}

function Get-LcaVersionProbe {
    <# Runs `<exe> --version` with a timeout and returns the version or $null. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$ArgumentList = @('--version'),
        [double]$TimeoutSec = 8
    )
    $r = Invoke-LcaProcess -FilePath $Path -ArgumentList $ArgumentList -TimeoutSec $TimeoutSec
    if ($r.TimedOut) {
        Add-LcaDiagnostic -Source 'probe' -Level 'info' -Message ("{0} --version timed out after {1}s" -f $Path, $TimeoutSec)
        return $null
    }
    $v = Get-LcaVersionFromText -Text $r.StdOut
    if (-not $v) { $v = Get-LcaVersionFromText -Text $r.StdErr }
    $v
}
# ---- Private/Enrichment/Size.ps1 ----
# Disk footprint (ported from v1 Get-SizeMB).

function Get-LcaSizeMB {
    <#
    Size in MB of a directory (recursive) or a single file (unrounded;
    rounding happens on display / export).
    Returns $null when the path is missing or unreadable.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param([AllowNull()][AllowEmptyString()][string]$Path)
    if (-not $Path) { return $null }
    try {
        if (Test-Path -LiteralPath $Path -PathType Container) {
            $sum = 0L
            foreach ($f in Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue) { $sum += $f.Length }
        } else {
            $sum = (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).Length
        }
        return ($sum / 1MB)
    } catch {
        Add-LcaDiagnostic -Source 'size' -Level 'info' -Message "cannot measure $Path" -ErrorRecord $_
    }
    $null
}
# ---- Private/Enrichment/Usage.ps1 ----
# Usage intel from an agent's config folders (ported from v1 Get-ConfigDirs /
# Get-McpCountFromRaw / Get-AgentIntel). Presence-only: credential FILE names
# and KEY names are matched, values are never read out or stored.

function Get-LcaConfigDirCandidate {
    <#
    Likely config locations for a command, by the generic v1 rule (a folder
    or file named after the command): ~/.<n>, ~/.config/<n>, ~/.<n>.json,
    %APPDATA%\<n>, %LOCALAPPDATA%\<n>; "-cli"/"-code" suffixes are stripped too.
    Returns only paths that exist.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()][AllowEmptyString()][string]$Name)
    if (-not $Name) { return @() }
    $homeDir = Get-LcaKnownFolder -Name 'Home'
    $appData = Get-LcaKnownFolder -Name 'AppData'
    $localAppData = Get-LcaKnownFolder -Name 'LocalAppData'
    $bases = @($Name)
    if ($Name -match '-(cli|code)$') { $bases += ($Name -replace '-(cli|code)$', '') }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($b in $bases) {
        $cands = @()
        if ($homeDir) {
            $cands += (Join-Path -Path $homeDir -ChildPath ".$b")
            $cands += (Join-Path -Path (Join-Path -Path $homeDir -ChildPath '.config') -ChildPath $b)
            $cands += (Join-Path -Path $homeDir -ChildPath ".$b.json")
        }
        if ($appData) { $cands += (Join-Path -Path $appData -ChildPath $b) }
        if ($localAppData) { $cands += (Join-Path -Path $localAppData -ChildPath $b) }
        foreach ($c in $cands) {
            if ((Test-Path -LiteralPath $c) -and -not $out.Contains($c)) { $out.Add($c) }
        }
    }
    $out.ToArray()
}

function Get-LcaMcpCount {
    <#
    Counts entries directly inside every "mcpServers": { ... } block (also
    "mcp_servers" / "mcp" json keys and toml [mcp_servers.x] sections)
    without fully parsing the file - config files can be multi-MB.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([AllowNull()][AllowEmptyString()][string]$Raw)
    if (-not $Raw) { return 0 }
    $total = 0
    foreach ($pat in @('"mcpServers"\s*:\s*\{', '"mcp_servers"\s*:\s*\{', '"mcp"\s*:\s*\{')) {
        $found = 0
        foreach ($m in [regex]::Matches($Raw, $pat)) {
            $i = $m.Index + $m.Length
            $depth = 1; $inStr = $false; $esc = $false; $keys = 0; $expectKey = $true
            $limit = [math]::Min($Raw.Length, $i + 262144)
            for ($p = $i; $p -lt $limit -and $depth -gt 0; $p++) {
                $ch = $Raw[$p]
                if ($esc) { $esc = $false; continue }
                if ($ch -eq '\') { if ($inStr) { $esc = $true }; continue }
                if ($ch -eq '"') {
                    if ($inStr) { $inStr = $false }
                    else { $inStr = $true; if ($depth -eq 1 -and $expectKey) { $keys++; $expectKey = $false } }
                    continue
                }
                if ($inStr) { continue }
                if ($ch -eq '{' -or $ch -eq '[') { $depth++ }
                elseif ($ch -eq '}' -or $ch -eq ']') { $depth-- }
                elseif ($ch -eq ',' -and $depth -eq 1) { $expectKey = $true }
            }
            $found += $keys
        }
        if ($found) { $total += $found; break }   # one key style per file is enough
    }
    $total += ([regex]::Matches($Raw, '(?m)^\s*\[mcp_servers\.[^\]\.]+')).Count
    $total
}

function Get-LcaUsageIntel {
    <#
    One walk over the config dirs: newest write (last used), session-ish
    files touched in the last 30 days, MCP servers configured, and a
    credentials hint (probably logged in). Returns
    { LastUsed, Sessions30d, McpCount, LoggedIn, DataDirs }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)]$Context, [AllowEmptyCollection()][string[]]$Dirs = @())
    $res = [pscustomobject]@{ LastUsed = $null; Sessions30d = 0; McpCount = 0; LoggedIn = $false; DataDirs = @($Dirs) }
    if (-not $Dirs -or $Dirs.Count -eq 0) { return $res }
    $lastUtc = [datetime]::MinValue
    $cut = $Context.Now.UtcDateTime.AddDays(-30)
    $sessRx = '(?i)\.jsonl$|[\\/](history|sessions?|logs?|chats?|threads?|projects|transcripts?)([\\/]|$)'
    $credRx = '(?i)credential|oauth|token|\bauth\b|auth\.json|\.creds'
    $credKey = '(?i)"(api[-_]?key|access[-_]?token|refresh[-_]?token|oauth[a-z_]*|bearer)"\s*:'
    foreach ($dCfg in $Dirs) {
        $item = $null
        try { $item = Get-Item -LiteralPath $dCfg -Force -ErrorAction Stop } catch {
            Add-LcaDiagnostic -Source 'usage' -Level 'info' -Message "cannot read $dCfg" -ErrorRecord $_
            continue
        }
        if ($item.LastWriteTimeUtc -gt $lastUtc) { $lastUtc = $item.LastWriteTimeUtc }
        if (-not $item.PSIsContainer) {
            # a single config file, e.g. ~/.claude.json
            if ($item.Length -lt 15MB) {
                try {
                    $raw = [System.IO.File]::ReadAllText($item.FullName)
                    $res.McpCount += Get-LcaMcpCount -Raw $raw
                    if (-not $res.LoggedIn -and $item.Length -lt 2MB -and $raw -match $credKey) { $res.LoggedIn = $true }
                } catch {
                    Add-LcaDiagnostic -Source 'usage' -Level 'info' -Message "cannot read config file $($item.FullName)" -ErrorRecord $_ -NoExceptionText
                }
            }
            continue
        }
        $files = @(Get-ChildItem -LiteralPath $dCfg -Recurse -Depth 3 -File -Force -ErrorAction SilentlyContinue | Select-Object -First 6000)
        foreach ($f in $files) {
            if ($f.LastWriteTimeUtc -gt $lastUtc) { $lastUtc = $f.LastWriteTimeUtc }
            if ($f.LastWriteTimeUtc -ge $cut -and $f.FullName -match $sessRx) { $res.Sessions30d++ }
            if (-not $res.LoggedIn -and $f.Name -match $credRx) { $res.LoggedIn = $true }
        }
        # config-ish files: direct children only (settings.json, config.toml, mcp.json ...)
        foreach ($f in $files) {
            if ($f.DirectoryName -ne $item.FullName) { continue }
            if ($f.Extension -notmatch '(?i)^\.(json|toml)$' -or $f.Length -ge 15MB) { continue }
            try {
                $raw = [System.IO.File]::ReadAllText($f.FullName)
                $res.McpCount += Get-LcaMcpCount -Raw $raw
                if (-not $res.LoggedIn -and $f.Length -lt 2MB -and $raw -match $credKey) { $res.LoggedIn = $true }
            } catch {
                Add-LcaDiagnostic -Source 'usage' -Level 'info' -Message "cannot read config file $($f.FullName)" -ErrorRecord $_ -NoExceptionText
            }
        }
    }
    if ($lastUtc -gt [datetime]::MinValue) {
        $res.LastUsed = (New-Object System.DateTimeOffset ([datetime]::SpecifyKind($lastUtc, [System.DateTimeKind]::Utc))).ToLocalTime()
    }
    $res
}
# ---- Private/Platform/Environment.ps1 ----
# Provider seam: platform, environment, filesystem roots, clock.
# Every scanner reads the outside world through these small functions so tests
# can mock them. Nothing else in the module reads $env:, calls Get-Date or
# touches $IsWindows (which does not exist on Windows PowerShell 5.1 and throws
# under StrictMode).

function Get-LcaPlatform {
    <# Returns 'windows', 'macos' or 'linux'. #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { return 'windows' }
    $isMac = Get-Variable -Name 'IsMacOS' -ValueOnly -ErrorAction Ignore
    if ($isMac) { return 'macos' }
    'linux'
}

function Test-LcaWindows {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    (Get-LcaPlatform) -eq 'windows'
}

function Test-LcaDesktopEdition {
    <# True on Windows PowerShell 5.1 (.NET Framework). #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $PSVersionTable.PSEdition -ne 'Core'
}

function Get-LcaEnvironmentVariable {
    <# Reads one environment variable. Empty values come back as $null. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Name)
    $v = [System.Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrEmpty($v)) { return $null }
    $v
}

function Split-LcaPathList {
    <#
    Splits a PATH-style list. Entries are trimmed, unquoted, env-expanded
    (Windows), stripped of trailing separators - but a drive root stays
    "C:\" (v1's TrimEnd turned it into the drive-relative "C:") - and
    de-duplicated in order (case-insensitively on Windows).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory = $true)][char]$Separator,
        [bool]$Windows
    )
    if (-not $Value) { return @() }
    $cmp = [StringComparer]::Ordinal
    if ($Windows) { $cmp = [StringComparer]::OrdinalIgnoreCase }
    $seen = New-Object System.Collections.Generic.HashSet[string] ($cmp)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($part in $Value.Split($Separator)) {
        $p = $part.Trim().Trim('"')
        if (-not $p) { continue }
        if ($Windows -and $p.Contains('%')) { $p = [System.Environment]::ExpandEnvironmentVariables($p) }
        if ($p.Length -gt 1) {
            $trimmed = $p.TrimEnd('\', '/')
            if ($trimmed -match '^[A-Za-z]:$') { $p = $trimmed + '\' }
            elseif ($trimmed) { $p = $trimmed }
        }
        if ($seen.Add($p)) { $out.Add($p) }
    }
    $out.ToArray()
}

function Get-LcaPathEntry {
    <#
    The PATH, split on the platform separator (';' on Windows, ':' elsewhere -
    v1 always split on ';', which found nothing on Linux/macOS).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    Split-LcaPathList -Value (Get-LcaEnvironmentVariable -Name 'PATH') -Separator ([System.IO.Path]::PathSeparator) -Windows (Test-LcaWindows)
}

function Get-LcaKnownFolder {
    <#
    Filesystem roots. Windows values come from the environment (USERPROFILE,
    APPDATA, LOCALAPPDATA) so fixtures can redirect them; XDG roots honour the
    XDG_* variables (absolute paths only, per the spec) and fall back to the
    spec defaults. Returns $null when a root does not apply to the platform.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Home', 'AppData', 'LocalAppData', 'XdgConfigHome', 'XdgDataHome', 'XdgStateHome',
            'XdgCacheHome', 'AppSupport', 'WinDir', 'ProgramFiles', 'ProgramFilesX86', 'ProgramData', 'Temp')]
        [string]$Name
    )
    $platform = Get-LcaPlatform
    $homeDir = $null
    if ($platform -eq 'windows') { $homeDir = Get-LcaEnvironmentVariable -Name 'USERPROFILE' }
    if (-not $homeDir) { $homeDir = Get-LcaEnvironmentVariable -Name 'HOME' }
    if (-not $homeDir) { $homeDir = [System.Environment]::GetFolderPath('UserProfile') }

    switch ($Name) {
        'Home' { return $homeDir }
        'AppData' { if ($platform -eq 'windows') { return (Get-LcaEnvironmentVariable -Name 'APPDATA') }; return $null }
        'LocalAppData' { if ($platform -eq 'windows') { return (Get-LcaEnvironmentVariable -Name 'LOCALAPPDATA') }; return $null }
        'WinDir' { if ($platform -eq 'windows') { return (Get-LcaEnvironmentVariable -Name 'WINDIR') }; return $null }
        'ProgramFiles' { if ($platform -eq 'windows') { return (Get-LcaEnvironmentVariable -Name 'ProgramFiles') }; return $null }
        'ProgramFilesX86' { if ($platform -eq 'windows') { return (Get-LcaEnvironmentVariable -Name 'ProgramFiles(x86)') }; return $null }
        'ProgramData' { if ($platform -eq 'windows') { return (Get-LcaEnvironmentVariable -Name 'ProgramData') }; return $null }
        'AppSupport' {
            if ($platform -eq 'macos' -and $homeDir) { return (Join-Path -Path (Join-Path -Path $homeDir -ChildPath 'Library') -ChildPath 'Application Support') }
            return $null
        }
        'Temp' { return [System.IO.Path]::GetTempPath() }
    }

    # XDG roots
    $map = @{
        XdgConfigHome = @('XDG_CONFIG_HOME', '.config')
        XdgDataHome   = @('XDG_DATA_HOME', '.local/share')
        XdgStateHome  = @('XDG_STATE_HOME', '.local/state')
        XdgCacheHome  = @('XDG_CACHE_HOME', '.cache')
    }
    $spec = $map[$Name]
    $v = Get-LcaEnvironmentVariable -Name $spec[0]
    if ($v -and [System.IO.Path]::IsPathRooted($v)) { return $v }
    if ($platform -eq 'windows' -or -not $homeDir) { return $null }
    $rel = $spec[1]
    $acc = $homeDir
    foreach ($seg in $rel.Split('/')) { $acc = Join-Path -Path $acc -ChildPath $seg }
    $acc
}

function Get-LcaNow {
    <#
    The clock seam. LCA_FAKE_NOW (ISO 8601) pins the clock for fixture runs and
    screenshot generation; it is never set in normal use.
    #>
    [CmdletBinding()]
    [OutputType([System.DateTimeOffset])]
    param()
    $fake = Get-LcaEnvironmentVariable -Name 'LCA_FAKE_NOW'
    if ($fake) {
        $parsed = [System.DateTimeOffset]::MinValue
        if ([System.DateTimeOffset]::TryParse($fake, [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
            return $parsed
        }
    }
    [System.DateTimeOffset]::Now
}

function Get-LcaHostName {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $n = Get-LcaEnvironmentVariable -Name 'COMPUTERNAME'
    if (-not $n) { $n = Get-LcaEnvironmentVariable -Name 'HOSTNAME' }
    if (-not $n) {
        try { $n = [System.Net.Dns]::GetHostName() } catch { $n = $null }
    }
    $n
}

function Get-LcaUserName {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $n = Get-LcaEnvironmentVariable -Name 'USERNAME'
    if (-not $n) { $n = Get-LcaEnvironmentVariable -Name 'USER' }
    if (-not $n) {
        $homeDir = Get-LcaKnownFolder -Name 'Home'
        if ($homeDir) { $n = Split-Path -Path $homeDir -Leaf }
    }
    $n
}
# ---- Private/Platform/Network.ps1 ----
# Provider seam: the only network access (opt-in update checks: npm / PyPI /
# crates.io registry fallbacks, GitHub latest-release checks) and the
# Microsoft.WinGet.Client module. Nothing here runs unless a caller asks.

function Invoke-LcaHttpJson {
    <#
    GETs a JSON document with a timeout. Never throws; returns
    { Ok, Data, StatusCode, Error }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [int]$TimeoutSec = 15,
        [hashtable]$Headers = @{}
    )
    $res = [pscustomobject]@{ Ok = $false; Data = $null; StatusCode = $null; Error = $null }
    if ($Uri -notmatch '^https://') {
        $res.Error = 'only https URLs are allowed'
        return $res
    }
    $h = @{ 'User-Agent' = ('list-coding-agents/' + $script:LcaToolVersion); 'Accept' = 'application/json' }
    foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] }
    try {
        if (Test-LcaDesktopEdition) {
            # Windows PowerShell 5.1 does not offer TLS 1.2 by default on older systems.
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        }
        $params = @{ Uri = $Uri; Headers = $h; TimeoutSec = $TimeoutSec; Method = 'Get'; ErrorAction = 'Stop' }
        if (Test-LcaDesktopEdition) { $params['UseBasicParsing'] = $true }
        $res.Data = Invoke-RestMethod @params
        $res.Ok = $true
        $res.StatusCode = 200
    } catch {
        $res.Error = $_.Exception.Message
        $resp = $null
        try { $resp = $_.Exception.Response } catch { Write-Debug 'no response on exception' }
        if ($resp) {
            try { $res.StatusCode = [int]$resp.StatusCode } catch { Write-Debug 'no status code' }
        }
    }
    $res
}

function Get-LcaWinGetModulePackage {
    <#
    Installed packages from the Microsoft.WinGet.Client module
    (Get-WinGetPackage) when that module is available - structured data, no
    column parsing, no truncated ids. Returns $null when the module is not
    installed (callers then fall back to parsing `winget list`), else
    { Name, Id, Version, Available, Source } per package.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param()
    if (-not (Test-LcaWindows)) { return $null }
    $cmd = Get-Command -Name 'Get-WinGetPackage' -ErrorAction Ignore
    if (-not $cmd) { return $null }
    try {
        $pkgs = @(& $cmd -ErrorAction Stop)
    } catch {
        Write-Verbose "Get-WinGetPackage failed: $($_.Exception.Message)"
        return $null
    }
    $out = foreach ($p in $pkgs) {
        $props = @($p.PSObject.Properties | ForEach-Object { $_.Name })
        $avail = $null
        if ($props -contains 'IsUpdateAvailable' -and $p.IsUpdateAvailable -and $props -contains 'AvailableVersions' -and $p.AvailableVersions) {
            $avail = [string](@($p.AvailableVersions)[0])
        }
        $src = $null
        if ($props -contains 'Source') { $src = [string]$p.Source }
        $ver = $null
        if ($props -contains 'InstalledVersion') { $ver = [string]$p.InstalledVersion }
        [pscustomobject]@{ Name = [string]$p.Name; Id = [string]$p.Id; Version = $ver; Available = $avail; Source = $src }
    }
    @($out)
}
# ---- Private/Platform/Parallel.ps1 ----
# Bounded parallelism that works on Windows PowerShell 5.1 (a RunspacePool;
# ForEach-Object -Parallel is 7.0+). Runspaces do not see module functions,
# so the caller names the functions the work item needs and their
# definitions are copied into the pool's InitialSessionState.

function Invoke-LcaParallel {
    <#
    Runs $ScriptBlock once per input item with at most $ThrottleLimit running
    at a time and returns one result per item, in input order:
      { Input, Output, Error }
    The script block receives the item as its first argument. With a throttle
    of 1 (or a single item) the work runs inline in the current runspace,
    which keeps Pester mocks effective.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [AllowEmptyCollection()][object[]]$InputObject = @(),
        [int]$ThrottleLimit = 4,
        [string[]]$FunctionName = @(),
        [hashtable]$Variable = @{},
        [double]$TimeoutSec = 300
    )
    $items = @($InputObject)
    if ($items.Count -eq 0) { return @() }

    if ($ThrottleLimit -le 1 -or $items.Count -eq 1) {
        $results = foreach ($item in $items) {
            $r = [pscustomobject]@{ Input = $item; Output = $null; Error = $null }
            try { $r.Output = & $ScriptBlock $item } catch { $r.Error = $_.Exception.Message }
            $r
        }
        return @($results)
    }

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($fn in $FunctionName) {
        $cmd = Get-Command -Name $fn -CommandType Function -ErrorAction Stop
        $entry = New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry ($fn, $cmd.Definition)
        $iss.Commands.Add($entry)
    }
    foreach ($k in $Variable.Keys) {
        $ve = New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry ([string]$k, $Variable[$k], '')
        $iss.Variables.Add($ve)
    }
    $limit = [Math]::Max(1, [Math]::Min($ThrottleLimit, $items.Count))
    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $limit, $iss, $Host)
    $jobs = New-Object System.Collections.Generic.List[object]
    # StrictMode must come after the work item's own param block, so the
    # caller's script block runs nested inside a small wrapper.
    $body = "param(`$lcaItem)`nSet-StrictMode -Version Latest`n& {`n" + $ScriptBlock.ToString() + "`n} `$lcaItem"
    try {
        $pool.Open()
        foreach ($item in $items) {
            $ps = [System.Management.Automation.PowerShell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($body).AddArgument($item)
            $jobs.Add([pscustomobject]@{ Input = $item; PS = $ps; Async = $ps.BeginInvoke() })
        }
        $deadline = [System.Diagnostics.Stopwatch]::StartNew()
        $results = foreach ($j in $jobs) {
            $r = [pscustomobject]@{ Input = $j.Input; Output = $null; Error = $null }
            try {
                $left = [int][Math]::Max(1, ($TimeoutSec * 1000) - $deadline.ElapsedMilliseconds)
                if ($j.Async.AsyncWaitHandle.WaitOne($left)) {
                    $out = @($j.PS.EndInvoke($j.Async))
                    $r.Output = $out
                    if ($out.Count -eq 1) { $r.Output = $out[0] }
                    if ($j.PS.Streams.Error.Count -gt 0 -and $null -eq $r.Output) {
                        $r.Error = $j.PS.Streams.Error[0].ToString()
                    }
                } else {
                    $r.Error = 'parallel work item timed out'
                    [void]$j.PS.BeginStop($null, $null)
                }
            } catch {
                $r.Error = $_.Exception.Message
            }
            $r
        }
        return @($results)
    } finally {
        foreach ($j in $jobs) {
            try { $j.PS.Dispose() } catch { Write-Debug "runspace dispose failed: $($_.Exception.Message)" }
        }
        try { $pool.Close(); $pool.Dispose() } catch { Write-Debug "pool dispose failed: $($_.Exception.Message)" }
    }
}
# ---- Private/Platform/Process.ps1 ----
# Provider seam: running external programs (package managers, winget,
# --version probes). Uses System.Diagnostics.Process directly instead of
# Start-Job (one full PowerShell process per probe in v1): stdin is closed,
# stdout AND stderr are captured (some CLIs print their version on stderr),
# CI=1 / NO_COLOR=1 / TERM=dumb keep tools non-interactive and plain, and a
# hard timeout kills the whole process tree.

function ConvertTo-LcaArgumentString {
    <#
    Joins arguments into one command line using the MSVCRT/CommandLineToArgvW
    quoting rules. .NET applies the same rules when it splits
    ProcessStartInfo.Arguments on Linux/macOS, so one code path serves every
    platform (ProcessStartInfo.ArgumentList does not exist on .NET Framework).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyCollection()][AllowNull()][string[]]$ArgumentList)
    if ($null -eq $ArgumentList -or $ArgumentList.Count -eq 0) { return '' }
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($a in $ArgumentList) {
        if ($null -eq $a) { $a = '' }
        if ($a.Length -gt 0 -and $a -notmatch '[\s"]') { $parts.Add($a); continue }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('"')
        $bs = 0
        foreach ($ch in $a.ToCharArray()) {
            if ($ch -eq [char]'\') { $bs++; continue }
            if ($ch -eq [char]'"') {
                [void]$sb.Append([char]'\', (2 * $bs) + 1)
                [void]$sb.Append([char]'"')
                $bs = 0
                continue
            }
            if ($bs -gt 0) { [void]$sb.Append([char]'\', $bs); $bs = 0 }
            [void]$sb.Append($ch)
        }
        if ($bs -gt 0) { [void]$sb.Append([char]'\', 2 * $bs) }
        [void]$sb.Append('"')
        $parts.Add($sb.ToString())
    }
    $parts -join ' '
}

function Test-LcaSafeBatchArgument {
    <#
    cmd.exe re-parses the command line of a .cmd/.bat file, so quoting alone
    cannot make arbitrary arguments safe there. Only plain tokens (package
    names, ids, versions, flags) are allowed through.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyCollection()][AllowNull()][string[]]$ArgumentList)
    foreach ($a in @($ArgumentList)) {
        if ($null -eq $a) { continue }
        if ($a -match '[\r\n"&|<>^%!()`]') { return $false }
    }
    $true
}

function Test-LcaUnixExecutable {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $mode = [System.IO.File]::GetUnixFileMode($Path)
        return (([int]$mode -band 73) -ne 0)   # 73 = UserExecute|GroupExecute|OtherExecute (0o111)
    } catch {
        Write-Debug "unix mode check failed for ${Path}: $($_.Exception.Message)"
        return $true
    }
}

function Get-LcaPowerShellPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (Test-LcaDesktopEdition) { return (Join-Path -Path $PSHOME -ChildPath 'powershell.exe') }
    $name = 'pwsh'
    if (Test-LcaWindows) { $name = 'pwsh.exe' }
    Join-Path -Path $PSHOME -ChildPath $name
}

function Find-LcaExecutable {
    <#
    Resolves a command name against PATH (and PATHEXT on Windows) through the
    seam, so fixtures can put fake npm/winget/... shims first on PATH.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Name)
    $win = Test-LcaWindows
    if ([System.IO.Path]::IsPathRooted($Name)) {
        if ([System.IO.File]::Exists($Name)) { return $Name }
        return $null
    }
    $exts = @('')
    if ($win) {
        $pathext = Get-LcaEnvironmentVariable -Name 'PATHEXT'
        if (-not $pathext) { $pathext = '.COM;.EXE;.BAT;.CMD' }
        $exts = @($pathext.Split(';') | Where-Object { $_ })
        if ([System.IO.Path]::GetExtension($Name)) { $exts = @('') + $exts }
    }
    foreach ($dir in Get-LcaPathEntry) {
        foreach ($e in $exts) {
            $cand = Join-Path -Path $dir -ChildPath ($Name + $e)
            if (-not [System.IO.File]::Exists($cand)) { continue }
            if ($win -or (Test-LcaUnixExecutable -Path $cand)) { return $cand }
        }
    }
    $null
}

function Open-LcaProcess {
    <#
    Starts a process and returns a handle without waiting, so slow queries
    (winget, brew, npm) can run while the PATH scan proceeds. Collect the
    result with Wait-LcaProcess. Never throws: a failed start is recorded on
    the handle.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [AllowEmptyCollection()][string[]]$ArgumentList = @(),
        [string]$WorkingDirectory,
        [hashtable]$Environment
    )
    $handle = [pscustomobject]@{
        PSTypeName   = 'ListCodingAgents.ProcessHandle'
        FilePath     = $FilePath
        ArgumentList = @($ArgumentList)
        Process      = $null
        OutTask      = $null
        ErrTask      = $null
        Error        = $null
        Started      = [System.Diagnostics.Stopwatch]::StartNew()
    }
    try {
        $exe = $FilePath
        if (-not [System.IO.Path]::IsPathRooted($exe)) {
            $found = Find-LcaExecutable -Name $exe
            if (-not $found) { throw "command not found: $FilePath" }
            $exe = $found
        }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $argString = ConvertTo-LcaArgumentString -ArgumentList $ArgumentList
        $ext = [System.IO.Path]::GetExtension($exe).ToLowerInvariant()
        if ((Test-LcaWindows) -and ($ext -eq '.cmd' -or $ext -eq '.bat')) {
            if (-not (Test-LcaSafeBatchArgument -ArgumentList $ArgumentList)) {
                throw "refusing to pass shell metacharacters to batch file $exe"
            }
            $comspec = Get-LcaEnvironmentVariable -Name 'ComSpec'
            if (-not $comspec) { $comspec = 'cmd.exe' }
            $psi.FileName = $comspec
            $psi.Arguments = '/d /s /c "' + (ConvertTo-LcaArgumentString -ArgumentList @($exe)) + ' ' + $argString + '"'
        } elseif ($ext -eq '.ps1') {
            $psi.FileName = Get-LcaPowerShellPath
            $psi.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
                (ConvertTo-LcaArgumentString -ArgumentList @($exe)) + ' ' + $argString
        } else {
            $psi.FileName = $exe
            $psi.Arguments = $argString
        }
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $psi.StandardOutputEncoding = $utf8
        $psi.StandardErrorEncoding = $utf8
        if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
        $psi.EnvironmentVariables['CI'] = '1'
        $psi.EnvironmentVariables['NO_COLOR'] = '1'
        $psi.EnvironmentVariables['TERM'] = 'dumb'
        $psi.EnvironmentVariables['NO_UPDATE_NOTIFIER'] = '1'
        if ($Environment) {
            foreach ($k in $Environment.Keys) { $psi.EnvironmentVariables[[string]$k] = [string]$Environment[$k] }
        }
        $p = [System.Diagnostics.Process]::Start($psi)
        $handle.Process = $p
        # Close stdin so a CLI waiting for input sees EOF. On .NET Framework the
        # stdin writer would emit a UTF-8 BOM on close (Console.InputEncoding),
        # so close the raw stream there instead of the writer.
        try {
            if (Test-LcaDesktopEdition) { $p.StandardInput.BaseStream.Close() } else { $p.StandardInput.Close() }
        } catch { Write-Debug "stdin close failed: $($_.Exception.Message)" }
        $handle.OutTask = $p.StandardOutput.ReadToEndAsync()
        $handle.ErrTask = $p.StandardError.ReadToEndAsync()
    } catch {
        $handle.Error = $_.Exception.Message
        Write-Verbose "process start failed: $FilePath - $($handle.Error)"
    }
    $handle
}

function Stop-LcaProcessTree {
    <# Kills a process this module started, including its children. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Internal: only ever kills a child process this module started, after its timeout.')]
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process)
    try { if ($Process.HasExited) { return } } catch { Write-Debug "HasExited failed: $($_.Exception.Message)" }
    # .NET Core 3.0+ has Kill(bool entireProcessTree); .NET Framework does not.
    $killTree = $Process.GetType().GetMethod('Kill', [type[]]@([bool]))
    if ($killTree) {
        try { [void]$killTree.Invoke($Process, @($true)); return } catch { Write-Debug "Kill(true) failed: $($_.Exception.Message)" }
    }
    if (Test-LcaWindows) {
        try {
            $tk = New-Object System.Diagnostics.ProcessStartInfo
            $tk.FileName = 'taskkill.exe'
            $tk.Arguments = '/PID ' + $Process.Id + ' /T /F'
            $tk.UseShellExecute = $false
            $tk.CreateNoWindow = $true
            $tk.RedirectStandardOutput = $true
            $tk.RedirectStandardError = $true
            $k = [System.Diagnostics.Process]::Start($tk)
            [void]$k.WaitForExit(5000)
            return
        } catch { Write-Debug "taskkill failed: $($_.Exception.Message)" }
    }
    try { $Process.Kill() } catch { Write-Debug "Kill() failed: $($_.Exception.Message)" }
}

function Wait-LcaProcess {
    <#
    Waits for a handle from Open-LcaProcess up to the timeout (measured from
    when it started) and returns
    { ExitCode, StdOut, StdErr, TimedOut, Failed, Error, DurationMs }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]$Handle,
        [double]$TimeoutSec = 30
    )
    $res = [pscustomobject]@{
        PSTypeName = 'ListCodingAgents.ProcessResult'
        FilePath   = $Handle.FilePath
        ExitCode   = $null
        StdOut     = ''
        StdErr     = ''
        TimedOut   = $false
        Failed     = $false
        Error      = $null
        DurationMs = 0
    }
    if ($Handle.Error -or -not $Handle.Process) {
        $res.Failed = $true
        $res.Error = $Handle.Error
        $res.DurationMs = [int]$Handle.Started.ElapsedMilliseconds
        return $res
    }
    $p = $Handle.Process
    try {
        $remaining = [int][Math]::Max(1, ($TimeoutSec * 1000) - $Handle.Started.ElapsedMilliseconds)
        if (-not $p.WaitForExit($remaining)) {
            $res.TimedOut = $true
            $res.Failed = $true
            $res.Error = ('timed out after {0}s' -f $TimeoutSec)
            Stop-LcaProcessTree -Process $p
            [void]$p.WaitForExit(5000)
        }
        # Grandchildren can keep the pipes open after a kill; never wait forever.
        if ($Handle.OutTask -and $Handle.OutTask.Wait(5000)) { $res.StdOut = [string]$Handle.OutTask.Result }
        if ($Handle.ErrTask -and $Handle.ErrTask.Wait(2000)) { $res.StdErr = [string]$Handle.ErrTask.Result }
        if ($p.HasExited) { $res.ExitCode = $p.ExitCode }
        if (-not $res.TimedOut -and $null -ne $res.ExitCode -and $res.ExitCode -ne 0) {
            $res.Failed = $true
            $res.Error = ('exit code {0}' -f $res.ExitCode)
        }
    } catch {
        $res.Failed = $true
        $res.Error = $_.Exception.Message
        Write-Verbose "process wait failed: $($Handle.FilePath) - $($res.Error)"
    } finally {
        try { $p.Dispose() } catch { Write-Debug "dispose failed: $($_.Exception.Message)" }
    }
    $res.DurationMs = [int]$Handle.Started.ElapsedMilliseconds
    $res
}

function Invoke-LcaProcess {
    <# Runs a program to completion (or timeout). See Open-LcaProcess. #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [AllowEmptyCollection()][string[]]$ArgumentList = @(),
        [double]$TimeoutSec = 30,
        [string]$WorkingDirectory,
        [hashtable]$Environment
    )
    $h = Open-LcaProcess -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory -Environment $Environment
    Wait-LcaProcess -Handle $h -TimeoutSec $TimeoutSec
}
# ---- Private/Platform/Registry.ps1 ----
# Provider seam: Windows registry and PE version info. Both switch off
# cleanly on macOS/Linux (they return nothing).

function Get-LcaUninstallEntry {
    <#
    Reads the Windows Uninstall keys (HKCU, HKLM, HKLM WOW6432Node) and returns
    { DisplayName, DisplayVersion, Publisher, InstallLocation, EstimatedSizeKB,
      UninstallString, QuietUninstallString, KeyName, Hive }.
    Returns an empty array on other platforms.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param()
    if (-not (Test-LcaWindows)) { return @() }
    $roots = @(
        @('HKCU', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'),
        @('HKLM', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall'),
        @('HKLM32', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
    )
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($r in $roots) {
        $keys = @()
        try { $keys = @(Get-ChildItem -LiteralPath $r[1] -ErrorAction Stop) } catch {
            Write-Debug "registry read failed: $($r[1]) - $($_.Exception.Message)"
            continue
        }
        foreach ($k in $keys) {
            $p = $null
            try { $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Stop } catch {
                Write-Debug "registry value read failed: $($k.PSPath)"
                continue
            }
            $names = @($p.PSObject.Properties | ForEach-Object { $_.Name })
            if ($names -notcontains 'DisplayName' -or -not $p.DisplayName) { continue }
            $get = {
                param($n)
                if ($names -contains $n) { return $p.$n }
                $null
            }
            $size = & $get 'EstimatedSize'
            $out.Add([pscustomobject]@{
                    DisplayName          = [string]$p.DisplayName
                    DisplayVersion       = [string](& $get 'DisplayVersion')
                    Publisher            = [string](& $get 'Publisher')
                    InstallLocation      = [string](& $get 'InstallLocation')
                    EstimatedSizeKB      = $(if ($null -ne $size) { [long]$size } else { $null })
                    UninstallString      = [string](& $get 'UninstallString')
                    QuietUninstallString = [string](& $get 'QuietUninstallString')
                    KeyName              = [string]$k.PSChildName
                    Hive                 = $r[0]
                })
        }
    }
    $out.ToArray()
}

function Get-LcaFileVersionInfo {
    <#
    Embedded version-info of an executable (CompanyName, ProductName,
    FileDescription, ProductVersion, FileVersion). Only meaningful for
    Windows PE files; returns $null for anything else.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($Path -notmatch '(?i)\.exe$') { return $null }
    try {
        $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        [pscustomobject]@{
            CompanyName     = [string]$vi.CompanyName
            ProductName     = [string]$vi.ProductName
            FileDescription = [string]$vi.FileDescription
            ProductVersion  = [string]$vi.ProductVersion
            FileVersion     = [string]$vi.FileVersion
        }
    } catch {
        Write-Debug "version info failed for ${Path}: $($_.Exception.Message)"
        $null
    }
}
# ---- Private/Report/ConvertTo-LcaReportHtml.ps1 ----
# HTML report assembly. The report is ONE self-contained file: template +
# CSS + JS + fonts (base64 WOFF2) + the scan export embedded as
# <script type="application/json">, rendered client-side with DOM APIs.

function ConvertTo-LcaScriptJson {
    <#
    JSON that is safe inside <script type="application/json">: '<', '>' and
    '&' are escaped (no "</script>" or "<!--" breakout) as are U+2028/2029.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$InputObject)
    $json = ConvertTo-LcaJson -InputObject $InputObject -Compress
    $json.Replace('<', '\u003c').Replace('>', '\u003e').Replace('&', '\u0026').Replace([string][char]0x2028, '\u2028').Replace([string][char]0x2029, '\u2029')
}

function Get-LcaReportFontCss {
    <# @font-face rules with embedded fonts; empty when no fonts are bundled. #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $faces = @(
        @{ Family = 'Syne'; File = 'report/fonts/syne-latin.woff2'; Weight = '600 800' },
        @{ Family = 'JetBrains Mono'; File = 'report/fonts/jetbrains-mono-latin.woff2'; Weight = '400 700' }
    )
    $sb = New-Object System.Text.StringBuilder
    foreach ($f in $faces) {
        if (-not (Test-LcaAsset -Name $f.File -Binary)) { continue }
        $b64 = Get-LcaAsset -Name $f.File -AsBase64
        [void]$sb.Append("@font-face{font-family:'" + $f.Family + "';font-style:normal;font-weight:" + $f.Weight +
            ";font-display:swap;src:url(data:font/woff2;base64," + $b64 + ") format('woff2')}`n")
    }
    $sb.ToString()
}

function ConvertTo-LcaReportHtml {
    <# Builds the report from an export (ConvertTo-LcaExport). #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)]$Export)
    $template = Get-LcaAsset -Name 'report/template.html'
    $css = Get-LcaAsset -Name 'report/report.css'
    $js = Get-LcaAsset -Name 'report/report.js'
    $fonts = Get-LcaReportFontCss
    $data = ConvertTo-LcaScriptJson -InputObject $Export
    # Plain string replacement (no regex) - data never passes through a
    # replacement-pattern parser. DATA goes last so its content can't be
    # mistaken for another placeholder.
    $html = $template.Replace('/*{{FONTS}}*/', $fonts).Replace('/*{{CSS}}*/', $css).Replace('/*{{JS}}*/', $js)
    $html.Replace('{{DATA}}', $data)
}
# ---- Private/State/Config.ps1 ----
# Optional config.json in the config directory:
#   { "staleDays": 60, "probeTimeoutSec": 8, "parallelism": 4,
#     "defaults": { "IncludeEditors": true, "SkipWinget": false, ... } }

$script:LcaConfigDefaultSwitches = @(
    'IncludeEditors', 'IncludeExtensions', 'All', 'SkipWinget', 'CheckUpdates', 'NoProbe', 'NoHtml', 'NoOpen',
    'Json', 'ShowReasons', 'Quiet', 'NoColor', 'Redact'
)

function Get-LcaConfig {
    <#
    Returns { StaleDays, ProbeTimeoutSec, Parallelism, Defaults (hashtable of
    switch name -> bool), Path }. Invalid values are ignored with a warning
    diagnostic; a missing file means defaults.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)]$Context)
    $cfg = [pscustomobject]@{ StaleDays = 60; ProbeTimeoutSec = 8; Parallelism = $null; Defaults = @{}; Path = $null }
    if (-not $Context.ConfigDir) { return $cfg }
    $p = Join-Path -Path $Context.ConfigDir -ChildPath 'config.json'
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $cfg }
    $cfg.Path = $p
    $j = $null
    try { $j = ConvertFrom-LcaJson -Text (Read-LcaTextFile -Path $p) } catch {
        Add-LcaDiagnostic -Source 'config' -Message "config.json is not valid JSON, using defaults ($p)" -ErrorRecord $_ -NoExceptionText
        return $cfg
    }
    $num = {
        param($name, $min, $max)
        $v = Get-LcaProperty -InputObject $j -Name $name
        if ($null -eq $v) { return $null }
        $d = 0.0
        if (-not [double]::TryParse([string]$v, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d) -or $d -lt $min -or $d -gt $max) {
            Add-LcaDiagnostic -Source 'config' -Message ("config.json: {0} must be a number between {1} and {2}; ignored" -f $name, $min, $max)
            return $null
        }
        $d
    }
    $v = & $num 'staleDays' 1 3650; if ($null -ne $v) { $cfg.StaleDays = [int]$v }
    $v = & $num 'probeTimeoutSec' 1 120; if ($null -ne $v) { $cfg.ProbeTimeoutSec = [double]$v }
    $v = & $num 'parallelism' 1 32; if ($null -ne $v) { $cfg.Parallelism = [int]$v }
    $defs = Get-LcaProperty -InputObject $j -Name 'defaults'
    if ($defs) {
        foreach ($prop in $defs.PSObject.Properties) {
            $match = $script:LcaConfigDefaultSwitches | Where-Object { $_ -eq $prop.Name }
            if (-not $match -or $prop.Value -isnot [bool]) {
                Add-LcaDiagnostic -Source 'config' -Message ("config.json: defaults.{0} is not a known switch with a true/false value; ignored" -f $prop.Name)
                continue
            }
            $cfg.Defaults[[string]$match] = [bool]$prop.Value
        }
    }
    $cfg
}
# ---- Private/State/NameList.ps1 ----
# agents-extra.txt / agents-exclude.txt: one command name per line, '#'
# comments. Read from next to the script (v1) and from the config directory.

function Get-LcaNameList {
    <# Union of the named list file in ScriptRoot and ConfigDir, lowercased. #>
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.HashSet[string]])]
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)][string]$FileName)
    $set = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    $dirs = @()
    if ($Context.ScriptRoot) { $dirs += $Context.ScriptRoot }
    if ($Context.ConfigDir) { $dirs += $Context.ConfigDir }
    foreach ($d in $dirs) {
        $p = Join-Path -Path $d -ChildPath $FileName
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        try {
            foreach ($raw in ((Read-LcaTextFile -Path $p) -split "`r?`n")) {
                $line = $raw.Trim()
                if ($line -and $line -notmatch '^\s*#') { [void]$set.Add($line.ToLowerInvariant()) }
            }
        } catch {
            Add-LcaDiagnostic -Source 'config' -Message "cannot read $p" -ErrorRecord $_
        }
    }
    # leading comma stops PowerShell unrolling the HashSet into loose strings -
    # without it an empty set comes back as $null and .Contains() blows up
    , $set
}
# ---- Private/State/Paths.ps1 ----
# Where state and config live.

function Get-LcaStateDirectory {
    <#
    Windows %LOCALAPPDATA%\list-coding-agents, macOS
    ~/Library/Application Support/list-coding-agents, Linux
    ${XDG_STATE_HOME:-~/.local/state}/list-coding-agents.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $base = $null
    switch (Get-LcaPlatform) {
        'windows' {
            $base = Get-LcaKnownFolder -Name 'LocalAppData'
            if (-not $base) {
                $h = Get-LcaKnownFolder -Name 'Home'
                if ($h) { $base = Join-Path -Path (Join-Path -Path $h -ChildPath 'AppData') -ChildPath 'Local' }
            }
        }
        'macos' { $base = Get-LcaKnownFolder -Name 'AppSupport' }
        default { $base = Get-LcaKnownFolder -Name 'XdgStateHome' }
    }
    if (-not $base) { return $null }
    Join-Path -Path $base -ChildPath 'list-coding-agents'
}

function Get-LcaConfigDirectory {
    <#
    Windows %APPDATA%\list-coding-agents, macOS
    ~/Library/Application Support/list-coding-agents, Linux
    ${XDG_CONFIG_HOME:-~/.config}/list-coding-agents.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $base = $null
    switch (Get-LcaPlatform) {
        'windows' {
            $base = Get-LcaKnownFolder -Name 'AppData'
            if (-not $base) {
                $h = Get-LcaKnownFolder -Name 'Home'
                if ($h) { $base = Join-Path -Path (Join-Path -Path $h -ChildPath 'AppData') -ChildPath 'Roaming' }
            }
        }
        'macos' { $base = Get-LcaKnownFolder -Name 'AppSupport' }
        default { $base = Get-LcaKnownFolder -Name 'XdgConfigHome' }
    }
    if (-not $base) { return $null }
    Join-Path -Path $base -ChildPath 'list-coding-agents'
}
# ---- Private/State/StateFile.ps1 ----
# Scan state (last-scan.json): previous names, trend history, probe cache.
# Ported from v1, which kept the file next to the script. Workstream D moves
# it to the state directory, adds migration, schemaVersion and corruption
# handling.

function Get-LcaStateFilePath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)]$Context)
    if (-not $Context.ScriptRoot) { return $null }
    Join-Path -Path $Context.ScriptRoot -ChildPath 'last-scan.json'
}

function Read-LcaState {
    <#
    Returns { Path, Exists, Date, Agents, WingetOnly, HasWingetKey, History,
    Probes }. A missing or unreadable file yields an empty state.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)]$Context)
    $st = [pscustomobject]@{
        Path = (Get-LcaStateFilePath -Context $Context); Exists = $false; Date = ''
        Agents = @(); WingetOnly = @(); HasWingetKey = $false; History = @(); Probes = @{}
    }
    if (-not $st.Path -or -not (Test-Path -LiteralPath $st.Path -PathType Leaf)) { return $st }
    try {
        $prev = ConvertFrom-LcaJson -Text (Read-LcaTextFile -Path $st.Path)
        $st.Exists = $true
        $v = Get-LcaProperty -InputObject $prev -Name 'agents'; if ($v) { $st.Agents = @($v) }
        $v = Get-LcaProperty -InputObject $prev -Name 'date'; if ($v) { $st.Date = "$v" }
        $v = Get-LcaProperty -InputObject $prev -Name 'history'; if ($v) { $st.History = @($v) }
        $v = Get-LcaProperty -InputObject $prev -Name 'probes'
        if ($v) { foreach ($pp in $v.PSObject.Properties) { $st.Probes[$pp.Name] = $pp.Value } }
        # Agents only the winget scan can see. Tracked separately so a scan that
        # skipped winget knows which previous names it simply didn't look for.
        if ($prev.PSObject.Properties['wingetOnly']) {
            $st.HasWingetKey = $true
            $v = Get-LcaProperty -InputObject $prev -Name 'wingetOnly'
            if ($v) { $st.WingetOnly = @($v) }
        }
    } catch {
        Add-LcaDiagnostic -Source 'state' -Message "cannot read state file $($st.Path)" -ErrorRecord $_ -NoExceptionText
    }
    $st
}

function Get-LcaHistoryChange {
    <#
    Diffs the current scan against the previous state (v1 semantics) and
    prepares what Save-LcaState persists. Returns
    { PreviousDate, New, Gone, Unscanned, PersistNames, WingetOnly,
      WriteState, History }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$State,
        [AllowEmptyCollection()][object[]]$Agent = @(),
        [double]$TotalMB = 0
    )
    $inScope = @(Select-LcaAgentInScope -Context $Context -Agent $Agent -Tier 'detected')
    $curNames = @($inScope | ForEach-Object { $_.Name })
    $wingetScanned = [bool]$Context.Data['wingetScanned']
    # Without a winget scan, previous winget-only agents are "not checked", not
    # "gone" - reporting them as removed is a lie about state we never observed.
    $unscanned = @()
    if (-not $wingetScanned) { $unscanned = @($State.WingetOnly) }
    $new = @(); $gone = @()
    if ($State.Agents.Count) {
        $new = @($curNames | Where-Object { $State.Agents -notcontains $_ })
        $gone = @($State.Agents | Where-Object { $curNames -notcontains $_ -and $unscanned -notcontains $_ })
    }

    # A run without a winget scan is a PARTIAL scan. Writing its short agent
    # list as the new baseline would make the next full scan report every
    # winget-only agent as "+ new" (and this run report them as "- gone"). So
    # carry the previous winget-only names forward and skip the trend point,
    # whose count/size would be understated and show up as a phantom dip.
    $wingetOnly = @($inScope | Where-Object { -not $_.Command -and $_.Channel -eq 'winget' } | ForEach-Object { $_.Name })
    $persist = $curNames
    $write = $true
    $hist = @($State.History)
    if (-not $wingetScanned) {
        if ($State.Agents.Count -and -not $State.HasWingetKey) {
            # Pre-upgrade state file: no way to tell which previous names were
            # winget-only, so leave the baseline alone rather than corrupt it.
            $write = $false
        } else {
            $wingetOnly = @($State.WingetOnly)
            $persist = @(@($curNames) + @($State.WingetOnly) | Select-Object -Unique)
        }
    } else {
        $entry = [pscustomobject]@{
            d  = $Context.Now.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
            c  = $inScope.Count
            mb = [math]::Round($TotalMB, 1)
        }
        if ($hist.Count -and "$($hist[$hist.Count - 1].d)" -eq $entry.d) { $hist[$hist.Count - 1] = $entry }
        else { $hist = @($hist) + @($entry) }
        if ($hist.Count -gt 60) { $hist = @($hist[($hist.Count - 60)..($hist.Count - 1)]) }
    }
    foreach ($a in $Agent) { if ($new -contains $a.Name) { $a.IsNew = $true } }
    [pscustomobject]@{
        PreviousDate = $State.Date
        New          = $new
        Gone         = $gone
        Unscanned    = $unscanned
        VersionChanges = @()
        PersistNames = $persist
        WingetOnly   = $wingetOnly
        WriteState   = $write
        History      = $hist
    }
}

function Save-LcaState {
    <# Persists names, winget-only names, history and the probe cache. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)]$Scan)
    $path = Get-LcaStateFilePath -Context $Context
    if (-not $path -or -not $Scan.Changes.WriteState) { return }
    try {
        $obj = [ordered]@{
            date       = $Context.Now.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
            agents     = @($Scan.Changes.PersistNames)
            wingetOnly = @($Scan.Changes.WingetOnly)
            history    = @($Scan.Changes.History)
            probes     = $Context.ProbeCache
        }
        Write-LcaTextFile -Path $path -Content (ConvertTo-LcaJson -InputObject $obj)
    } catch {
        Add-LcaDiagnostic -Source 'state' -Message "cannot write state file $path" -ErrorRecord $_
    }
}
# ---- Private/Updates/Add-LcaUpdateInfo.ps1 ----
# Update / uninstall information (ported from v1). Workstream C replaces the
# string version compare, the second winget call and the uninstall rules.

function Add-LcaUninstallInfo {
    <# v1 rules, expressed as argument arrays instead of re-parsed strings. #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Agent = @())
    foreach ($r in @($Agent)) {
        if ($r.Tier -eq 'excluded') { continue }
        if ($r.Channel -eq 'npm' -and $r.Package) {
            $r.UninstallCommand = New-LcaCommand -Exe 'npm' -Arguments @('rm', '-g', $r.Package)
        } elseif ($r.Channel -eq 'winget' -and -not $r.Command) {
            $r.UninstallCommand = New-LcaCommand -Exe 'winget' -Arguments @('uninstall', '--id', $r.Source)
        } elseif ($r.Channel -eq 'winget') {
            $r.UninstallCommand = New-LcaCommand -Exe 'winget' -Arguments @('uninstall', $r.Name)
        } elseif ($r.Source -match '(?i)\.(exe|cmd|bat|ps1)$') {
            $r.UninstallCommand = New-LcaCommand -Exe 'Remove-Item' -Arguments @($r.Source)
        }
    }
}

function Add-LcaUpdateInfo {
    <#
    Sets UninstallCommand on every row and, with Options.CheckUpdates, Latest /
    UpdateCommand / UpdateStatus from npm and winget.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [AllowEmptyCollection()][object[]]$Agent = @()
    )
    Add-LcaUninstallInfo -Agent $Agent
    if (-not $Context.Options.CheckUpdates) { return }
    $detected = @($Agent | Where-Object { $_.Tier -eq 'detected' })
    $npm = Find-LcaExecutable -Name 'npm'
    if ($npm) {
        $r = Invoke-LcaProcess -FilePath $npm -ArgumentList @('outdated', '-g', '--json') -TimeoutSec 60
        # npm outdated exits 1 when something is outdated; the JSON is still valid
        $raw = $r.StdOut.Trim()
        if ($raw) {
            try {
                $out = ConvertFrom-LcaJson -Text $raw
                foreach ($p in $out.PSObject.Properties) {
                    $latest = Get-LcaProperty -InputObject $p.Value -Name 'latest'
                    foreach ($a in $detected) {
                        if ($a.Package -eq $p.Name -and $latest -and $latest -ne $a.Version) {
                            $a.Latest = [string]$latest
                            $a.UpdateCommand = New-LcaCommand -Exe 'npm' -Arguments @('i', '-g', ($a.Package + '@latest'))
                            $a.UpdateStatus = 'outdated'
                            $a.UpdateReason = $null
                        }
                    }
                }
            } catch {
                Add-LcaDiagnostic -Source 'npm' -Message 'npm outdated returned unreadable JSON' -ErrorRecord $_ -NoExceptionText
            }
        }
    }
    $winget = Find-LcaExecutable -Name 'winget'
    if ($winget) {
        $r = Invoke-LcaProcess -FilePath $winget -ArgumentList @('upgrade', '--disable-interactivity') -TimeoutSec 120
        $wg = @{}
        foreach ($line in ($r.StdOut -split "`r?`n")) {
            if ($line -notmatch '[A-Za-z]') { continue }
            $parts = $line -split '\s{2,}'
            if ($parts.Count -ge 4 -and $parts[1].Trim() -match '\.' -and $parts[1].Trim() -ne 'Id') {
                $wg[$parts[1].Trim()] = $parts[3].Trim()
            }
        }
        foreach ($a in @($detected | Where-Object { $_.Channel -eq 'winget' -and -not $_.Latest })) {
            foreach ($k in $wg.Keys) {
                if ($a.Source -match [regex]::Escape($k) -or $k -match [regex]::Escape($a.Name)) {
                    $a.Latest = $wg[$k]
                    $a.UpdateCommand = New-LcaCommand -Exe 'winget' -Arguments @('upgrade', '--id', $k)
                    $a.UpdateStatus = 'outdated'
                    $a.UpdateReason = $null
                    break
                }
            }
        }
    }
}
# ---- Private/Updates/FailOn.ps1 ----
# -FailOn outdated,stale,conflict,new for CI. Workstream C owns this.

function Test-LcaFailOn {
    <#
    Returns the -FailOn conditions that are present in the scan (display
    scope), e.g. @('outdated', 'new'). Empty when none matched.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Scan,
        [AllowEmptyCollection()][string[]]$FailOn = @()
    )
    $inScope = @(Select-LcaAgentInScope -Context $Context -Agent $Scan.Agents -Tier 'detected')
    $hit = New-Object System.Collections.Generic.List[string]
    foreach ($c in @($FailOn)) {
        $match = switch ($c) {
            'outdated' { @($inScope | Where-Object { $_.UpdateStatus -eq 'outdated' }).Count -gt 0 }
            'stale' { @($inScope | Where-Object { $_.Usage -eq 'stale' }).Count -gt 0 }
            'conflict' { @($inScope | Where-Object { @($_.Shadows).Count -gt 0 }).Count -gt 0 }
            'new' { @($Scan.Changes.New).Count -gt 0 }
            default { $false }
        }
        if ($match -and -not $hit.Contains($c)) { $hit.Add($c) }
    }
    $hit.ToArray()
}
# ---- Private/Updates/UpdateAll.ps1 ----
# -UpdateAll from the CLI. Workstream C owns this.

function Invoke-LcaUpdateAll {
    <#
    Updates every outdated DETECTED agent in display scope through
    Update-CodingAgent (ShouldProcess: -DryRun maps to -WhatIf, -AskConfirm to -Confirm).
    Returns the ListCodingAgents.UpdateResult objects.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Scan,
        [switch]$Force,
        [switch]$DryRun,
        [switch]$AskConfirm
    )
    $outdated = @(Select-LcaAgentInScope -Context $Context -Agent $Scan.Agents -Tier 'detected' | Where-Object { $_.UpdateStatus -eq 'outdated' })
    if (-not $outdated.Count) { return @() }
    @($outdated | Update-CodingAgent -Force:$Force -WhatIf:$DryRun -Confirm:$AskConfirm -PassThru)
}
# ---- Public/Export-CodingAgentReport.ps1 ----
function Export-CodingAgentReport {
    <#
    .SYNOPSIS
        Writes the HTML report and/or the JSON export for a scan.

    .DESCRIPTION
        Takes a scan from Get-CodingAgent -AsScan (or runs one) and writes
        coding-agents.html (self-contained, no network requests) and/or
        coding-agents.json (schema/coding-agents.schema.json) to -OutDir.

    .PARAMETER Scan
        A ListCodingAgents.Scan from Get-CodingAgent -AsScan. When omitted a
        new scan runs.

    .PARAMETER OutDir
        Output folder. Defaults to the current directory.

    .PARAMETER Format
        html, json or both. Default: html.

    .PARAMETER Redact
        Strip the user name and host name from the files (for sharing).

    .PARAMETER Open
        Open the HTML report afterwards.

    .PARAMETER PassThru
        Emit the written files as FileInfo objects.

    .EXAMPLE
        Get-CodingAgent -AsScan -All | Export-CodingAgentReport -Format html, json -OutDir ./out
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(ValueFromPipeline = $true)]$Scan,
        [string]$OutDir,
        [ValidateSet('html', 'json')][string[]]$Format = @('html'),
        [switch]$Redact,
        [switch]$Open,
        [switch]$PassThru
    )
    process {
        if (-not $Scan) { $Scan = Get-CodingAgent -AsScan }
        $ctx = Get-LcaProperty -InputObject $Scan -Name 'Context'
        if (-not $ctx) { throw 'Export-CodingAgentReport: pass a scan from Get-CodingAgent -AsScan' }
        if (-not $OutDir) { $OutDir = (Get-Location).ProviderPath }
        $export = ConvertTo-LcaExport -Scan $Scan -Context $ctx -Redact:$Redact
        foreach ($f in $Format) {
            if ($f -eq 'json') {
                $p = Join-Path -Path $OutDir -ChildPath 'coding-agents.json'
                Write-LcaTextFile -Path $p -Content ((ConvertTo-LcaJson -InputObject $export) + "`n")
            } else {
                $p = Join-Path -Path $OutDir -ChildPath 'coding-agents.html'
                Write-LcaTextFile -Path $p -Content (ConvertTo-LcaReportHtml -Export $export)
                if ($Open) { Open-LcaReport -Path $p }
            }
            if ($PassThru) { Get-Item -LiteralPath $p }
        }
    }
}
# ---- Public/Get-CodingAgent.ps1 ----
function Get-CodingAgent {
    <#
    .SYNOPSIS
        Finds the AI coding agents installed on this machine.

    .DESCRIPTION
        Scans PATH, package managers (npm, pnpm, bun, pipx, uv, pip, cargo,
        Homebrew, scoop, choco), winget, the Windows Uninstall registry and
        editor extension folders, scores every candidate against a catalog of
        known agents plus heuristics, and emits one ListCodingAgents.Agent
        object per agent with its version, install footprint, usage and update
        information.

        Get-CodingAgent does not write anything unless -UpdateState is used.

    .PARAMETER Name
        Only return agents whose name, id or command matches one of these
        wildcard patterns.

    .PARAMETER IncludeEditors
        Also return GUI AI editors (Cursor, Windsurf, Kiro, Zed ...).

    .PARAMETER IncludeExtensions
        Also return AI coding extensions installed in VS Code-family editors.

    .PARAMETER All
        Same as -IncludeEditors -IncludeExtensions.

    .PARAMETER IncludePossible
        Also return low-confidence candidates (tier "possible").

    .PARAMETER SkipWinget
        Skip the winget package scan.

    .PARAMETER CheckUpdates
        Ask each package manager whether a newer version exists.

    .PARAMETER NoProbe
        Do not run "<agent> --version" to discover versions.

    .PARAMETER AsScan
        Return the whole scan (agents, history, fleet health, diagnostics)
        as one ListCodingAgents.Scan object instead of agent objects.

    .PARAMETER UpdateState
        Record this scan in the state directory (history, probe cache), as
        the list-coding-agents.ps1 script does.

    .EXAMPLE
        Get-CodingAgent

    .EXAMPLE
        Get-CodingAgent -CheckUpdates | Where-Object UpdateStatus -eq 'outdated'

    .OUTPUTS
        ListCodingAgents.Agent, or ListCodingAgents.Scan with -AsScan.
    #>
    [CmdletBinding()]
    [OutputType('ListCodingAgents.Agent', 'ListCodingAgents.Scan')]
    param(
        [Parameter(Position = 0)][SupportsWildcards()][string[]]$Name,
        [switch]$IncludeEditors,
        [switch]$IncludeExtensions,
        [switch]$All,
        [switch]$IncludePossible,
        [switch]$SkipWinget,
        [switch]$CheckUpdates,
        [switch]$NoProbe,
        [switch]$AsScan,
        [switch]$UpdateState
    )
    $ctx = New-LcaContext -Options @{
        IncludeEditors = $IncludeEditors; IncludeExtensions = $IncludeExtensions; All = $All
        SkipWinget = $SkipWinget; CheckUpdates = $CheckUpdates; NoProbe = $NoProbe
    }
    $scan = Invoke-LcaScan -Context $ctx
    if ($UpdateState) { Save-LcaState -Context $ctx -Scan $scan }
    if ($AsScan) {
        $scan | Add-Member -NotePropertyName 'Context' -NotePropertyValue $ctx -Force
        return $scan
    }
    $tier = 'detected'
    if ($IncludePossible) { $tier = 'any' }
    foreach ($a in @(Select-LcaAgentInScope -Context $ctx -Agent $scan.Agents -Tier $tier)) {
        if ($Name) {
            $hit = $false
            foreach ($n in $Name) {
                if ($a.Name -like $n -or $a.Id -like $n -or ($a.Command -and $a.Command -like $n)) { $hit = $true; break }
            }
            if (-not $hit) { continue }
        }
        $a
    }
}
# ---- Public/Update-CodingAgent.ps1 ----
function Update-CodingAgent {
    <#
    .SYNOPSIS
        Updates outdated AI coding agents through their own package manager.

    .DESCRIPTION
        Runs each agent's update command (an executable plus an argument array;
        nothing is re-parsed by a shell) after ShouldProcess confirmation,
        checks the exit code, then re-reads the version and prints
        "before -> after".

        Without -InputObject, runs Get-CodingAgent -CheckUpdates and updates
        every outdated agent (or the ones matching -Name).

    .PARAMETER Name
        Only update agents whose name, id or command matches these patterns.

    .PARAMETER InputObject
        Agent objects from Get-CodingAgent -CheckUpdates.

    .PARAMETER Force
        Do not ask for confirmation (for non-interactive runs). -WhatIf still
        wins.

    .PARAMETER PassThru
        Emit one result object per agent: { Name, Before, After, Status, ExitCode, Command }.

    .EXAMPLE
        Update-CodingAgent -WhatIf

    .EXAMPLE
        Get-CodingAgent -CheckUpdates -Name claude | Update-CodingAgent -Force
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium', DefaultParameterSetName = 'Name')]
    [OutputType('ListCodingAgents.UpdateResult')]
    param(
        [Parameter(ParameterSetName = 'Name', Position = 0)][SupportsWildcards()][string[]]$Name,
        [Parameter(ParameterSetName = 'InputObject', Mandatory = $true, ValueFromPipeline = $true)][psobject[]]$InputObject,
        [switch]$Force,
        [switch]$PassThru
    )
    begin {
        $queue = New-Object System.Collections.Generic.List[object]
    }
    process {
        if ($PSCmdlet.ParameterSetName -eq 'InputObject') { foreach ($i in $InputObject) { $queue.Add($i) } }
    }
    end {
        if ($PSCmdlet.ParameterSetName -eq 'Name') {
            foreach ($a in @(Get-CodingAgent -Name $Name -CheckUpdates -All)) { $queue.Add($a) }
        }
        $todo = @($queue | Where-Object { $_.UpdateStatus -eq 'outdated' -and $_.UpdateCommand })
        foreach ($a in $todo) {
            $cmd = $a.UpdateCommand
            $target = '{0} {1} -> {2}' -f $a.Name, $a.Version, $a.Latest
            $result = [pscustomobject]@{
                PSTypeName = 'ListCodingAgents.UpdateResult'
                Name = $a.Name; Before = $a.Version; After = $null; Status = 'skipped'; ExitCode = $null; Command = $cmd.Display
            }
            if ($PSCmdlet.ShouldProcess($target, $cmd.Display) -and ($Force -or $PSCmdlet.ShouldContinue($cmd.Display, "Update $($a.Name)?"))) {
                $r = Invoke-LcaProcess -FilePath $cmd.Exe -ArgumentList $cmd.Arguments -TimeoutSec 900
                $result.ExitCode = $r.ExitCode
                if ($r.Failed) {
                    $result.Status = 'failed'
                    Write-Warning ('{0}: update failed ({1})' -f $a.Name, $r.Error)
                } else {
                    $result.Status = 'updated'
                    $result.After = $a.Latest
                }
                Write-Verbose ('{0}: {1} -> {2} [{3}]' -f $a.Name, $result.Before, $result.After, $result.Status)
            }
            if ($PassThru) { $result }
        }
    }
}
Export-ModuleMember -Function @()
}
#endregion LCA-MODULE

$lcaBound = @{}
foreach ($lcaKey in $PSBoundParameters.Keys) { $lcaBound[$lcaKey] = $PSBoundParameters[$lcaKey] }
if ($WhatIfPreference -and -not $lcaBound.ContainsKey('WhatIf')) { $lcaBound['WhatIf'] = [switch]$true }
& $lcaModule { param($b, $r) Invoke-LcaCli -BoundParameters $b -ScriptRoot $r } $lcaBound $PSScriptRoot
$lcaExit = & $lcaModule { $script:LcaLastExitCode }
# Under "irm ... | iex" there is no script file: never call exit there, it
# would close the user's shell.
if ($PSCommandPath -and $lcaExit -ne 0) { exit $lcaExit }
