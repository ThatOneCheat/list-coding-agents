# Catalog cross-check (independent)

Input: `catalog-draft.json` (66 entries). Output: `catalog-xcheck.json` (one record per entry id: `packages`, `commands`, `configDirs`, `notes`, plus an `evidence` object with the per-item proof). Scripts and raw data are in `../xcheck/`: `fetch.py`, `winget.py`, `summarize.py`, `analyze.py`, `evidence.py`, and `raw/`.

## Totals

| Item | Confirmed | Unofficial | Not found | Unverifiable | Unconfirmed |
|---|---|---|---|---|---|
| Package ids (185) | 183 | 2 | 0 | 0 | n/a |
| Commands (68) | 68 | n/a | n/a | n/a | 0 |
| configDirs, 19 entries checked | 17 confirmed | 2 partly | n/a | n/a | 47 not checked |

## How I checked (all fetched again by me; the draft's downloads were not used)

- **npm:** `registry.npmjs.org/<name>/latest`. I compared the `bin` map with the claimed commands, and read the repository, maintainers and the `deprecated` field.
- **PyPI:** `pypi.org/pypi/<name>/json`. I also downloaded each wheel and read `entry_points.txt [console_scripts]`, which is a stronger check than pyproject.
- **Homebrew:** formulae.brew.sh formula and cask JSON (binary targets, zap, old_tokens, deprecation). I read the tap formulae from `raw.githubusercontent.com/<owner>/homebrew-<tap>/HEAD/...`, and some homebrew-core `.rb` files for bin names.
- **Scoop:** raw manifests from ScoopInstaller/Main and Extras, and charmbracelet/scoop-bucket.
- **Chocolatey:** the OData `Packages()?$filter=Id eq '<id>' and IsLatestVersion` feed (Title, ProjectUrl, PackageSourceUrl, Published), plus the package page.
- **winget:** a fresh `cdn.winget.microsoft.com/cache/source.msix`, then `Public/index.db` (ids, versions, Commands). I also fetched each package's merged manifest from the winget CDN (Publisher, PackageUrl, installer hosts, PortableCommandAlias).
- **VS Code:** Marketplace `extensionquery` (filterType 7). I recorded the publisher, verified domain, installs and flags.
- **Docs:** vendor docs (Mintlify `.md` pages where available) and READMEs/pyprojects via raw.githubusercontent.com. Where curl was blocked I used WebFetch/WebSearch.

## Every NON-confirmed item

| Entry | Item | Status | Finding | Recommended action |
|---|---|---|---|---|
| zed | `choco:zed` | unofficial (wrong product) | Chocolatey `zed` is **AuthZed's SpiceDB CLI**: ProjectUrl github.com/authzed/zed, maintainer authzed, "Official command-line tool for managing SpiceDB". Chocolatey search finds no package for the Zed editor. | **Drop.** It would also cause false positives, because that package installs a `zed.exe`. |
| copilot-cli | `choco:copilot-cli` | unofficial / stale | The package exists, but it is not in the approved-latest feed and has no "Package Approved" banner. It is at v1.0.12 (2026-03-29), has 12 downloads and is maintained by steviecoaster. `choco:github-copilot-cli` (approved, 1.0.91, mu88) is the live package. | **Drop** (keep `github-copilot-cli`). |
| cursor-cli | configDirs | partly | Docs (cursor.com/docs/cli/reference/configuration.md) give the global config as `~/.cursor/cli-config.json`, `%USERPROFILE%\.cursor\cli-config.json` on Windows, or `$XDG_CONFIG_HOME/cursor/cli-config.json`. The draft lists only `~/.config/cursor-agent`, which comes from the Homebrew zap stanza. | **Fix:** add `~/.cursor` (all) and `{XDG_CONFIG_HOME}/cursor` (linux), and keep `~/.config/cursor-agent`. Note that `~/.cursor` is shared with the Cursor editor. |
| cline | configDirs | partly | The draft has no dirs. The docs (docs.cline.bot/getting-started/config.md) say "Global configuration in `~/.cline/`", with a `CLINE_DIR` override, shared by the IDE, CLI and SDK. | **Fix:** add `~/.cline` (all). |

## Confirmed, but the catalog should change (recommended fixes)

