# Recon C: coding-agent catalog draft

The catalog is in `catalog-draft.json`. It has 66 entries: 47 CLIs, 12 editors or desktop apps, and 7 extension-only products. It lists 68 command names and 185 package ids, with 379 source claims. `gen_catalog.py` regenerates the JSON.

## How I verified the claims (all primary sources)
- **npm:** `registry.npmjs.org/<pkg>/latest`. I checked each name and its `bin` map. I also read maintainers and repository fields for packages whose ownership was in doubt.
- **PyPI:** `pypi.org/pypi/<pkg>/json`.
- **Homebrew:** the `formulae.brew.sh` API, both formula and cask JSON. I also read the full `cask.json` to find renames (`old_tokens`), linked binaries and zap paths. I took most macOS config dirs from cask zap stanzas.
- **winget:** I could not use the GitHub API (blocked in this session). Instead I downloaded the official community source index (`cdn.winget.microsoft.com/cache/source.msix`, then `Public/index.db`). From it I read the PackageIdentifiers, the latest versions and the `Commands` aliases. The URLs in `sources` are the matching `winget-pkgs/tree/master/manifests/...` directories.
- **Scoop:** raw manifests in ScoopInstaller/Main and Extras. **Chocolatey:** `community.chocolatey.org/packages/<id>`, with the page title checked. **VS Code:** the Marketplace `extensionquery` API.
- **Repos and docs:** official GitHub READMEs, fetched raw. Old repo names redirected, which showed the renames. I also used vendor docs pages.

## Renamed or superseded, and candidates that turned out different
- **Windsurf is now Devin Desktop.** Cask `devin-desktop` has `old_tokens: ["windsurf"]`. winget has both `Codeium.Windsurf` and `CognitionAI.DevinDesktop`. Cognition also ships a separate **Devin CLI** (`devin`).
- **Amazon Q Developer CLI is now Kiro CLI.** Cask `kiro-cli` has old tokens `amazon-q` and `codewhisperer`. `q` and `q chat` still work.
- **Gemini CLI is being replaced by Antigravity CLI (`agy`).** The Homebrew `gemini-cli` formula was deprecated on 2026-06-18, with cask `antigravity-cli` as the replacement. A Google developer blog post confirms the transition. `agy` is now the CLI. The IDE is a separate product, `antigravity-ide` (commands `antigravity-ide` and `agy-ide`). The `antigravity` cask is now the "Antigravity 2" agent-platform app.
- **Kimi CLI (Python, `kimi-cli`) is archived.** It is replaced by **Kimi Code CLI** (npm `@moonshot-ai/kimi-code`, config `~/.kimi-code`). Both use the `kimi` command.
- **Grok:** xAI now has an official **Grok Build** (`grok`, `~/.grok`, cask `grok-build`, winget `xAI.GrokBuild`, npm `@xai-official/grok`). superagent-ai/grok-cli is a separate community project, with the same command and dir, published on npm as `grok-dev`.
- **coder/mux is now coder/xum.** The `xum` and `mux` bins come from `@coder/xum`. npm `mux` is a compatibility package.
- **Amp:** npm `@sourcegraph/amp` was renamed to `@ampcode/cli`.
- **Pi:** `@mariozechner/pi-coding-agent` is deprecated in favor of `@earendil-works/pi-coding-agent`. The repo moved from badlogic/pi-mono to earendil-works/pi.
- **opencode:** the repo moved from sst/opencode to anomalyco/opencode. **goose:** the repo moved from block/goose to aaif-goose/goose.
- **Cursor CLI:** the primary command is now **`agent`**. `cursor-agent` is still linked by the Homebrew cask.
- **Qodo:** `@qodo/gen` became `@qodo/command`, and both are now deprecated. They are replaced by the Qodo Agentic Toolbox (`get.qodo.ai`), whose command name is not documented.
- **Open Interpreter** is now a Rust fork of Codex, installed by script, with commands `interpreter` and `i`. PyPI `open-interpreter` is the legacy version.
- **Continue:** the repo is read-only, with a final 2.0.0 release. The CLI command is `cn`.
- **gh-copilot** was deprecated on 2025-10-25 in favor of Copilot CLI.
- **MiMo:** this is Xiaomi **MiMo Code** (npm `@mimo-ai/cli`, command `mimo`).
- **jcode:** this is 1jehuang/jcode, a Rust project. PyPI `jcode` and npm `jcode` are unrelated.
- **Not found as a CLI:** Roo Code (extension only), Zencoder (extension only; the docs mention a "Zen CLI" with no install details), Trae CN (no launcher documented) and Factory desktop (no `factory` command documented).
- **Trae Agent** (`trae-cli`, bytedance/trae-agent) is real but installs from source only.

