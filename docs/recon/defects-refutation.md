# Recon B (refuter): brief section 2 vs v1 code

Target: `list-coding-agents.ps1` v1 (1,382 lines, byte-identical to `HEAD:list-coding-agents.ps1` @ 8d05c16). While I worked, another agent moved the file to `tests/fixtures/v1/list-coding-agents.v1.ps1` and created a new root file. Both files are still byte-identical to v1, and so is every sandbox copy I ran (checked with `cmp`). I made no writes to the repo.

How I checked:
- I loaded functions out of the script with the AST, using `scratchpad/refute/load.ps1`.
- I ran the whole script on copies under `scratchpad/refute/sb*/` with a fake HOME and a `;`-separated PATH, and with `PATHEXT` set.
- `npm` and `winget` were faked as global functions, so `Get-Command` finds them (`scratchpad/refute/runner.ps1`).
- The real HOME and PATH were never touched.

Totals: items 1-20 come to **19 CONFIRMED, 1 PARTLY (#9), 0 REFUTED**. Item 21's four sub-bullets come to **3 CONFIRMED, 1 PARTLY (21c)**. Across all 24 rows that is 22 CONFIRMED, 2 PARTLY, 0 REFUTED. There are **17 new findings** after self-refutation, and 6 candidates I refuted myself.

## Verdicts on the 21 defects

| id | verdict | lines | evidence |
|---|---|---|---|
| 1 | CONFIRMED | 665-666, 687, 795, 810 | `$detected` is editor-filtered and feeds `$curNames`, `wingetOnly` and `histEntry.c`. **Ran it:** sandbox run 1 (default) showed 5 detected. Run 2 changed only `-IncludeEditors` and printed `+ new since last scan (...): windsurf`, with history `c` 5→6 and rank COLLECTOR→ENTHUSIAST. Run 3 (toggled back) printed `- gone since last scan: windsurf`. |
| 2 | CONFIRMED | 655, 703, 288, 768-771 | `Get-AgentIntel $r.Command` is called with `'(winget)'`, and `Get-ConfigDirs` returns `@()` at L288 (verified: count=0). **Ran it:** winget-only `Kiro` with a fresh `~/.kiro/sessions/today.json` was reported "never seen used" and listed under dead weight with `winget uninstall --id "Amazon.Kiro"`. |
| 3 | CONFIRMED | 768-769, 775 | `$r.Stale = $true` is unconditional, and only a `LastUsed` within 60d flips it. **Ran it:** `goose.exe` and `windsurf.cmd` had no config dir, so both got "never seen used" and an uninstall suggestion. |
| 4 | CONFIRMED | 655 (vs 534-539) | `Kind='cli'` is hardcoded, and `Get-Kind` is never called for winget rows. Called directly, `Get-Kind -Name Cursor` returns `editor`. **Ran it:** the winget row `Cursor  Anysphere.Cursor` (score 6) appeared under "Installed via winget" *without* `-IncludeEditors`. |
| 5 | CONFIRMED | 735 | `$p.Value.latest -ne $r.Version` is plain inequality. **Ran it:** installed `0.50.0-alpha.1` with npm latest `0.49.0` printed `codex 0.50.0-alpha.1 -> 0.49.0  npm i -g @openai/codex@latest` (a downgrade). Nuance: the winget path (L747-758) does no comparison at all and trusts winget's Available column, so the "string compare" applies to npm only. |
| 6 | CONFIRMED | 726-762, 888-895 | The success message depends only on `$updates.Count`. **Ran it:** with neither npm nor winget present, `-CheckUpdates` printed `== Everything is up to date ==` for 5 agents. Also, an npm JSON parse failure is swallowed at L741. |
| 7 | CONFIRMED | 737, 757, 900-913 | `Read-Host` is at L902, and `Invoke-Expression $r.UpdateCmd` at L907. There is no exit-code check (the try/catch can't see native failures) and no re-probe ("re-run the scan to verify"). **Ran it:** `Invoke-Expression 'winget upgrade --id "Foo.Bar$(Write-Output INJECTED-RAN)"'` executed the subexpression. Scoped npm names survive IEX intact (`@openai/codex@latest`). |
| 8 | CONFIRMED | 770-773, 1011 | `"Remove-Item `"$($r.Source)`""` is suggested for any .exe/.cmd/.bat/.ps1. That includes npm shims that have no Package (it removes the shim only) and `windsurf.cmd`. **Ran it (worse than stated):** the string uses `-Path` semantics, so for `a[bc].exe` it targets `ab.exe` and `ac.exe` instead (`-WhatIf` output). L772 also builds `winget uninstall "<basename>"` as a name query, not `--id`. |
| 9 | PARTLY | 396-407, 709-723 | **Confirmed:**<br>- a `pwsh -s -NoLogo -NoProfile` process per probe (seen in `ps`);<br>- sequential probes, each costing up to 8.1 s;<br>- `2>$null` loses a stderr-only version (`stderrver.exe` returned empty).<br>**Not reproduced:** the process leak. On Linux pwsh 7.6, `Remove-Job -Force` killed both the `sh` and `sleep` grandchildren. Windows was not tested. |
| 10 | CONFIRMED | 633-652, 747-753, 757, 771 | `-split '\s{2,}'` on a winget-style truncated row gave `pkgName=[OpenAI Codex CLI - lightweigh… OpenAI.Codex] id=[0.46.0]`. A fully truncated row gave `id=[winget]`. This assumes winget separates a full-width cell with a single space; it was a synthetic test because winget isn't available here. A second `winget upgrade` call happens at L747. Truncated IDs are passed to `--id` with no check. |
| 11 | CONFIRMED | 701-702 | A size is only taken for npm PkgDir or `Source -match '\.exe$'`. **Ran it:** `windsurf.cmd` showed `?`, and the winget rows Cursor/Kiro showed `?`. The scoop/pipx shim `.exe` case is from reading the code. See also N1: claude's size came from the shadowed npm package, not the running exe. |
| 12 | CONFIRMED | 1079, 1126 | `.bar{...opacity:0;animation:rise ...}`. The reduce block lists `.eyebrow,.meta,.stat,.channel,.unit,.search`, but not `.bar`. `.search` gets `opacity:1`, but its parent `.bar` stays at 0, so the whole subtree, including the share button, is invisible. `.bar` is the only `opacity:0` rule missing from the reset (grepped the generated HTML). |
| 13 | CONFIRMED | 1021, 1043, 1357 (also 1133) | The generated HTML contained `"hostn":"ALICE-WORK-LAPTOP"` in `#cardData`, and the footer draws `D.hostn`. There is no opt-out. On Linux/macOS `$env:COMPUTERNAME` is unset, so it's blank there. |
| 14 | CONFIRMED | 1053-1055, 1257-1261 | The generated HTML links `fonts.googleapis.com/css2?family=Syne...`. `document.fonts.load(... Syne)` adds fetches. |
| 15 | CONFIRMED | 570, 669, 931, 1378 | **Ran it:** `Get-Content -Raw script \| Invoke-Expression` in a sandbox. `$PSScriptRoot` is `''`, so `Join-Path` fails ("empty string") and `Out-File -LiteralPath $null` fails. No state, JSON or HTML was written, and it printed `HTML report: ` with a blank path. The extra/exclude lists are silently ignored too. |
| 16 | CONFIRMED | 824, 932, 1379 | On pwsh 7, the files start `7b`/`5b`/`3c` (no BOM). The 5.1 BOM comes from documented behavior; 5.1 isn't runnable here. Python `json.load` fails with "Unexpected UTF-8 BOM", and Node `JSON.parse` fails with "Unexpected token '﻿'" (both run). |
| 17 | CONFIRMED | 273, 362, 380, 405, 685, 713, 741, 825, 1037, 1046, 1381 | PSScriptAnalyzer reports exactly these 11 PSAvoidUsingEmptyCatchBlock lines, and 55 warnings in total, which matches the brief. There is no `diagnostics` array in the JSON. |
| 18 | CONFIRMED | 277-283, 832-833, 1001, 1022, 1043 | `Format-Size 0` returns `<0.1 MB`. **Ran it:** an empty fleet printed `0 detected ... <0.1 MB on disk` and `dead weight: <0.1 MB`. The `'none'`/`'0 MB'` fallbacks never trigger, and the share card JSON has `"reclaim":"\u003c0.1 MB"`. Side note: `$diskLabel` is written unencoded at L1133/L1137 (`<b><0.1 MB</b>`), which renders as text but isn't valid HTML. |
| 19 | CONFIRMED | 71-79, 1381 | There is no `-NoOpen`. `Invoke-Item` runs whenever `-not $NoHtml`, and `-NoHtml` also suppresses writing the file. |
| 20 | CONFIRMED | README.md | None of `-UpdateAll`, `-SkipWinget`, `agents-exclude.txt`, MCP, logged-in, PATH conflicts, dead weight, fleet rank, trend or share card appear. "how to run it" has no `Unblock-File` / execution-policy step. |
| 21a | CONFIRMED | 82-91 | There are two consecutive "Lexicons" header blocks. |
| 21b | CONFIRMED | 530-531 | Both return `'standalone installer'`, so L530 is dead code. |
| 21c | PARTLY | 528-530 | The dots are unescaped: `Get-Method 'C:\x\_cargo\bin\f.exe'` returns `cargo`, and `...\xbun\bin\...` returns `bun`. But the `.local` case at L530 has no effect, because L531 returns the same value anyway. |
| 21d | CONFIRMED | 810, 819, 925, 1018 | `'yyyy-MM-dd HH:mm'` and `.ToString('s')` carry no offset. See N12: the L810/819/1018 formats are also calendar-dependent on the current culture. |

Item 21 sub-bullets: 3 CONFIRMED, 1 PARTLY. The PARTLY is 21c, where the `.local` dot is moot.

## New findings

Ordered by severity. Each finding passed my own refutation attempt.

**N1 (high): npm metadata is attached by command name even when the PATH winner isn't the npm shim** (L599-604)
- **Scenario:** native `claude.exe` sits first on PATH, and an old npm `@anthropic-ai/claude-code` is still installed but shadowed. This is the common npm→native migration.
- **What goes wrong:** the row gets the npm package's `Method`, `Version`, `Package` and `PkgDir`. As a result, the version, size, update command (`npm i -g` updates the copy that never runs), `-UpdateAll` and the uninstall command all describe the shadowed install.
- **Verified:** sandbox run 1 showed `claude 1.0.3 ... Source .../local/claude.exe` under "Installed via npm". The running exe reports `2.0.5`. A run without npm probed it as `2.0.5`, and the probe cache confirms that.

**N2 (high): `-Json` export changes shape with the count** (L919, L932)
- `@($export) | ConvertTo-Json` unrolls through the pipeline.
- **Verified:** with 1 agent the root is a JSON *object* (Python saw `dict`). With 0 agents `coding-agents.json` is **0 bytes**, and `json.load` raised "Expecting value".

**N3 (medium): `$KnownCli` contains common non-agent tool names** (L96-107, contradicting the L94-95 comment)
- Affected names: `goose` (pressly/goose DB migrations), `copilot` (AWS Copilot CLI), `mux`, `hermes` (Hermes JS engine) and `kilo` (editor).
- Each scores 9 (6 for kilo) on the bare name, so it is DETECTED.
- **Verified:** a sandbox `goose.exe` printing `goose version v3.24.1` was DETECTED and suggested as dead weight via `Remove-Item`.
- The winget display name `Claude` (Claude Desktop, `Anthropic.Claude`) scores 12 and is reported as a coding agent whenever Claude Code isn't on PATH.
- **Refutation tried:** Block's goose and GitHub's copilot really are agents. That makes these genuine collisions, so they belong in the ambiguous tier, like `sg`/`src`.

**N4 (medium): MCP server counts are inflated** (L313-337)
- The TOML regex `\[mcp_servers\.[^\]\.]+` has no closing `\]`, so `[mcp_servers.x.env]` subtables count as servers. Codex `config.toml` is affected.
- **Verified:** 2 servers with env tables showed `MCP 4` in the sandbox. A direct call with 2 servers, one of which has an env table, returned 3.
- `~/.claude.json` sums per-project duplicates: 1 server in user scope plus 2 projects returned 3.
- VS Code-style `"mcp":{"servers":{a,b,c}}` returned 1.

**N5 (medium): Another app's data is attributed to the CLI** (L298-299)
- Generic `%APPDATA%\<name>` and `%LOCALAPPDATA%\<name>` mean that, for `claude`, Claude Desktop's folder is read.
- Its recent writes set Claude Code's `LastUsed`, and its `claude_desktop_config.json` `mcpServers` adds to the MCP count.
- **Verified with APPDATA pointed at a fixture:** `~/.claude` untouched for 200 days still gave LastUsed=today and Mcp=3.

**N6 (medium): The trend is never recorded on machines without winget** (L630-632, L799-814)
- Every such run is "partial", and the history entry is added only in the full-scan branch.
- This hits Linux/macOS after the port, plus Windows Server, LTSC and Sandbox without App Installer.
- The banner "partial scan: winget not found" also prints on every run.
- **Verified:** sandbox runs sb2 (1 agent) and sb3 (3 runs) still had `history: []`.

**N7 (medium): A winget update can be attached to the wrong package** (L754-758)
- `$k -match [regex]::Escape($r.Name)` is a substring match over hashtable order.
- **Verified with an exact replica:** a `Claude` row (`Anthropic.Claude`, up to date) with only `Anthropic.ClaudeCode` upgradable got `Latest=2.1.0  winget upgrade --id "Anthropic.ClaudeCode"`. `-UpdateAll` would upgrade a different package.

**N8 (medium-low): PATH conflicts count the same install more than once** (L509-511)
- Each extension variant in the *same* shadowing dir is appended separately.
- **Verified:** native claude plus an npm install produced `shadows=2: claude.cmd, claude.ps1`, so the report says "shadowed ×2" for one npm install.

**N9 (low-medium): `-SkipWinget` doesn't skip winget during `-CheckUpdates`** (L744, no `$SkipWinget` check)
- **Verified:** `-SkipWinget -CheckUpdates` printed `checking winget for updates...`. That is the slow call the switch exists to avoid.

**N10 (low): Generated commands are PowerShell double-quoted strings** (L737, L757, L771-773)
- `$(...)`, `$var` or a backtick in a winget ID or path is evaluated by IEX (L907), or when the user pastes the copied command (L950, L1011).
- `Remove-Item "<path>"` treats `[ ]` as wildcards and hits other files.
- **Verified:** both, see #7 and #8.
- Likelihood is low, since it needs an odd ID or path. Fix by single-quote escaping plus `-LiteralPath`, or argument arrays.

**N11 (low): An empty previous baseline hides the diff** (L692 `if ($prevNames.Count)`)
- After a scan that found 0 agents, the first agent installed is never shown as "+ new". It also conflates "no state file" with "zero agents".
- **Verified:** sb3 (persisted `agents: []`) plus `aider.cmd` produced no "+ new" line.

**N12 (low): State dates use the current culture's calendar** (L810, L819, L1018)
- `Get-Date -Format 'yyyy-MM-dd'` printed `2569-10-11` under th-TH, `1448-04-30` under ar-SA and `1405-07-19` under fa-IR.
- The JSON `lastUsed` uses invariant `'s'` (`2026-10-11T...`), so files mix calendars.
- v2's migration of v1 `last-scan.json` must not assume Gregorian, and v2 must write with InvariantCulture.
- **Verified:** set `[cultureinfo]::CurrentCulture` and ran it.

**N13 (low): Override list gaps** (L573-574, L644-660)
- `agy   # note` is stored verbatim, so the entry silently never matches.
- `agents-extra.txt` is never consulted for winget rows, although `agents-exclude.txt` is (L647).
- **Verified:** in sandbox sb6, `agy.cmd` with an inline comment was not detected, and the same-file entry `blackbox2` was.

**N14 (low): "logged in" false positives** (L350-351, L361, L370, L379)
- Any file name containing `token` (for example `tokenizer.json`), or a credential key present with a null value, sets Auth.
- **Verified:** a 200-day-old `~/.aider/cache/tokenizer.json` plus `{"apiKey": null}` gave Auth=True.

**N15 (low, porting): Path regexes only handle backslashes**
- Affected lines: L121-135 PathSignatures, L496, L524-530 `Get-Method`, L536 `Get-Kind`.
- Even with PATH splitting fixed, on Linux/macOS:
  - `/home/u/.local/bin/claude` loses the path-signature bonus (9 vs 12 on Windows);
  - npm, pipx and cargo paths all map to `standalone installer`;
  - editors are never classified by path.
- **Verified:** called the functions directly.

**N16 (low, Windows): A drive-root PATH entry becomes drive-relative** (L486)
- `TrimEnd('\')` turns `C:\` into `C:` (verified). PowerShell resolves `C:` as the current directory on drive C, so the scan reads the cwd instead of the root.
- The drive semantics are Windows-only, from docs; not runnable here.

**N17 (low): The probe cache is never pruned** (L678, L720, L823)
- Keys are `path|mtimeTicks`, so every agent upgrade and every removed exe leaves a permanent entry in `last-scan.json`.
- **Verified:** read the code. The fixture accumulated keys across runs.

Code-reading only (Windows, not runnable here): L525 maps every `\WindowsApps\` path to `winget`, but that folder also holds Microsoft Store app-execution aliases. L772 then suggests `winget uninstall "<basename>"`, a fuzzy name query. I'm listing this as unverified, not as a numbered finding.

## Candidates I refuted

- **PS7 `ConvertFrom-Json` turning stored `d`/`date` into DateTime and breaking same-day dedup.** Refuted. Newtonsoft only converts strings with `T` at index 10. Sandbox run 2 replaced the same-day entry correctly (one history row, `c` 5→6).
- **Culture-specific `'{0:N1}'` (de-DE `5,2 MB`, ar-SA `5٫2 MB`) breaking output.** Refuted as a bug. `Format-Size` output is display-only, and JSON and history store raw doubles serialized invariantly. `data-count` values are ints interpolated invariantly.
- **HTML, attribute or JS injection.** Refuted:
  - every data value goes through `Enc` (`HtmlEncode` also encodes `"` and `'`);
  - the embedded JSON escapes `<` (`\u003c`), so `</script>` and `<!--` can't break out;
  - the canvas uses `fillText`.
  - The only unencoded value is `$diskLabel` (#18 note).
- **`@scope/pkg` mangled by splatting under Invoke-Expression.** Refuted. The arguments arrive intact.
- **Single-element unrolling in history, card or trend JSON.** Refuted. These use `-InputObject @(...)` or array-typed properties. Only the `-Json` export is affected (N2).
- **Version-probe grandchild survives `Remove-Job`.** Not reproduced on Linux (see #9).

## Artifacts

- `scratchpad/refute/load.ps1`: AST loader for v1 functions and lexicons.
- `scratchpad/refute/runner.ps1`: sandbox runner with fake npm/winget, PATH and PATHEXT.
- `scratchpad/refute/sb1..sb6/`: fixtures, plus the generated `last-scan.json`, `coding-agents.json` and `coding-agents.html`.
- `scratchpad/refute/probe/`: `hang.exe` and `stderrver.exe` for the #9 tests.
