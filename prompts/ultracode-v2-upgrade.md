# Ultracode prompt: list-coding-agents → v2.0.0

Based on a full read of the repo at commit `8d05c16` (2026-10-11). Every defect listed below was checked against the code, and the toolchain facts were checked by running PowerShell 7.6, Pester 6.2 and PSScriptAnalyzer 1.25.

## How to run it

1. Open Claude Code in this repo and turn on ultracode. Either start it with `claude --effort ultracode` (this also sets xhigh effort) or run `/effort ultracode` in an open session. Ultracode needs a model that supports xhigh effort and has Dynamic workflows turned on. On Pro, enable workflows in `/config`.
2. Switch to auto permission mode, or pre-allow `pwsh`, `git`, `node` and `npx` in `/permissions`. Otherwise background agents stall at permission prompts.
3. Paste everything under **The prompt**. Or just type: `Read prompts/ultracode-v2-upgrade.md and execute the prompt in it.`
4. Watch progress with `/workflows`. Expect a long run that uses a lot of tokens. Progress is saved in `UPGRADE_PROGRESS.md` and committed after each phase. If the session dies, open a new one and type `Resume the v2 upgrade from UPGRADE_PROGRESS.md`.
5. Running on Windows works best, because v1 and v2 can be compared on your real machine. In a Linux or cloud session, Claude installs PowerShell itself and covers the Windows-only code with fixtures and CI.

---

## The prompt

ultracode: take `list-coding-agents` from a vibe-coded single script to a finished, tested, documented **v2.0.0**, following this brief end to end.

Nobody will answer questions mid-run. Every judgment call below has a default. Where the brief is silent, pick the conservative option, log it under **Decisions** in `UPGRADE_PROGRESS.md`, and keep going.

### 1. Ground truth (verified at commit `8d05c16`)

- **The script.** `list-coding-agents.ps1` is 1,382 lines, ASCII, no BOM, and does everything in one file. Section map:

  | Lines | Section |
  |---|---|
  | L93-148 | lexicons |
  | L151-260 | scorer `Get-AgentScore` |
  | L263-407 | enrichment helpers |
  | L410-474 | npm metadata |
  | L477-519 | PATH scan |
  | L521-564 | method / kind / PE info |
  | L568-583 | extra / exclude lists |
  | L586-625 | PATH evaluation |
  | L630-662 | winget scan |
  | L665-666 | tiers |
  | L669-695 | history diff |
  | L698-723 | enrichment |
  | L726-763 | update check |
  | L766-785 | fleet health |
  | L795-826 | persistence |
  | L829-915 | terminal report |
  | L918-934 | JSON export |
  | L937-1382 | HTML report: one here-string with inline CSS/JS |

- **Other files.** `README.md` (casual voice, partly out of date) and `LICENSE` (MIT). There are no tests, no CI, no lint config, no `.gitignore`, no changelog and no release process.
- **Baseline.** The script parses cleanly and already uses 5.1-compatible syntax (PSUseCompatibleSyntax: 0 findings). PSScriptAnalyzer's default rules report 55 warnings:

  | Count | Rule |
  |---|---|
  | 37 | PSAvoidUsingWriteHost |
  | 11 | PSAvoidUsingEmptyCatchBlock |
  | 3 | PSUseSingularNouns |
  | 2 | PSUseUsingScopeModifierInNewRunspaces |
  | 1 | PSAvoidUsingInvokeExpression |
  | 1 | PSUseShouldProcessForStateChangingFunctions |

- **Linux.** Under PowerShell 7.6, v1 reports **0 agents** even when Claude Code is installed through npm and `~/.claude` exists. It splits PATH on `;` and assumes `PATHEXT` and `WINDIR` exist.
- **Read the entire script before changing anything.** Its comments record deliberate fixes:
  - ambiguous names (`sg` = ast-grep, `src` = Sourcegraph) are held to the review tier;
  - the `-SkipWinget` partial-scan baseline logic;
  - the share-card layout that measures its text (L1285-1338).

  Keep those behaviors, carry the comments over, and give each one a regression test.

### 2. Verified defects (every fix needs a regression test)