## v1 names I could not confirm as executables
`factory`, `trae-cn`, `roo-code`, `zencoder`, `continue-cli` and `hermes-agent`. The last one is only a bin of the unofficial npm bridge. They are in `notes` and not in `commands`.

## Packages I was unsure about and left out
- **npm `@vibe-kit/grok-cli`** (bin `grok`). It is probably the earlier superagent grok-cli, but no primary source links them.
- **npm `@blackbox_ai/blackbox-cli`** (bin `blackbox`, repo llmcod/blackbox_cli). The official docs do not mention it, and the docs' `@blackbox/cli` returns 404.
- **npm `hermes-agent`** describes itself as an "Unofficial npm bridge". **PyPI `hermes-agent`** has no project URLs tying it to Nous Research.
- **npm `kimi-code`** and **`grok-cli`** (whitesmith) are claude-code proxy wrappers, not the vendors' agents.
- npm `openhands` and `plandex` are security placeholders.

## Packages included with caveats
- **PyPI `openhands-ai`** is the main OpenHands server package; the CLI is `openhands`.
- **PyPI `kimi-code`** is an archived alias of the legacy kimi-cli.
- **Chocolatey `amp` and `copilot-cli`** look stale.
- Homebrew deprecated the **`gemini-cli`**, **`kimi-cli`** and **`cline`** formulae.
- **npm `@xai-official/grok`** is maintained by `xai-security <security@x.ai>`, but the docs page only shows the curl installer.

## Command-name collisions with non-agents (relevant to `ambiguous`)
- `sg`: ast-grep. npm `@ast-grep/cli` has bins `sg` and `ast-grep`, and Scoop `ast-grep` has bin `sg.exe`.
- `src`: Sourcegraph src-cli (npm `@sourcegraph/src`, bin `src`) and Homebrew `src`, which is ESR's revision control tool.
- `forge`: Foundry (Homebrew `foundry`) and Homebrew formula `forge` (arrayfire). ForgeCode (antinomyhq) is real, so its entry is marked ambiguous.
- `q`: Scoop main/q (harelba) and Homebrew `q` (a DNS client).
- `goose`: Pressly goose (Homebrew `goose`, winget `Pressly.Goose`).
- `amp`: the amp.rs editor (Homebrew `amp`).
- `copilot`: AWS Copilot CLI (Homebrew `copilot`, winget `Amazon.CopilotCLI`).
- `warp`: Scoop main/warp (warp-packer) and Chocolatey `warp` (Cloudflare WARP).
- `grok`: Homebrew `grok` (jordansissel), plus two grok agents.
- `cbc`: the COIN-OR solver (Homebrew `cbc`).
- `blackbox`: StackExchange blackbox (Homebrew).
- Other collisions noted in the entries:
  - `agent` (Cursor and Grok Build)
  - `kimi` (two Moonshot agents)
  - `kilo` (antirez's editor)
  - `hermes` (Hermes JS engine)
  - `mux` (Mux.com)
  - `acli` (Appfire ACLI)
  - `i`, `pi` and `vibe` (short or common words)

## Caveats
- `versionArgs` defaults to `--version` unless docs say otherwise. Amp and Jules use `version`. Some tools' version flags are undocumented.
- `configDirs` taken from Homebrew zap stanzas are macOS-sourced. I put home dot-dirs (for example `~/.factory` and `~/.devin`) under `all`, and `~/Library/Application Support` paths under `macos`.
- `verified` is true for every entry: every command and package listed has a source URL. The 12 entries with `commands: []` (editors and extensions) can only be detected through packages or config dirs.
- Not added, but worth considering: winget `ZhipuAI.ZCode` (Z Code), cask `void` (Void editor), `TabNine.tabnine-vscode`, and cask `zed-delta` (Delta).
