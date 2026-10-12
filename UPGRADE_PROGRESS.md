# v2.0.0 upgrade progress

Working file for the v1 -> v2 upgrade (brief: "Ultracode prompt: list-coding-agents -> v2.0.0").
Resume rule: continue from the first unchecked item. Deleted in Phase 4.

Branch: `ccr-82f8cba4-qqa6vr` (the session's designated branch; see D-01).

## Phase checklist

- [x] Phase 0 - Recon (parity spec, verified defects, catalog draft, toolchain facts, baseline)
- [x] Phase 1 - Foundation (module skeleton, provider seam, result model + schema, build + bundle, lint + Pester config, CI skeleton, fixture builder + shims, v1 port, frozen contracts)
- [ ] Phase 2 - Workstreams A Detection / B Enrichment / C Updates / D State & CLI / E Report / F Repo & docs
- [ ] Phase 3 - Integrate, adversarial review, gates
- [ ] Phase 4 - Ship-ready (docs, final gates, progress file removed, push, draft PR)

## Phase 1 status (foundation)

Done (commit "feat: phase 1 foundation"):
- Module skeleton `src/ListCodingAgents` (manifest, loader, format view, 3 public cmdlets), entry script `src/list-coding-agents.ps1` with full comment-based help for every switch (v1 switches + all new ones; `PositionalBinding = $false`).
- Provider seam `Private/Platform/`: environment, PATH (platform separator, drive roots kept - N16), known folders (XDG, AppSupport), clock (`LCA_FAKE_NOW`), process runner (stdin closed, stdout+stderr, CI/NO_COLOR/TERM, hard timeout + tree kill, batch-file metacharacter guard), RunspacePool, registry Uninstall keys, PE version info.
- Result model + frozen contracts (Agent, Evidence, Command, Context, Scan), diagnostics with secret scrubbing, BOM-less atomic writes, one JSON export + `schema/coding-agents.schema.json` (validated by `Test-Json` in tests).
- v1 logic ported into the module layout (scorer with structured evidence + one scoring table in `data/catalog.json`, PATH / npm / winget sources, enrichment, update checks, state + partial-scan logic, console renderer). The v1 HTML generator is not ported: workstream E replaces it; a minimal client-side report keeps the pipeline working.
- `build.ps1` (Build / Lint / Test, `-Coverage`): deterministic, ASCII-checked, parse-checked bundle; `PSScriptAnalyzerSettings.psd1` (5.1 + 7.4 syntax, the three command profiles); CI skeleton `.github/workflows/ci.yml` (windows pwsh + 5.1, ubuntu, macos; drift, lint, Pester; report job placeholder).
- Fixture builder `tests/Helpers/Fixture.psm1` + `tests/fixtures/bin/shim.ps1`: fake HOME / APPDATA / XDG / PATH, fake npm / winget / any tool that logs arguments and replays canned output, in-process (`Use-LcaFixture`) and child-process (`Invoke-LcaFixtureScript`, `-AsScriptBlock` = irm|iex) runs.
- Parity proof: `tests/Detection/Parity.Tests.ps1` loads v1's scorer, lexicons, Get-Method and Get-Kind from the frozen v1 script via the AST and compares with v2 over 8,000+ inputs (exact score and reasons for every non-catalog name; tier for catalog names; method/kind for Windows paths). `tests/Parity/V1Run.Tests.ps1` runs the real v1 script and the v2 bundle on the same fixture machine on Windows (CI only).

Port deviations from v1 that are deliberate (each is a brief requirement or a confirmed defect fix):
outputs go to `-OutDir` (default: current directory) instead of the script folder (#15); JSON is the v2 export (D-05) and never an empty file or bare object (N2); BOM-less UTF-8 everywhere (#16); `Format-LcaSize 0` = `0 MB` (#18); probes go through the process seam (stderr captured, tree kill, #9 partly); PATH split per platform and Unix exec-bit candidates (N18); drive-root PATH entries kept (N16); command strings are argument arrays (N10); `-NoOpen` honoured (#19); exit never called under `irm | iex`.

Measured (Linux, pwsh 7.6.6):
- Lint: **0** findings on src/, build.ps1 and the bundle (v1: 55).
- Pester: **310 passed**, 0 failed, 4 skipped (Windows-only / 5.1-only), ~40 s; line coverage **74.0%** of src/ (gate is 80%, Phase 2 must add tests).
- Bundle: 183.9 KB, byte-identical across rebuilds.
- Fixture scan (1 npm agent, Linux): detects claude (v1 on the same fixture: 0).

Independent verification (Phase 1 verifier agent, read-only, at 6c86657): 1 blocker + 7 majors + 15 minors, all reproduced with fixture scripts. Fixed in b877fce: ValidateSet broke a real `irm | iex` (blocker); stale PATH entries threw in `Find-LcaExecutable`; relative `-OutDir` resolved against the process dir; RunspacePool ignored its timeout and lost errors/diagnostics; the timeout test did not prove the tree kill (now asserts recorded PIDs die - and fails when the kill is mocked out); command `Display` not paste-safe; `-Redact` over-matched (user `vscode` rewrote channel `vscode`); `-WhatIf` wrote state and reports; plus diagnostics wiped by the scan, N6 half-applied in history, `-Format json` stdout polluted, ISO dates becoming DateTime on pwsh 7, shim/process encodings, registry casts, batch path quoting, report opening outside the seam, contract gaps (`Installs`, `EditorHost`, Options, `wingetPackages`), build guard against top-level return/param/using, iex variable cleanup. Left for workstreams: 5.1 junction-following size walks (B), Update-CodingAgent re-probe (C).

CI (GitHub Actions) at e14f32e: windows pwsh 7 green (incl. the real v1-vs-v2 run: same detections), macOS green, ubuntu red only on the coverage gate (73.9%), windows 5.1 red on 3 issues fixed in 6c86657 (5.1 `-Include` quirk in a test, v1 JSON array unrolling in a test, stdin BOM on .NET Framework). Speed on the windows-latest fixture: v1 1547 ms vs v2 1875 ms (pwsh 7), v1 1699 ms vs v2 2441 ms (5.1) - gate 10 is NOT met yet (workstreams A/B).

After the fixes (Linux): 361 tests passed, 0 failed, 5 skipped; lint 0; coverage 73.0%.

Known gaps handed to Phase 2 (beyond the brief's workstream scope):
- A: scoring every binary in `/usr/bin` takes ~2.8 s on this box; `/bin` -> `/usr/bin` symlink produces a false PATH conflict (`sg`); on Linux `sg` (shadow-utils) shows as POSSIBLE.
- D: `Update-FormatData` for `-PassThru` objects in bundle mode; `-Format table|csv|markdown`; `-FailOn`; terminal renderer.

## Phase 2 status (workstreams)

- First attempt: six isolated writer agents (one per workstream). The worktree-isolation guard refused pwsh for all of them (D-08), and all six were then cut off by an account rate limit (HTTP 429, "session limit"). Work preserved as `wip(v2-ws-x)` checkpoint commits on each branch (A: catalog rebuilt from the sourced draft; B: Size/Usage; C: version/channels/commands; D: state/history/console/format; E: fonts, report template/CSS/JS, Playwright start; F: README/CONTRIBUTING/CHANGELOG/CLAUDE drafts, 5 commits). All six branches build.
- Second attempt (workflow `v2-phase2-workstreams`): per workstream, non-isolated implementer agents continue in the same worktree with pwsh (A in two parts), then an independent read-only verifier, then up to two verify -> fix rounds.
- That workflow was stopped twice while the session's usage limit ran out (its A part 1 and E agents were cut off mid-way; their work is in further `wip` checkpoints on v2-ws-a / v2-ws-e). Third attempt (2026-10-12): the same workflow script, now retrying an agent that dies (up to 3 attempts, told to pick up the uncommitted work), run as two concurrent runs to use 4 agent slots instead of 2: `wf_b4bfa792-a25` (A, B, F) and `wf_193be3bc-f0d` (E, D, C) - see D-09.

## Environment (this run)

| Item | Value |
|---|---|
| Host | Linux cloud container, Ubuntu 24.04, 4 vCPU |
| PowerShell | 7.6.6 (installed from packages.microsoft.com) |
| Pester | 6.2.0 |
| PSScriptAnalyzer | 1.25.0 |
| Node | 22.22.0, Chromium at /opt/pw-browsers |
| Windows | not available - Windows-only code is covered by fixtures + windows-latest CI |
| Network | npm/PyPI registries and raw.githubusercontent.com reachable; github.com web and api.github.com blocked (403) |

## Baseline (v1 @ 8d05c16)

- PSScriptAnalyzer default rules: **55** warnings (37 PSAvoidUsingWriteHost, 11 PSAvoidUsingEmptyCatchBlock, 3 PSUseSingularNouns, 2 PSUseUsingScopeModifierInNewRunspaces, 1 PSAvoidUsingInvokeExpression, 1 PSUseShouldProcessForStateChangingFunctions). Matches the brief.
- Linux fixture (npm-global `@anthropic-ai/claude-code` with a `claude` bin on PATH, `~/.claude` present, fake `npm` shim): v1 prints **0 detected, 0 possible**, "<0.1 MB on disk", "dead weight: <0.1 MB", wall clock 0.80 s. `coding-agents.json` is an **empty file** (not `[]`).
- v1 on a real Windows machine: not available in this environment.

## Toolchain facts (Phase 0 D)

Windows PowerShell 5.1 cannot run the following; all are banned in `src/` and enforced by `tests/Compat/Syntax51.Tests.ps1` (AST walk), because the analyzer misses several of them:

| Construct | Analyzer catches it? |
|---|---|
| `??`, `??=` | yes (PSUseCompatibleSyntax) |
| ternary `a ? b : c` | yes |
| `&&` / `\|\|` pipeline chains | yes |
| `?.` / `?[]` null-conditional | **no** |
| `ForEach-Object -Parallel` | yes (PSUseCompatibleCommands) |
| `ConvertFrom-Json -AsHashtable` / `-Depth` | yes |
| multi-child `Join-Path a b c` / `-AdditionalChildPath` | **no** |
| `clean {}` block | **no** |
| `$IsWindows` / `$IsLinux` / `$IsMacOS` (undefined on 5.1, throws under StrictMode) | **no** |
| `-Encoding utf8NoBOM`, `Get-Content -AsByteStream`, `ConvertTo-Json -AsArray`, `Test-Json`, `$PSStyle`, `Start-ThreadJob` | partly |
| `ProcessStartInfo.ArgumentList`, `Process.Kill($true)`, `String.Contains(char)`, `Path.GetRelativePath` (.NET Core only APIs) | **no** |

Other 5.1 traps recorded for implementers: `ConvertTo-Json` turns `DateTime` into `"\/Date(...)\/"` on 5.1 (always serialize dates as strings); 5.1 `ConvertTo-Json` escapes `<>&'` as `<` etc. while 7 does not (never rely on byte-identical JSON across editions); `'[..]' | ConvertFrom-Json` emits the array as ONE object on 5.1 (use `-InputObject` and `@()`); `Out-File/Set-Content -Encoding utf8` writes a BOM on 5.1; `String.Split('ab')` splits on each char on 5.1; files without a BOM are read as ANSI by 5.1 (keep every source file ASCII).

PSScriptAnalyzer: `PSUseCompatibleSyntax` accepts `TargetVersions = '5.1','7.4'`. All three `PSUseCompatibleCommands` profiles named in the brief ship with PSScriptAnalyzer 1.25.0 (`compatibility_profiles/`).

Pester 6.2.0 installs on pwsh 7.6 with `Install-Module Pester -RequiredVersion 6.2.0 -SkipPublisherCheck`. Playwright: use the preinstalled Chromium (`PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers`), never `playwright install` here.

## Parity spec (Phase 0 A) - what v1 does, exactly

### Switches

| Switch | v1 meaning |
|---|---|
| `-IncludeEditors` | Keep rows with `Kind='editor'` in both tiers (terminal, JSON, HTML, history, totals, dead weight). Without it they are dropped right after scoring (L665-666). `Kind='editor'` when the path matches `\Programs\(cursor\|windsurf\|kiro\|trae\|trae-cn)\` or the basename is one of those five (L534-539). Winget rows are always `cli`. |
| `-ShowReasons` | Adds a `Why` column to the per-channel DETECTED tables (L857). The POSSIBLE table always shows `Why`. |
| `-NoHtml` | Do not write or open `coding-agents.html`. |
| `-SkipWinget` | Skip `winget list`. Partial scan: previous `wingetOnly` names are carried into the new baseline and are never reported as gone; no trend point is written; if the previous state file has agents but no `wingetOnly` key, the state file is not written at all (L799-814). Note: `-CheckUpdates` still runs `winget upgrade` under `-SkipWinget` (L744). |
| `-CheckUpdates` | `npm outdated -g --json`: any DETECTED row whose `Package` matches and whose `latest` differs (string compare) from `Version` gets `Latest` + `npm i -g <pkg>@latest`. `winget upgrade`: DETECTED `Method='winget'` rows without `Latest` match on Id-in-Source or Name-in-Id -> `winget upgrade --id "<id>"`. Prints an "Updates available" list or "Everything is up to date". HTML tile 4 becomes "updates available". |
| `-UpdateAll` | Implies `-CheckUpdates`. If any updates: `Read-Host` y/n, then `Invoke-Expression` each `UpdateCmd`, then "re-run the scan to verify versions". |
| `-Json` | Write `coding-agents.json` next to the script: an array of DETECTED+POSSIBLE rows (after the editor filter) with keys `name tier command source method kind version latest updateCmd sizeMB lastUsed sessions30d mcpServers loggedIn stale uninstallCmd shadowedBy score why`. |

### Files

- `agents-extra.txt` / `agents-exclude.txt`, read from `$PSScriptRoot`: trimmed lines, `#` comments, case-insensitive. Extra: a PATH candidate scoring < 4 becomes score 5, why `agents-extra.txt override` (names not on PATH are never added). Exclude (wins over extra): PATH -> score -99; winget rows are skipped when the first word of the display name, or the whole display name, is listed.
- `last-scan.json` (next to the script, `Out-File -Encoding utf8`): `{ date: 'yyyy-MM-dd HH:mm' (local, no offset), agents: [DETECTED names after the editor filter], wingetOnly: [...], history: [{d:'yyyy-MM-dd', c:<detected count>, mb:<detected MB>}] (max 60, same day replaces), probes: {"<path>|<mtime ticks>": "<version>" or "?"} }`.
- Outputs `coding-agents.json` / `coding-agents.html` are written next to the script and the HTML is opened with `Invoke-Item`.

### Pipeline

1. **npm metadata** (only if `npm` resolves): `npm root -g`; every package dir (scoped `@x/y` included) with a `bin` in `package.json` maps each bin name (or the package's last name segment for a string `bin`) to `{Package, Version, Dir, Text = name + description + keywords, Deps = names in dependencies + optionalDependencies + peerDependencies}`.
2. **PATH candidates**: extensions = `PATHEXT` + `.PS1`; PATH split on `;`, trimmed, trailing `\` removed, existing dirs only, de-duplicated; dirs under `%WINDIR%` are skipped except `...\WindowsApps`; first occurrence of a basename wins, later ones in a different dir are recorded as `Shadows`.
3. **Per candidate** (basenames starting with `.` skipped): `Method` from path regex (npm / winget / `pip / uv` / scoop / cargo / bun / `standalone installer`); npm metadata overrides text, deps, method (`npm`), version, package, pkgDir; `.exe` version-info adds product + description text, `CompanyName` as publisher and the first dotted version (Node.js / Oven / Bun wrappers ignored); score; extra / exclude overrides; rows with score >= 2 are kept.
4. **winget list** rows (split on 2+ spaces): key = first word of the display name, lowercased; skipped if already found on PATH or excluded; scored with text `"<name> <id>"`, publisher = Id prefix, name = display name, path = Id. Version = column 3 if dotted-numeric, else `_x.y_` inside the Id. Row: `Command='(winget)'`, `Source=<id>`, `Method='winget'`, `Kind='cli'`.
5. **Tiers**: DETECTED >= 4, POSSIBLE 2-3, then the editor filter.
6. **History**: new / gone are diffed over DETECTED names only when the previous state had names; previous winget-only names are not "gone" on a run that did not scan winget.
7. **Enrichment** (DETECTED + POSSIBLE): size = recursive npm package dir or the `.exe` file itself; usage intel from config dirs derived from the command (`~/.<n>`, `~/.config/<n>`, `~/.<n>.json`, `%APPDATA%\<n>`, `%LOCALAPPDATA%\<n>`, with `-cli`/`-code` stripped too): last used = newest write time (depth 3, first 6000 files), sessions in 30 days (session-ish paths), MCP count (brace-depth scan of `mcpServers` / `mcp_servers` / `mcp` and TOML `[mcp_servers.x]`), auth = credential-looking file names or key names. Version probe (DETECTED, no version, `.exe`, not winget): `Start-Job` `& exe --version 2>$null`, 8 s timeout, cached by `path|mtime`.
8. **Fleet health**: `Stale` unless last used within 60 days (no evidence = stale); uninstall: npm -> `npm rm -g <pkg>`; winget-only -> `winget uninstall --id "<id>"`; winget on PATH -> `winget uninstall "<name>"`; `.exe/.cmd/.bat/.ps1` -> `Remove-Item "<path>"`. Dead weight = stale DETECTED, reclaim = their size sum; conflicts = DETECTED+POSSIBLE with shadows; total MB = DETECTED sizes; active30 = DETECTED used in 30 days; rank by DETECTED count: <=2 MINIMALIST, <=5 COLLECTOR, <=9 ENTHUSIAST, <=13 CERTIFIED HOARDER, else AGENT SINGULARITY.
9. **Terminal**: summary line, rank line, editors-hidden hint, partial-scan note, `+ new` / `- gone` lines, one table per method (order npm, winget, pip / uv, scoop, cargo, bun, standalone installer, unknown; columns Agent Version Size Used 30d MCP Auth Source [+Why]), PATH conflicts, dead weight (by size desc, with uninstall command), POSSIBLE table, updates section or tip.
10. **Exit code**: always 0 unless the script crashes.

### Deliberate v1 behaviors to keep (each gets a regression test)

- Ambiguous names (`sg` ast-grep, `src` Sourcegraph, `amp`, `pi`, `vibe`, `continue`, `roo`) score +2 only and never auto-detect on the name alone; they do not get the known-name bypass of the MCP / helper guards.
- `-SkipWinget` partial-scan baseline handling (carry-over, no trend point, legacy-state guard).
- Share card measures its text: stats flow by measured width with a 48 px gap; the rank pill shrinks its font (30 -> 18 px) and then trims, and is centred on both axes.
- Path signatures only boost the primary agent command, never sibling tools in the same install dir; the full path is never folded into the scored text.
- `@modelcontextprotocol/sdk` is not an AI SDK signal; MCP-utility and skill-installer names are hard-excluded.
- Node.js / Bun wrapper exes contribute no version-info text and no version.
- Probe results are cached by path + mtime.

## Verified defects (Phase 0 B)

Two independent passes: my own reading of the code, then an adversarial refuter agent that tried to disprove each item in sandboxes with a byte-identical v1 copy, fake HOME and fake npm/winget (full report: `docs/recon/defects-refutation.md`). Nothing was refuted.

| # | Defect | Lines | Verdict | Workstream |
|---|---|---|---|---|
| 1 | History built from the editor-filtered list | L665, L687, L795-810 | confirmed | D |
| 2 | Winget-only rows (`Command='(winget)'`) never get usage intel | L703, L288 | confirmed | B |
| 3 | No usage evidence => stale => uninstall suggestion | L768-773 | confirmed | B (usage) + C (suggestion) |
| 4 | Winget rows hardcode `Kind='cli'` | L655 | confirmed | A |
| 5 | Versions compared as strings | L735 | confirmed | C |
| 6 | "Everything is up to date" printed without evidence | L886-895 | confirmed | C + D |
| 7 | `-UpdateAll` uses `Invoke-Expression` + `Read-Host` | L900-913 | confirmed | C |
| 8 | `Remove-Item <exe>` uninstall suggestion | L773 | confirmed | C |
| 9 | Serial `Start-Job` probes, stderr dropped, no tree kill | L396-407, L709-723 | partly: one pwsh per probe, serial, stderr lost all confirmed; the hung-process leak did not reproduce on Linux (Windows untested) | B (seam: Phase 1) |
| 10 | Winget parsing by `\s{2,}`, second `winget upgrade` call | L633-661, L744-761 | confirmed | A (parser) + C (Available column) |
| 11 | Sizes measure launchers | L700-702 | confirmed | B |
| 12 | Reduced motion hides `.bar` | L1079, L1126 | confirmed | E |
| 13 | Share card prints the hostname | L1043, L1357 | confirmed | E |
| 14 | Google Fonts network request | L1053-1055 | confirmed | E |
| 15 | State and outputs written via `$PSScriptRoot` | L570, L669, L931, L1378 | confirmed | D |
| 16 | `Out-File -Encoding utf8` BOM differs by edition | L824, L932, L1379 | confirmed | Phase 1 (`Write-LcaTextFile`) |
| 17 | 11 empty `catch {}` | analyzer list | confirmed (11) | all (diagnostics: Phase 1) |
| 18 | `Format-Size 0` -> `<0.1 MB` | L279 | confirmed | Phase 1 (`Format-LcaSize`) |
| 19 | HTML always opens | L1381 | confirmed | D (`-NoOpen`) |
| 20 | README out of date | README.md | confirmed | F |
| 21a | Duplicated lexicon header | L82-91 | confirmed | Phase 1 (lexicons moved to catalog) |
| 21b | `Get-Method` last two branches identical | L530-531 | confirmed | Phase 1 |
| 21c | Unescaped `.` in `'\\.local'` etc. | L528-530 | partly: real, but harmless for `.local` because both branches return the same value; `.cargo` / `.bun` also match any char | Phase 1 |
| 21d | `lastUsed` / `date` without UTC offset | L819, L925 | confirmed | D (state) + Phase 1 (`ConvertTo-LcaIsoString`) |

New findings (each survived a refutation attempt by the agent that found it; N18 is mine):

| # | Sev | Finding | Lines | Workstream |
|---|---|---|---|---|
| N1 | high | npm metadata attached by command name even when the PATH winner is NOT the npm shim (native `claude.exe` first, old npm copy shadowed): version, size, update and uninstall describe the shadowed copy | L599-604 | A |
| N2 | high | `-Json` writes an object for 1 agent and a 0-byte file for 0 agents | L932 | Phase 1 (`ConvertTo-LcaJson`) |
| N3 | med | `$KnownCli` holds names that collide with non-agents (`goose` = pressly/goose, `copilot` = AWS Copilot, `mux`, `hermes` = Hermes JS engine, `kilo` editor); winget display name `Claude` (Claude Desktop) scores 12 | L96-107 | A (catalog `ambiguous`, corroboration) |
| N4 | med | MCP counts inflated: TOML `[mcp_servers.x.env]` subtables counted; `~/.claude.json` per-project duplicates summed; VS Code `"mcp":{"servers":{...}}` counts 1 | L313-337 | B (MCP map with names, de-duplicated) |
| N5 | med | Generic `%APPDATA%\<name>` credits Claude Desktop's folder and MCP servers to Claude Code | L298-299 | B (catalog configDirs first) |
| N6 | med | No winget => every run is "partial" => trend never recorded (Linux/macOS, Server, LTSC) | L630-632, L799-814 | D (partial only when winget exists but was skipped) |
| N7 | med | winget update matched by substring over hashtable order: `Anthropic.Claude` row can get `Anthropic.ClaudeCode`'s upgrade | L754-758 | C (exact Id match) |
| N8 | med-low | One shadowing install counted once per extension (`claude.cmd` + `claude.ps1`) | L509-511 | A |
| N9 | low-med | `-SkipWinget` still runs `winget upgrade` under `-CheckUpdates` | L744 | C (single winget call) |
| N10 | low | Commands assembled as PowerShell double-quoted strings: `$()` evaluates, `[ ]` wildcards | L737, L757, L771-773 | Phase 1 (`New-LcaCommand` argument arrays) + C |
| N11 | low | Empty previous baseline hides "+ new"; "no state" conflated with "zero agents" | L692 | D |
| N12 | low | State dates use the current culture's calendar (th-TH writes 2569) | L810, L819, L1018 | D (invariant culture; migration must not assume Gregorian) |
| N13 | low | Inline `#` comments in override lists break the entry; `agents-extra.txt` ignored for winget rows | L573-574, L644-660 | D (list parsing) + A (winget extra) |
| N14 | low | "logged in" false positives: `tokenizer.json`, `{"apiKey": null}` | L350-379 | B |
| N15 | low | Path regexes only handle `\` (signatures, method, kind) | L121-135, L524-536 | Phase 1 (normalised `/` matching) + A |
| N16 | low | `C:\` PATH entry trimmed to drive-relative `C:` | L486 | Phase 1 (`Get-LcaPathEntry`) |
| N17 | low | Probe cache never pruned | L678, L720, L823 | B/D |
| N18 | high | Linux/macOS: PATH split on `;`, `PATHEXT`/`WINDIR` assumed => 0 agents | L479-496 | Phase 1 (seam) + A |
| N19 | info (unverified, Windows) | Every `\WindowsApps\` path is labelled winget, but Store app-execution aliases live there too; then `winget uninstall "<basename>"` is a fuzzy query | L525, L772 | A + C |

## Decisions (frozen unless noted)

- **D-01** Branch: the session mandates `ccr-82f8cba4-qqa6vr`; it plays the role of `v2`. Workstream branches `v2-ws-<x>` are local worktree branches only (the session may not push other branches) and are merged locally.
- **D-02** `prompts/` does not exist in this checkout; nothing to leave untouched there. The brief lives outside the repo.
- **D-03** Windows-only verification (real v1 vs v2 run, winget, registry, PE info, 5.1) cannot run here. It is covered by fixtures and a `windows-latest` CI job (5.1 + 7); if CI cannot be observed, the final report says so.
- **D-04** Catalog `pathSignatures` are regexes matched case-insensitively against paths normalised to `/`, so one signature works on every OS (v1's were backslash-only, N15).
- **D-05** The JSON export changes shape: v1 wrote a bare array; v2 writes `{ schemaVersion: 2, ..., agents: [...] }` (the brief requires a `schemaVersion`). Every v1 agent key keeps its v1 meaning inside `agents[]`. Migration note goes to CHANGELOG (`jq '.agents'`).
- **D-06** The install channel is a machine id (`npm`, `pipx`, `standalone`, ...) in `channel`; `method` keeps v1's display labels (`standalone installer`, `pip / uv`) for compatibility.
- **D-07** Workstream branches (`v2-ws-a` ... `v2-ws-f`) live only in local worktrees and are merged locally into the session branch (see D-01).
- **D-08** The harness's worktree-isolation guard refuses every `pwsh` command for isolated agents (it cannot prove pwsh won't run git outside the worktree), and the isolated worktrees were created from `main` (v1) - each agent rebased its branch onto the Phase 1 tip b0b0b8e. The guard was not circumvented: the isolated writers finish their code without running it, then a separate NON-isolated agent (normal session permissions, the same ones the integrator uses) runs build / lint / Pester in that worktree and fixes failures, and a third agent verifies. Reported in the final report.
- **D-09** One workflow runs at most 2 agents at a time on this 4-CPU host, so Phase 2 runs as two concurrent runs of the same script (each takes a subset of workstreams through `args.ws`). Agents that die on an API error or session limit are retried up to twice with a note to resume from the worktree's uncommitted state.

## Catalog draft (Phase 0 C)

Researched by one agent from primary sources (npm registry JSON, PyPI JSON, formulae.brew.sh API, Scoop bucket manifests, Chocolatey, the official winget source index `cdn.winget.microsoft.com/cache/source.msix`, VS Code Marketplace API, vendor docs / READMEs), then **independently re-checked by a second agent** that re-fetched every claim.

- Draft: `docs/recon/catalog-draft.json` (66 entries: 47 CLIs, 12 editors/desktop apps, 7 extension-only; 68 commands, 185 package ids, 379 source claims). Notes: `docs/recon/catalog-draft.md`.
- Cross-check: `docs/recon/catalog-xcheck.json` / `.md`: 183 / 185 package ids confirmed, 2 unofficial, 0 not found; 68 / 68 commands confirmed; configDirs checked for 19 entries (17 confirmed, 2 partly).
- Corrections to apply when the catalog is built (workstream A):
  - drop choco `zed` (it is AuthZed's SpiceDB CLI, not the Zed editor) and choco `copilot-cli` (unapproved, stale; `github-copilot-cli` is the live one);
  - cursor-cli configDirs: add `~/.cursor` and `{XDG_CONFIG_HOME}/cursor`; cline: add `~/.cline`;
  - add commands `hermes-agent`, `hermes-acp`, `kimi-cli`; legacy PyPI `kimi-code` installs `kimi-code` (not `kimi`);
  - PyPI `openhands-ai` installs no executable; iFlow CLI shut down 2026-04-17 (keep for detection, note it);
  - several packages are deprecated / unpublished (see xcheck notes) - keep for detection of existing installs, mark in `notes`.
- Notable facts (confirmed by both agents): Cursor CLI's main command is now `agent` (plus legacy `cursor-agent`); Gemini CLI is being replaced by Antigravity CLI `agy`; Windsurf was renamed Devin Desktop; Amazon Q Developer CLI became Kiro CLI and keeps the `q` alias; collisions with non-agents recorded as `ambiguous`: `sg`, `src`, `forge`, `q`, `goose`, `amp`, `copilot`, `warp`, `cbc`, `grok`, `agent`.