1. **History follows display filters.** History is built from the editor-filtered list (L665, L687, L810). Toggling `-IncludeEditors` between runs therefore reports editors as "+ new"/"- gone" and puts phantom jumps in the trend line. This is the same class of bug as the `-SkipWinget` fix. Persist the unfiltered set plus the scan scope, and only diff like with like.
2. **Winget-only agents are always dead weight.** Their rows have `Command='(winget)'`, so `Get-AgentIntel $r.Command` (L703) finds no config dirs (L288). They never get a last-used date and always land in dead weight with an uninstall suggestion, even when used daily.
3. **No usage evidence is treated as stale.** L768-769 mark an agent stale unless usage evidence exists. Any agent whose config dir isn't in the generic locations gets an uninstall suggestion. Usage must be `active | stale | unknown`, and only stale-with-evidence counts as dead weight.
4. **Winget rows hardcode `Kind='cli'`** (L655). A GUI editor that only winget sees (for example Cursor without its shell command on PATH) shows up without `-IncludeEditors`.
5. **Versions are compared as strings** (`-ne`, L735). A prerelease, or an install newer than "latest", is offered a downgrade. Use real comparison: SemVer with prerelease tags, `v` prefixes, 4-part winget versions, and `Unknown` / `< x` tokens.
6. **"Everything is up to date" can be false** (L894). It prints even when npm or winget is missing, when a query failed, or when the agent's channel is never checked. Status must be `current | outdated | unknown(reason)`.
7. **`-UpdateAll` uses `Invoke-Expression`** on assembled strings (L907) and blocks on `Read-Host` (L902). Fix:
   - invoke with argument arrays (`& $exe @args`);
   - add `SupportsShouldProcess` (`-WhatIf`/`-Confirm`) and `-Force` for non-interactive runs;
   - check each command's exit code;
   - re-probe versions afterwards.
8. **The uninstall suggestion is dangerous.** For standalone installs, dead weight suggests `Remove-Item <exe>` (L773). That is wrong for installer-managed apps and shims, and risky to paste.
   - Use the channel's own uninstaller (pipx, uv, scoop, cargo, bun, pnpm, choco, brew), or the registered `QuietUninstallString`/`UninstallString`.
   - If none is known, say "no safe uninstall command known".
   - Never suggest `Remove-Item`.
9. **The version probe is slow and can leak processes** (L396-407).
   - Problems:
     - `Start-Job` starts a full PowerShell process per exe;
     - probes run one at a time with an 8-second timeout each;
     - `2>$null` discards stderr, where some CLIs print their version;
     - removing the job doesn't reliably kill a hung exe.
   - Replace it with `System.Diagnostics.Process`:
     - close stdin and capture stdout and stderr;
     - set `CI=1`, `NO_COLOR=1`, `TERM=dumb`;
     - enforce a hard timeout and kill the whole process tree.
   - Run probes with bounded parallelism (a RunspacePool, which works on 5.1) and cache results by path + mtime + size.
10. **Winget parsing is fragile** (L636, L749).
    - Problems:
      - `-split '\s{2,}'` breaks on names and IDs truncated with `…`, and on localized output;
      - `-CheckUpdates` runs `winget upgrade` as a second command even though `winget list` already has an Available column.
    - Fix:
      - prefer `Microsoft.WinGet.Client` (`Get-WinGetPackage`) when it's installed;
      - otherwise parse by column offsets taken from the header/separator line;
      - make one winget call per scan;
      - never build `--id` from a truncated ID.
11. **Sizes measure launchers, not installs** (L701-702). Scoop shims and pipx/uv launchers report the launcher's size, `.cmd` files get no size, and winget-only rows get no size at all.
    - Resolve the real install root per channel, plus the registry's `InstallLocation`/`EstimatedSize`.
    - Report the data footprint of config dirs (`~/.claude`, …) separately from the install footprint.