| Entry | Finding (primary source) | Action |
|---|---|---|
| hermes-agent | `hermes-agent` **is** an executable. The upstream pyproject `[project.scripts]` has `hermes`, `hermes-agent` (legacy CLI) and `hermes-acp`, and the Homebrew formula tests `hermes-acp`. The draft listed `hermes-agent` as unconfirmed. | Fix: add `hermes-agent` and `hermes-acp` to commands. |
| hermes-agent | PyPI `hermes-agent` (left out of the draft) looks built from upstream: Author "Nous Research", summary identical to the upstream pyproject, and console_scripts with upstream module names. It has no project URLs, is not mentioned in the README, and lags at 0.19.0 (formula 0.21.6). | Optional: add `pypi:hermes-agent` with verified:false. |
| kimi-cli | The wheel's console_scripts are `kimi` and `kimi-cli`. PyPI `kimi-code` (legacy alias) installs a **`kimi-code`** executable, not `kimi`. | Fix: add the `kimi-cli` command, and note that the legacy `kimi-code` executable exists. |
| openhands | PyPI `openhands-ai` has **no console_scripts**, so it does not put `openhands` on PATH. PyPI `openhands` provides `openhands` and `openhands-acp`. | Keep `openhands-ai` only as a package-presence signal, and say so in notes. |
| iflow-cli | The README banner says "iFlow CLI will be shutting down on April 17, 2026". The draft's notes do not mention it. | Keep, but mark it discontinued in notes (or verified:false). |
| windsurf | The Devin Desktop FAQ says the legacy `surf` command still ships in `~/.codeium/windsurf/bin/`. winget `Codeium.Windsurf` and Scoop `extras/windsurf` are stuck at 2.3.15. winget `CognitionAI.DevinDesktop` and choco `windsurf` are at 3.10.48. | Optional: add `surf` (ambiguous), and note that the old ids are frozen. |
| forge | The README badges point to `tailcallhq/forgecode`, and the raw README is identical under both names. | Fix the repo to `tailcallhq/forgecode` (verify). |
| amp | `choco:amp` is official (ampcode-com, sourcegraph/amp-packages) but has been **stale since 2025-07-31**. `npm:@sourcegraph/amp` says "Renamed to @ampcode/cli". `vscode:sourcegraph.amp` is flagged **unpublished**. | Keep. Note that the first two are stale or renamed and that the extension is unpublished. |
| gemini-cli | `choco:gemini-cli` is stale at 0.27.2 (2026-02-06). The `brew:gemini-cli` formula was deprecated on 2026-06-18, with replacement `antigravity-cli`. | Keep and add caveats. |
| cline / kimi-cli | The `brew:cline` formula was deprecated on 2026-05-18 for using a non-FOSS SDK. The `brew:kimi-cli` formula was deprecated on 2026-07-17, with replacement `kimi-code`. | Keep and add caveats. |
| pi, qodo | npm deprecations: `@mariozechner/pi-coding-agent` points to `@earendil-works/...`. `@qodo/command` says "no longer supported". `@qodo/gen` was renamed to `@qodo/command`. | Keep as legacy signals. |
| windsurf, blackbox-cli | VS Code `Codeium.codeium` and `Blackboxapp.blackbox` are flagged **unpublished** on the Marketplace. | Keep for detecting existing installs, and add a note. |
| grok-build | `npm:@xai-official/grok` does not appear in docs.x.ai. However, its sole maintainer is `security@x.ai`, and its version, 1.0.50, matches the x.ai-hosted cask and winget `xAI.GrokBuild` (Publisher xAI Corp.). | Keep. Optionally mark this one package verified:false. |
| goose | Scoop `extras/goose` creates only a Start-menu shortcut, with no PATH shim. | Keep, but do not treat it as evidence for the `goose` command. |
| junie | `npm:@jetbrains/junie-cli` is owned by JetBrains, but it is the older line. The README documents `@jetbrains/junie`. | Keep as legacy. |

## Surprising claims: verification

| Claim | Verdict | Primary source |
|---|---|---|
| Cursor CLI command is now `agent` | **Confirmed** | cursor.com/docs/cli/installation (`agent --version`, `agent update`). The docs never mention `cursor-agent`. `cursor-agent` is confirmed only by the Homebrew cask binary target. |
| Gemini CLI is being replaced by Antigravity CLI `agy` | **Confirmed** | Google Developers Blog, "An important update: Transitioning Gemini CLI to Antigravity CLI": Gemini CLI and the Code Assist IDE extensions stopped serving individual Pro, Ultra and free users on 2026-06-18, while **enterprise access is unchanged**. The `agy` command and `~/.gemini/antigravity-cli` come from antigravity.google/docs (getting-started, cli/install). The Homebrew `gemini-cli` formula is deprecated with replacement `antigravity-cli`. |
| Windsurf was renamed Devin Desktop | **Confirmed** | docs.devin.ai/desktop/devin-desktop-faq.md: "On June 2, 2026, Windsurf is becoming Devin Desktop", and `surf` was replaced by `devin-desktop`. Supporting evidence: cask `devin-desktop` has old_tokens [windsurf], and winget DevinDesktop's installer is hosted on windsurf-stable.codeiumdata.com. |
| Amazon Q CLI became Kiro CLI, and `q` still works | **Confirmed** | kiro.dev/docs/upgrade-guides/migrating-from-q/: "You can still continue using the q and q chat entry points". It also lists `~/.kiro` and legacy `~/.aws/amazonq`. The cask has old_tokens [amazon-q, codewhisperer]. |
| The `antigravity` cask is now the "Antigravity 2" agent platform, and the IDE is `antigravity-ide` | Confirmed | The cask JSON has homepage `antigravity.google/product/antigravity-2`. Cask `antigravity-ide` links `antigravity-ide` and `agy-ide`. |
| Kimi CLI is archived in favor of Kimi Code (`~/.kimi-code`) | Confirmed | The kimi-cli README and PyPI summary, and moonshotai.github.io/kimi-code config docs. |
| Open Interpreter is now a Rust Codex fork with commands `i` and `interpreter` | Confirmed | openinterpreter/open-interpreter README. |
| coder/mux was renamed coder/xum | Confirmed | The xum README (Mux.com trademark), and npm `mux` "Compatibility package forwarding ... to @coder/xum". |
| gh-copilot was deprecated on 2025-10-25 | Confirmed | github/gh-copilot README. |
| Continue's repo is read-only | Confirmed | The continuedev/continue README. |
| Qodo is replaced by the "Qodo Agentic Toolbox" | **Not checked** | Only the npm deprecations were verified. |

## Not covered
- configDirs for the other 47 entries.
- `pathSignatures`.
- `versionArgs`, apart from `jules version` and `amp version`, which the docs confirm.
- Whether the draft's excluded packages should be added, apart from PyPI `hermes-agent` above.
