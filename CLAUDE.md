# list-coding-agents - maintainer notes

PowerShell tool that finds the AI coding agents installed on a machine. Ships two ways:

- `list-coding-agents.ps1` at the repo root: a single self-contained script. It is **generated** by `build.ps1`; never edit it by hand.
- the `ListCodingAgents` module in `src/ListCodingAgents/` (PowerShell Gallery), with `Get-CodingAgent`, `Update-CodingAgent` and `Export-CodingAgentReport`.

## Commands

```powershell
pwsh -NoProfile -File ./build.ps1                    # build the bundle (deterministic)
pwsh -NoProfile -File ./build.ps1 -Task Lint         # PSScriptAnalyzer: src/, build.ps1, bundle; must be 0 findings
pwsh -NoProfile -File ./build.ps1 -Task Test         # Pester (tests/)
pwsh -NoProfile -File ./build.ps1 -Task All -Coverage  # build + lint + tests + 80% line coverage gate
git diff --exit-code -- list-coding-agents.ps1       # CI fails if the committed bundle is stale
```

Run one test file: `pwsh -NoProfile -c "Invoke-Pester -Path ./tests/Core/Core.Tests.ps1 -Output Detailed"`.
Report tests (Playwright + axe): `cd tests/report && npm ci && npm test` (uses the preinstalled Chromium when `PLAYWRIGHT_BROWSERS_PATH` is set).

Toolchain: PowerShell 7.4+ and Windows PowerShell 5.1; Pester 6.2.0; PSScriptAnalyzer 1.25.0.

## Architecture

```
src/list-coding-agents.ps1     entry script: comment-based help + param block; region LCA-MODULE is replaced by the inlined module
src/ListCodingAgents/
  ListCodingAgents.psd1/.psm1  manifest / loader (dot-sources Private/** then Public/*, ordinal path order = build order)
  Public/                      one cmdlet per file
  Private/Platform/            PROVIDER SEAM - the only code that touches the outside world
  Private/Core/                model, context, diagnostics, file IO, JSON export, scan orchestrator, fleet health
  Private/Detection/           catalog + heuristic scorer, PATH / npm / winget / ... sources  -> Find-LcaAgent
  Private/Enrichment/          sizes, usage intel, MCP, version probes                        -> Add-LcaEnrichment
  Private/Updates/             outdated checks, version compare, update/uninstall commands    -> Add-LcaUpdateInfo
  Private/State/               state dir, last-scan.json, history, config.json, override lists
  Private/Console/             CLI (Invoke-LcaCli) and terminal renderer
  Private/Report/              HTML assembly (template + CSS + JS + fonts + embedded JSON)
  data/catalog.json            known agents + the ONE scoring table (weights, thresholds, lexicons)
  report/                      template.html, report.css, report.js, fonts/*.woff2 (+ OFL license)
schema/coding-agents.schema.json   the JSON export contract (coding-agents.json, -Format json, report data)
tests/                         Pester; tests/Helpers/Fixture.psm1 builds fake machines; tests/fixtures/v1 = frozen v1
```

Scan flow (`Invoke-LcaScan`): `Read-LcaState` -> `Find-LcaAgent` -> `Add-LcaEnrichment` -> `Add-LcaUpdateInfo` -> `Get-LcaFleetHealth` -> `Get-LcaHistoryChange`. The CLI then renders the console report, runs updates, saves state and writes the JSON/HTML from **one** export object (`ConvertTo-LcaExport`).

## Rules

### Windows PowerShell 5.1

Every file must run on 5.1 and 7.4+. Banned (enforced by `tests/Compat/Syntax51.Tests.ps1` and the analyzer): `??`, `??=`, `?.`, `?[]`, ternary `a ? b : c`, `&&`/`||`, `ForEach-Object -Parallel`, `ConvertFrom-Json -AsHashtable/-Depth`, `ConvertTo-Json -AsArray`, `Join-Path` with more than one child, `clean {}`, `$IsWindows/$IsLinux/$IsMacOS` (use `Get-LcaPlatform`), `utf8NoBOM`, `ProcessStartInfo.ArgumentList`, `Process.Kill($true)`, `[IO.Path]::GetRelativePath`.
Other traps: `ConvertTo-Json` turns `DateTime` into `"\/Date(..)\/"` on 5.1 (serialize dates as strings via `ConvertTo-LcaIsoString`); `'[..]' | ConvertFrom-Json` emits one object on 5.1 (use `ConvertFrom-LcaJson`); `Out-File -Encoding utf8` writes a BOM on 5.1 (use `Write-LcaTextFile`); `'a::b'.Split('::')` splits on each char on 5.1.

### Source files are ASCII

5.1 reads BOM-less files as ANSI. Emit glyphs with `[char]0x2713`, JSON escapes, CSS escapes. The build fails on any non-ASCII byte. Beware: some editors and AI file-writing tools silently turn backslash-u escape text (`\u003c`) into the literal character. Build such strings by concatenation (`'\' + 'u003c'` in PowerShell, `String.fromCharCode(0x2713)` in JS) and check with `grep -nP '[^\x00-\x7F]'`.

### StrictMode and PowerShell gotchas