12. **Reduced motion hides the search bar.** `.bar` starts at `opacity:0` (L1079) and is missing from the reduced-motion reset (L1126). With "reduce motion" on (Windows animations off), the search box and share button never appear.
13. **The share card shows the hostname** (L1043, L1357), on an image that's meant to be posted publicly. Default it off.
14. **The report loads Google Fonts** (L1053-1055). That's a network request, and an IP leak, every time someone opens a local file, and the fonts hang offline. The report must make zero network requests.
15. **State and outputs are written next to the script** via `$PSScriptRoot` (L570, L669, L931, L1378). This breaks read-only installs and `irm … | iex`, where `$PSScriptRoot` is empty.
16. **UTF-8 output is inconsistent.** `Out-File -Encoding utf8` (L824, L932, L1379) writes a BOM on 5.1 and none on 7. Python's `json` and Node's `JSON.parse` reject the BOM. Write BOM-less UTF-8 explicitly.
17. **11 empty `catch {}` blocks fail silently.** Each must `Write-Verbose`/`Write-Debug` and add an entry to a `diagnostics` array in the JSON.
18. **`Format-Size 0` returns `<0.1 MB`** (L279). An empty fleet prints "<0.1 MB on disk" and "dead weight: <0.1 MB".
19. **The HTML report always opens itself** (L1381). There's no `-NoOpen` for CI, SSH or headless runs.
20. **The README is out of date.**
    - These features are undocumented: `-UpdateAll`, `-SkipWinget`, `agents-exclude.txt`, MCP counts, logged-in detection, PATH conflicts, dead weight, fleet rank, the trend line and the share card.
    - The run instructions skip the execution-policy/`Unblock-File` step. On default Windows clients, a downloaded `.ps1` won't run without it.
21. **Small stuff:**
    - duplicated lexicon header (L82-91);
    - `Get-Method`'s last two branches are identical (L530-531);
    - unescaped `.` in `'\\.local'`, `'\\.cargo'`, `'\\.bun'` (L528-530);
    - `lastUsed` and `date` are exported without a UTC offset (L819, L925).

Phase 0 must re-confirm each item against the code and look for more.

### 3. Target state

#### Product

- Runs on Windows PowerShell 5.1, and on PowerShell 7.4+ on Windows, macOS and Linux. Windows-only sources (winget, PE version info, registry, scoop, choco) switch off cleanly on other platforms.
- Stays zero-config: download one `.ps1`, run it, get a terminal summary and an HTML report.
- Every v1 switch keeps its v1 meaning. `agents-extra.txt`, `agents-exclude.txt` and an existing `last-scan.json` keep working.
- Also ships as a PowerShell Gallery module named `ListCodingAgents` (the name was free when this brief was written). Its cmdlets emit objects: `Get-CodingAgent`, `Update-CodingAgent`, `Export-CodingAgentReport`.

#### Architecture

- **Layout.** `src/ListCodingAgents/` holds:
  - the manifest;
  - `Public/` (one cmdlet per file);
  - `Private/` (one concern per file);
  - `data/catalog.json`;
  - `report/` (`template.html`, `report.css`, `report.js`, `fonts/`).
- **Provider seam.** All external input goes through small private functions that tests can mock:
  - environment variables and PATH;
  - filesystem roots (HOME, APPDATA, LOCALAPPDATA, XDG);
  - process execution (package managers, winget, `--version` probes);
  - the registry;
  - the clock.

  No scanner calls `Get-Date` or `& npm`, or reads `$env:`, directly.
- **One result model.**
  - Objects carry the PSTypeName `ListCodingAgents.Agent`, with a `format.ps1xml` default table.
  - There is one JSON export, with a `schemaVersion`, validated against `schema/coding-agents.schema.json`.
  - The HTML report renders from that same JSON, embedded as `<script type="application/json">`.
- **Single-file build.** `build.ps1` bundles the module, catalog and report assets into one deterministic `list-coding-agents.ps1`. The repo-root `list-coding-agents.ps1` *is* that build output, committed so raw downloads keep working. CI fails if it differs from a fresh build.
- **Concurrency.** Winget, registry and package-manager queries run alongside the PATH scan. Probes and size walks run in a bounded RunspacePool. `-Verbose` prints timings for each phase.
- **Strict mode.** `Set-StrictMode -Version Latest` is on inside the module, with no violations.

#### Detection v2

- **Hybrid.** A data-driven catalog covers known agents, and the heuristic scorer still catches unknown ones. An agent missing from the catalog must still be detected exactly as v1 would detect it, and a parity test proves this.
- **Catalog entries** have these fields: `id`, `displayName`, `vendor`, `kind` (cli|editor|extension), `commands`, `ambiguous`, `packages` per channel (npm, pypi, cargo, brew, scoop, choco, winget, vscode), `pathSignatures`, `configDirs` per OS, `versionArgs`, `homepage`, `sources` (URLs proving each package name), `verified`.
  - Seed the catalog from v1's `$KnownCli`, `$AmbiguousCli`, `$PathSignatures` and `$BrandWords`.
  - Research agents v1 misses. These are candidates to verify, not facts: Antigravity's `agy` launcher (the README's own "undetectable" example), Amazon Q Developer/Kiro CLI, Qodo, Plandex, gptme, Open Interpreter, Jules, Rovo Dev, Warp, Zed, Mistral Vibe, Continue CLI (`cn`), Pi.
  - Never invent a package name. An entry without a primary-source URL goes in with `verified:false` and its command name only.
- **Structured evidence.**
  - The scorer returns evidence objects (signal, weight, source) instead of a comma-separated string. All weights and thresholds live in one table.
  - `-ShowReasons` keeps working.
  - A new `-Explain <name>` prints the full breakdown for one command, including why it was excluded.
- **New detection sources.** Each one feeds real metadata into the same scorer, not just a name:
  - Python dist-info `METADATA` (`Summary`, `Keywords`, and `Requires-Dist` entries such as anthropic, openai or litellm) for pipx, uv tools and pip user scripts;
  - cargo `~/.cargo/.crates2.json`;
  - bun and pnpm global `package.json` files;
  - Homebrew (`brew info --json=v2 --installed`);
  - scoop app manifests and choco nuspecs;
  - the Windows Uninstall registry keys (HKCU, HKLM, WOW6432Node);
  - VS Code-family extension folders (Code, Insiders, VSCodium, Cursor, Windsurf, …), reading each extension's `package.json`, reported with kind `extension`.
- **Scope switches.**
  - Default output is CLIs only, as in v1.
  - `-IncludeEditors` adds GUI editors, a new `-IncludeExtensions` adds editor extensions, and `-All` adds both.
  - History records everything regardless of these switches.
  - The headline count, fleet rank and trend line use CLIs only, so they stay comparable between runs.
- **Labeled corpus** (`tests/fixtures/corpus/`). Positives are real agent metadata. Negatives:

  | Group | Examples |
  |---|---|
  | dev CLIs from the npm global root | eslint, prettier, typescript, ts-node, nodemon, serve, http-server, playwright, pnpm, yarn, corepack, chromedriver |
  | short names that collide with agents | `sg` (ast-grep), `src` (Sourcegraph), `forge` (Foundry) |
  | cloud and infra CLIs | gh, az, aws, gcloud, docker, kubectl, terraform |
  | AI tools that aren't coding agents | ollama, llm, MCP servers, skill installers |
  | helper binaries | launchers, updaters |

  The test asserts that every positive reaches DETECTED and no negative does. A negative may land in POSSIBLE only with a documented reason.

#### Enrichment

- **Probes and sizes:** process-safe parallel probes (defect 9), true install roots (defect 11), and a data footprint for each agent.
- **Usage intel:** check the catalog's `configDirs` first. Then fall back to the generic rule, extended with:
  - XDG: `$XDG_CONFIG_HOME`, `~/.local/share/<n>`, `~/.local/state/<n>`;
  - macOS: `~/Library/Application Support/<n>`.

  This fixes defects 2 and 3.
- **MCP map:** for each agent, the *names* of its configured MCP servers plus their transport (stdio or http). The report shows which servers several agents share. Never output `env`, `args`, `headers`, URLs or any other config value.
- **Auth detection stays presence-only** (file names and key names). Secret values never reach output, logs, state or reports.

#### Updates and lifecycle

- **`-CheckUpdates` channels:** npm, pnpm, bun, pipx, uv, pip (user installs), cargo, scoop, choco, winget and brew.
  - Use each tool's own outdated/JSON command where it has one, with timeouts.
  - Registry APIs (npm, PyPI JSON, crates.io) are a fallback only.
  - GitHub latest-release checks apply only to catalog entries that declare a repo.
- **Correctness:** correct update and uninstall commands for each channel (defects 7 and 8), real version comparison (defect 5), and honest statuses (defect 6).
- **Updating:** `Update-CodingAgent` and `-UpdateAll` go through ShouldProcess and print each agent's version before → after.
- **Exit codes:** documented, plus `-FailOn outdated,stale,conflict,new` for CI.