- `Set-StrictMode -Version Latest` is on inside the module: reading a missing property throws. Use `Get-LcaProperty` for parsed JSON.
- Variable names are case-insensitive: `$name = ''` overwrites a `$Name` parameter.
- Return collections by emitting items (no leading comma) and wrap call sites in `@(...)`. Only return `, $set` for objects that must not be enumerated (HashSet).
- Pester 6: a `Mock` with only `-ParameterFilter` throws when no filter matches - add a default mock. `-Skip:` conditions run at discovery: set flags in `BeforeDiscovery`.
- `ConvertFrom-Json` on pwsh 7.0-7.4 turns ISO date strings into `[DateTime]` (offset lost); `ConvertFrom-LcaJson` uses `-DateKind String` where available. Never stringify a parsed date with `"$v"` (culture-dependent): use `ConvertTo-LcaIsoString`.
- Never call `Write-Error` in CLI paths without `-ErrorAction Continue`: a caller's `$ErrorActionPreference = 'Stop'` would turn it into an exception and lose the exit code.
- Relative user paths: resolve with `$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath()` (.NET resolves against the process directory, not `$PWD`). `Write-LcaTextFile` does this.
- No `ValidateSet` on the entry script's parameters: under `irm | iex` it rejects the empty defaults and aborts. Validate inside (exit code 2).

### Provider seam

Only `Private/Platform/` may read `$env:`, call `Get-Date`/`[DateTime]::Now`, start processes, read the registry, touch the network or call `npm`/`winget`/... Everything else uses `Get-LcaEnvironmentVariable`, `Get-LcaKnownFolder`, `Get-LcaPathEntry`, `Get-LcaNow`, `Invoke-LcaProcess`/`Open-LcaProcess`+`Wait-LcaProcess` (`-Encoding` for tools that don't print UTF-8), `Find-LcaExecutable`, `Split-LcaCommandLine` (registry UninstallString -> exe + args), `Open-LcaFile`, `Get-LcaUninstallEntry`, `Get-LcaFileVersionInfo`, `Invoke-LcaHttpJson` (opt-in update checks only), `Get-LcaWinGetModulePackage` (Microsoft.WinGet.Client), `Invoke-LcaParallel` (RunspacePool; returns `{ Input, Output (array), Error, TimedOut }` per item, copies module functions + `Lca*` variables, merges diagnostics). Enforced by the AST guard in `tests/Compat/Syntax51.Tests.ps1`.
Tests run the real code against fixture machines: `New-LcaFixture`, `Add-LcaFixtureNpmPackage`, `New-LcaFixtureCommand`, `Set-LcaShimResponse` (fake package managers that log their arguments), `Use-LcaFixture` (in-process) and `Invoke-LcaFixtureScript` (child process; `-AsScriptBlock` simulates `irm | iex`). `LCA_FAKE_NOW` pins the clock.

### Never touch the real toolchain

No real `npm i -g`, `winget upgrade`, uninstalls, etc. - not in tests, not while developing. Updaters are tested against shims that record arguments.

### Secrets

Auth detection is presence-only (file names and JSON key names). Secret values must never reach stdout, JSON, HTML, state, diagnostics or logs. MCP output is server names + transport only - never `env`, `args`, `headers`, URLs or other config values. Diagnostics pass through `Protect-LcaText`; use `Add-LcaDiagnostic -NoExceptionText` when an exception could quote a config file. Fixtures use obvious fakes (`sk-ant-FAKE-0000`, `ghp_FAKE0000`) and tests assert they never appear in any output. Never print or copy real config/credential files (`~/.claude.json`, `~/.codex/auth.json`, ...).

### Errors

No empty `catch {}`: record with `Add-LcaDiagnostic` (exported in the JSON `diagnostics` array) or at least `Write-Debug`.

### Analyzer

0 errors, 0 warnings. A suppression needs a `Justification` (e.g. `PSAvoidUsingWriteHost` only in `Write-LcaConsoleLine`; constructors `New-Lca*` suppress `PSUseShouldProcessForStateChangingFunctions`).

## Contracts (frozen in Phase 1 of the v2 upgrade)

- **Agent object** (`New-LcaAgent`, `Private/Core/Model.ps1`): PSTypeName `ListCodingAgents.Agent`; the property list in `$script:LcaAgentDefaults` is the contract (incl. `ChannelData` - a per-row hashtable of channel facts for later phases, not exported; `Installs` - every install seen `{ Path, Channel, Version, Active }`; `EditorHost` for extensions). Unknown properties throw.
- **Evidence** (`New-LcaEvidence`): `{ Signal, Label, Weight, Source, Detail }`; `Why` = labels joined with ", ".
- **Command** (`New-LcaCommand`): `{ Exe, Arguments[], Display }` - always an argument array, never a string to re-parse.
- **Context** (`New-LcaContext`): `Options` (IncludeEditors, IncludeExtensions, All, SkipWinget, CheckUpdates, NoProbe, Explain, ShowReasons, Redact, Quiet, NoColor, Format), `Platform`, `Now`, `ScriptRoot`, `StateDir`, `ConfigDir`, `Config {StaleDays, ProbeTimeoutSec, Parallelism, Defaults}`, `Catalog`, `Extra`, `Exclude`, `ProbeCache`, `Parallelism`, `Timings`, `Data` (scratch hashtable shared between phases).
- **Workstream entry points**: `Find-LcaAgent -Context` returns rows (tiers detected/possible, all kinds; display scope is applied later by `Select-LcaAgentInScope`); `Add-LcaEnrichment -Context -Agent`; `Add-LcaUpdateInfo -Context -Agent`; `Read-LcaState`, `Get-LcaHistoryChange`, `Save-LcaState`; `ConvertTo-LcaReportHtml -Export`.
- **Context.Data keys**: `npm`, `npmRoot`, `wingetAvailable`, `wingetScanned`, `wingetPackages` (`{ Name, Id, Version, Available }` rows - C reads Available; one winget call per scan), `quiet`.
- **Diagnostics** are cleared by the entry points (`Invoke-LcaCli`, `Get-CodingAgent`) before the context is built, never inside the scan.
- **JSON export**: `schema/coding-agents.schema.json` (schemaVersion 2), produced only by `ConvertTo-LcaExport`.
- **Exit codes**: 0 ok, 1 error, 2 bad arguments, 3 `-FailOn` matched, 4 an update failed.