#### State, config and CLI

- **State directory:**

  | OS | Location |
  |---|---|
  | Windows | `%LOCALAPPDATA%\list-coding-agents\` |
  | macOS | `~/Library/Application Support/list-coding-agents/` |
  | Linux | `${XDG_STATE_HOME:-~/.local/state}/list-coding-agents/` |

  - On the first run, copy a v1 `last-scan.json` from next to the script and keep the original.
  - State carries a `schemaVersion`.
  - A corrupt state file is moved aside to `last-scan.corrupt-<timestamp>.json` with a warning, never silently overwritten.
  - History records each agent's version, so scans report version bumps ("claude 1.0.3 → 1.0.9") and not just added or removed names.
- **Config:** the extra/exclude lists are read from next to the script (as in v1) and from the config dir. An optional `config.json` holds `staleDays` (default 60), `probeTimeoutSec` (default 8) and default switches.
- **Outputs:** `coding-agents.html` and `coding-agents.json` go to `-OutDir`, which defaults to the current directory. That matches v1 for the documented "run it from its folder" workflow.
- **New switches** (all v1 switches unchanged):
  - output: `-NoOpen`, `-OutDir`, `-PassThru`, `-Format table|json|csv|markdown` (to stdout), `-Quiet`, `-NoColor` (and honor `NO_COLOR`)
  - privacy: `-Redact` (strips the username and hostname from the generated JSON and HTML, for sharing the files)
  - detection: `-Explain`, `-IncludeExtensions`, `-All`, `-NoProbe`
  - CI and info: `-FailOn`, `-Version`

  Every switch gets full comment-based help.
- **Terminal output:**
  - tables sized to the console width, with status colors;
  - `Write-Progress` instead of the static "enriching…" line;
  - an ASCII fallback when the console isn't UTF-8.

  Source files stay ASCII; emit glyphs with expressions like `[char]0x2713`.

#### HTML report v2

Keep the identity: the dark "fleet manifest" look, Syne + JetBrains Mono, the lime accent.

- **Self-contained:** one file, zero network requests.
  - Embed WOFF2 files for Syne and JetBrains Mono, subset to Latin with something like fonttools `pyftsubset`. Both fonts are SIL OFL 1.1, so commit the font files and their license. If you can't get the fonts, fall back to system font stacks.
  - Keep a 20-agent report under 500 KB.
- **Safe rendering:** render client-side from the embedded JSON using `textContent` and DOM APIs. Never use `innerHTML` with data.
- **Features:**
  - light theme via `prefers-color-scheme`, plus a toggle;
  - sorting by name, size, last used or status;
  - filters for channel, kind and status (outdated, stale, conflict, new, unknown);
  - a detail drawer per agent showing versions, paths, install vs data footprint, usage, MCP server names, detection evidence, and update/uninstall commands with copy buttons;
  - keyboard support: `/`, Esc, j/k, Enter;
  - `aria-live` feedback when something is copied.
- **Quality bar:** WCAG AA contrast, works at 375 px wide with no horizontal scroll, and has a print stylesheet.
- **Privacy toggle:** redacts the username in paths and hides the hostname. It's on by default for the share card. Keep the share card's measured layout.
- **Trend chart:** labeled axes, values on hover, and version bumps when history has them.

#### Repo and release

- **Repo files:** `.gitignore` (reports, state, share cards), `.gitattributes`, `.editorconfig`.
- **Lint config:** `PSScriptAnalyzerSettings.psd1` enables:
  - PSUseCompatibleSyntax, targeting 5.1 and 7.4;
  - PSUseCompatibleCommands, with the profiles that ship with PSScriptAnalyzer: `win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework`, `win-8_x64_10.0.17763.0_7.0.0_x64_3.1.2_core` and `ubuntu_x64_18.04_7.0.0_x64_3.1.2_core`.

  Every suppression needs a justification, for example Write-Host in the console renderer only.
- **CI** (`.github/workflows/ci.yml`, with actions pinned to versions):
  - runners: windows-latest (both `shell: powershell` for 5.1 and `shell: pwsh`), ubuntu-latest, macos-latest;
  - steps: lint, Pester, build-drift check, bundle smoke test, report tests.
- **Release workflow,** triggered by `v*` tags:
  - builds the bundle and SHA256 checksums;
  - creates a GitHub Release with notes taken from CHANGELOG;
  - publishes to the PowerShell Gallery only when a `PSGALLERY_API_KEY` secret exists.

  Don't tag or publish anything yourself.
- **Docs:**
  - **README rewrite.** Keep the author's playful voice in the intro, then crisp reference sections:
    - install: direct download plus `Unblock-File` or a one-off `-ExecutionPolicy Bypass`; `Install-Module`; `irm | iex` with a note to inspect the script first;
    - quick start, every switch, and how detection works;
    - privacy: what the tool reads, what it never reads or sends, and no telemetry;
    - FAQ;
    - screenshots generated from fixture data only.
  - **`CONTRIBUTING.md`:** an "add an agent in 5 minutes" guide (catalog entry + corpus fixture + `-Explain` check).
  - **`CHANGELOG.md`:** Keep a Changelog format, with 1.x reconstructed from git history.
  - **Also:** `SECURITY.md`; issue templates for "missing agent" and "false positive" (both ask for `-Explain <name>` output); a PR template.
- **Maintainer tooling:**
  - a repo `CLAUDE.md` covering the architecture, the build/test/lint commands, the 5.1 rules, the provider seam and the secret rules;
  - a `.claude/settings.json` SessionStart hook that installs pwsh, Pester and PSScriptAnalyzer in cloud sessions when they're missing.

#### Out of scope

- rewriting in another language
- adding runtime dependencies
- telemetry
- any automatic uninstall or deletion
- GUI or Electron apps
- background or scheduled scans
- license changes
- pushing to `main`, tagging, publishing

### 4. Rules of engagement

- **Never touch the host's real toolchain.** No real `npm i -g`, `winget upgrade`, `pipx upgrade` or uninstalls. Test updaters against fake shims on PATH (`tests/fixtures/bin/npm`, `npm.cmd`, `winget.cmd`, …) that record their arguments.
- **Never print, `cat` or copy real agent config or credential files** (`~/.claude.json`, `~/.codex/auth.json`, …) into the transcript or into fixtures. Fixtures use obvious fakes (`sk-ant-FAKE-0000`, `ghp_FAKE0000`), and tests prove those canary values never reach any output.
- **Set up the toolchain first.**
  - If `pwsh` is missing, install PowerShell 7. Drop `sudo` if you're root.
    - Ubuntu:

      ```bash
      curl -sSLo /tmp/pmp.deb "https://packages.microsoft.com/config/ubuntu/$(. /etc/os-release; echo "$VERSION_ID")/packages-microsoft-prod.deb"
      sudo dpkg -i /tmp/pmp.deb && sudo apt-get update && sudo apt-get install -y powershell
      ```

    - macOS: `brew install --cask powershell`
  - Install the modules:

    ```powershell
    Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck
    Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
    ```

    `-SkipPublisherCheck` is needed on Windows because an old inbox Pester is installed. Pester 6.x still supports 5.1; pin the version in CI.
  - Report tests use a current Node LTS with Playwright and `@axe-core/playwright`. Use a browser that's already installed if there is one (`executablePath`, or `channel: 'msedge'` on Windows); otherwise install only Chromium.
  - If you can't get `pwsh` running at all, stop and report. Don't ship PowerShell you couldn't run.
- **On Windows,** also run v1 and v2 on the real machine (`-NoOpen -Json`, never `-UpdateAll`) and explain every difference in the final report.
- **Git:**
  - Use the session's designated branch if there is one; otherwise create `v2` from `main`.
  - Commit after each logical change and at the end of every phase, using Conventional Commits.
  - Push the working branch after each phase if a remote is configured.
  - Never force-push, and never push to `main`.
  - Leave `prompts/` untouched.
- **`UPGRADE_PROGRESS.md`** at the repo root holds the phase checklist, the decisions log, verification evidence and measured numbers. Commit it with every phase.
  - If it already exists, you are resuming: read it and continue from the first unchecked item.
  - In the last phase, move whatever should be kept into CONTRIBUTING or CHANGELOG, then delete the file.
- **Writers never verify their own work.** Every implementation agent gets an independent verifier agent.
- **Fix loops stop** when everything is green, or after two consecutive rounds that make no progress. In that case, record the blocker and move on.

### 5. Plan: one workflow per phase, commit between phases

#### Phase 0: Recon (read-only, parallel)

Five read-only agents (A–E) run in parallel:

- **A** maps v1: function inventory, data flow, side effects and the exact meaning of each switch. This becomes the **parity spec**.
- **B** confirms each defect in §2 with line citations and looks for more. A second agent tries to refute every finding, and only findings that survive are kept.
- **C** researches the catalog on the web. For every seeded and candidate agent it records command names, install channels and package names, config dirs, version flag and homepage, each with a primary-source URL. A second agent cross-checks every package name. If there is no web access, keep v1's names and mark entries `verified:false`.
- **D** confirms toolchain facts:
  - which syntax 5.1 can't run and must be banned (`??`, `?.`, ternaries, `&&`/`||`, `ForEach-Object -Parallel`, `ConvertFrom-Json -AsHashtable`, multi-child `Join-Path`, `clean {}`);
  - the analyzer config;
  - Pester and Playwright setup.
- **E** records the baseline: v1's behavior on fixtures (and on the real machine if this is Windows), wall-clock time, and lint counts.

Output: `UPGRADE_PROGRESS.md` with the verified defects, the parity spec, the sourced catalog draft and the frozen decisions. Commit.

#### Phase 1: Foundation (sequential, 1-2 agents)

Everything else builds on this phase.

- **Scaffolding.** Build:
  - the module skeleton;
  - the provider seam;
  - the result model and JSON schema;
  - `build.ps1` and the bundle;
  - the analyzer settings and Pester config;
  - the CI skeleton.
- **Fixture builder.** It creates fake HOME, APPDATA, XDG and PATH trees, plus fake shims for npm, pnpm, bun, pipx, uv, cargo, brew, scoop, choco and winget that replay captured output.
- **Port without changing behavior.** Move v1 into the module with **no behavior change**, and prove it:
  - On Windows (the real machine or windows-latest CI), run real v1 and v2 against the same fixtures through the shims and diff the results.
  - Elsewhere, diff against the parity spec.
- **Freeze contracts:** function signatures, the Agent object and the JSON schema. Phase 2 codes against these. A workstream that needs a contract change requests it in its handoff note, and Phase 3 applies it.

Commit.

#### Phase 2: Parallel workstreams

Each workstream:

- runs in its own git worktree on a branch named `v2-ws-<x>`;
- edits only the files it owns;
- finishes with its tests green and a handoff note;
- gets an independent verifier that checks its diff against §2 and §3.

| Workstream | Scope | Owns |
|---|---|---|
| A Detection | catalog, scorer v2 + evidence, `-Explain`, new sources, winget parser, Kind fix, corpus test | `Private/Detection/**`, `data/catalog.json`, `tests/Detection/**`, `tests/fixtures/corpus/**` |
| B Enrichment | probes, install roots + sizes, data footprint, usage intel, MCP map, caches | `Private/Enrichment/**`, `tests/Enrichment/**` |
| C Updates | per-channel outdated checks, version comparison, update/uninstall commands, `Update-CodingAgent`, `-UpdateAll`, exit codes | `Private/Updates/**`, `Public/Update-CodingAgent.ps1`, `tests/Updates/**` |
| D State & CLI | state dir, migration and schema, history, config, new switches, terminal renderer, `-Format`/`-PassThru` | `Private/State/**`, `Private/Console/**`, `Public/Get-CodingAgent.ps1`, the entry script's param block, `tests/State/**`, `tests/Console/**` |
| E Report | template/CSS/JS, offline fonts, client-side rendering, accessibility, themes, filters, privacy, share card, Playwright tests | `report/**`, `Public/Export-CodingAgentReport.ps1`, `tests/report/**` |
| F Repo & docs | dotfiles, issue/PR templates, release workflow, SECURITY, CLAUDE.md, SessionStart hook; drafts of README/CONTRIBUTING/CHANGELOG (finalized in Phase 4) | `.github/**` except `ci.yml`, `.claude/**`, `docs/**`, root `*.md` except `UPGRADE_PROGRESS.md` |

#### Phase 3: Integrate and harden

- **Merge and fix.** Merge in the order A → B → C → D → E → F, apply the contract change requests, and run every gate in §6. Fix until green; the stop rule from §4 applies.
- **Adversarial review.** Reviewers fan out in parallel, and no reviewer looks at code it wrote. The angles:
  - correctness;
  - security and privacy: command injection, XSS, secret leakage, destructive suggestions;
  - 5.1 compatibility;
  - performance;
  - backward compatibility: every v1 switch, file and output;
  - docs accuracy: run every README command.
- **Confirm before fixing.** A second agent confirms each finding before anyone fixes it.
- **Parity.** Every v1 detection appears in v2, or is listed in CHANGELOG as an intentional false-positive fix.

Commit.

#### Phase 4: Ship-ready

1. Finalize README, CHANGELOG and CONTRIBUTING, with screenshots rendered from fixture data.
2. Rebuild the bundle and run every gate in §6 one more time.
3. Move what's worth keeping out of `UPGRADE_PROGRESS.md`, then delete it.
4. Push the branch. If you have GitHub access, open a **draft** PR with the §8 report as its description.

### 6. Gates: all must pass before you say "done"

1. **Build:** `pwsh -NoProfile -File ./build.ps1` succeeds, and `git diff --exit-code -- list-coding-agents.ps1` is clean afterwards.
2. **Lint:** `Invoke-ScriptAnalyzer -Path ./src -Recurse -Settings ./PSScriptAnalyzerSettings.psd1`, plus the same check on `./build.ps1` and the bundle, reports 0 errors and 0 warnings.
3. **Tests:** Pester shows 0 failures on pwsh 7, and also on Windows PowerShell 5.1 when running on Windows or CI. Line coverage for `src/` is at least 80%.
4. **Corpus:** 100% of positives are DETECTED and 0 negatives are DETECTED.
5. **Secrets:** the canary values appear nowhere in stdout, JSON, HTML or state.
6. **Report:** run Playwright against a fixture report whose agent names include `<img src=x onerror=alert(1)>` and `"quotes"`. Check:
   - no console errors and zero network requests;
   - the hostile names render as plain text;
   - search, sort, filters, copy, theme and privacy controls all work;
   - axe-core finds 0 serious or critical issues;
   - no horizontal scroll at 375 px;
   - every control is visible with `reducedMotion: 'reduce'`.
7. **Bundle smoke test:**
   - `pwsh -NoProfile -File ./list-coding-agents.ps1 -NoOpen -Json -OutDir <tmp>` passes on the fixture environment;
   - the same content run as a scriptblock (simulating `irm | iex`, with no `$PSScriptRoot`) also passes;
   - `-UpdateAll -WhatIf` changes nothing.
8. **Backward compatibility:** every v1 switch keeps its v1 meaning, a v1 `last-scan.json` migrates with its history intact, and extra/exclude files next to the script are still honored.
9. **Schema:** the JSON output validates against the schema.
10. **Speed:** on Windows (real machine or windows-latest fixture run), v2's wall-clock time with default switches is at most v1's. Record both numbers, and record v2's times on Linux and macOS too.
11. **CI:** green on all three operating systems. If you can't push and watch it, say plainly that CI wasn't observed.

### 7. If the budget runs short

| Tier | Contents |
|---|---|
| P0 (never skip) | Phase 1; every §2 defect; the §4 rules; gates 1-9 |
| P1 | macOS/Linux support; the new detection sources; per-channel update checks; report v2; docs; the release workflow |
| P2 | MCP overlap view; version-bump timeline; print stylesheet; GitHub-release update checks; `-CheckUpdates` reporting newer list-coding-agents releases; SessionStart hook; a GitHub Pages sample report built from fixture data (the owner turns Pages on) |

Start a lower tier only once everything above it is green, and list what you skipped.

### 8. Final report (print it, and use it as the PR description)

- **What changed,** by area, and why. List intentional behavior changes with migration notes.
- **Verification:** for every gate in §6, the exact command and its result. State plainly anything that wasn't verified, such as real Windows/winget behavior or CI.
- **Before → after numbers:**
  - analyzer warnings (55 → 0);
  - test count and coverage;
  - corpus precision and recall;
  - scan wall-clock time;
  - report size;
  - agents detected on the reference environment.
- **Known limitations,** plus a short list of follow-ups.
