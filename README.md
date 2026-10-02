# machines-setups

An opinionated developer-machine baseline for Windows and macOS. A fresh box
becomes a working development machine with a `git clone` and one command.

It installs a deliberate selection of tools and editor extensions: a core
every machine gets, plus profiles you pick per machine. The choices are the
same on both platforms wherever the platforms allow.

```sh
# macOS
git clone <this repo> ~/development/machines-setups
~/development/machines-setups/macos/install.sh --dry-run --profile go,web   # read it first
~/development/machines-setups/macos/install.sh --profile go,web
```

```powershell
# Windows
git clone <this repo> $HOME\development\machines-setups
cd $HOME\development\machines-setups\windows
powershell -ExecutionPolicy Bypass -File .\install.ps1 -DryRun -Profile go,web   # read it first
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Profile go,web
```

## Core and profiles

Every machine gets **core**, which contains:

- Warp as the terminal (iTerm2 and Windows Terminal stay configured too)
- git, gh, delta, difftastic and act
- the starship prompt with a Nerd Font
- ripgrep, fd, bat, eza, jq, yq, fzf, zoxide, lazygit, yazi, sd, glow, tldr, btop, dust, duf, hyperfine, gping, doggo and fastfetch
- uv, and pre-commit installed through it
- VS Code with language-neutral extensions: GitLens, Error Lens, GitHub PRs, Copilot, Todo Tree, Mermaid and Draw.io among them
- on Windows: WSL 2 with Ubuntu and VS Code's Remote WSL extension, gsudo, PowerToys, EarTrumpet, Everything, Sysinternals, and the Terminal-Icons, PSScriptAnalyzer and WinGet modules; plus file extensions shown in Explorer and long path support

Everything else is a **profile**, chosen at install time:

| Profile | Adds |
| --- | --- |
| `cpp` | CMake, Ninja and LLVM. On Windows also Visual Studio 2026 with a curated C++ workload and GNU make. clangd, CMake Tools and LLDB extensions |
| `go` | Go, plus gopls, dlv, staticcheck and golangci-lint |
| `python` | Python 3.13 through uv (which is in core). Ruff, Pylance and debugpy |
| `web` | Node, pnpm, xh, mkcert, Bruno, HTTP Toolkit, ESLint and Prettier |
| `dotnet` | .NET SDK 10 (LTS) and C# Dev Kit |
| `rust` | rustup with the stable toolchain, and rust-analyzer |
| `java` | Amazon Corretto 21 and the Java extension pack |
| `containers` | Docker Desktop (with WSL on Windows), kubectl, kubectx, helm, k9s, kind, stern, lazydocker, dive |
| `cloud` | AWS CLI, OpenTofu, Terragrunt |
| `ai` | Ollama, the Claude desktop app, Claude Code, Gemini CLI and Codex CLI, plus the Claude Code extension |
| `gpu` | Windows only: CUDA Toolkit and Nsight Compute |
| `lowlevel` | Windows only, pulls in `cpp`: WinDbg, x64dbg, the WDK with its Visual Studio extension and Spectre libraries, PE-bear, Dependencies, ImHex, HxD, Cutter, Binary Ninja Free, PerfView, Tracy, the Windows Performance Toolkit, System Informer, Cppcheck, sccache, NASM, and VS Code's Hex Editor. Ghidra, VTune, uProf, OSR Driver Loader and Hyper-V are listed as manual steps |
| `apps` | Chrome, Arc, Obsidian, Slack, Zoom. On Windows also ShareX and WizTree |

`all` selects every profile. A run with no profile installs core and lists
the profiles.

## Layout

```text
common/                 shared by both platforms
  git/                  gitconfig, delta.gitconfig, global ignore
  starship.toml         the prompt
  profiles/<name>.txt   VS Code extensions, go tools, npm globals, uv Pythons and uv tools
macos/
  install.sh
  profiles/<name>.Brewfile
  dotfiles/             zshrc, zprofile
windows/
  install.ps1
  profiles/<name>.txt   winget ids, plus `psmodule`, `requires <profile>` and Windows-only `vscode` lines
  vsconfig/<name>.vsconfig  Visual Studio components a profile adds (cpp, lowlevel)
  dotfiles/powershell/  profile.ps1, shell-ux.ps1
```

Each profile has two halves. The platform half is a Brewfile or a winget list.
The common half holds the extensions and language tools, which are the same on
both platforms. **To add a profile**, create one file or both under the same
name. Both installers discover profiles from the file names, so nothing else
needs registering. To add a tool to an existing profile, add one line.

## The opinions, and why

- **Warp is the terminal, starship the prompt.** starship is configured once in
  `common/`, so the prompt reads the same in Warp, VS Code and any other terminal.
  Warp brings its own completions, Ctrl+R history search, autosuggestions and
  syntax highlighting, so the shell profiles skip their own versions of those
  inside Warp (detected through `TERM_PROGRAM`) and keep them everywhere else.
- **uv in core.** Python-based developer tools such as pre-commit install with
  `uv tool install` on every machine, without needing the python profile.
- **uv for Python, nothing else.** No conda and no python.org installers. uv
  installs interpreters, makes virtual environments and runs tools, faster than
  the alternatives and without a base environment leaking into every shell.
- **clangd for C and C++.** It gives the same language features on every
  platform and compiler, driven by `compile_commands.json`. Microsoft's
  IntelliSense is not installed.
- **OpenTofu, not Terraform.** One infrastructure-as-code CLI, and the one
  that stays open source.
- **Bruno over Postman, HTTP Toolkit over Fiddler.** Bruno keeps API collections
  as plain files in the repo, with no account and no cloud sync. HTTP Toolkit is
  the open-source successor to the free Fiddler, which no longer gets updates.
- **Git that does not surprise you.** Pulls are fast-forward only, deleted
  remote branches are pruned, rerere and zdiff3 conflict markers are on, and
  `main` is the default branch.
- **Windows settings a developer wants.** Explorer shows file extensions,
  hidden files and the full path. The taskbar offers End Task, and Start search
  stays local. Long paths are on in both Windows and git, so deep build trees
  do not fail at 260 characters. Developer Mode and Windows' own inline `sudo`
  are on. Taste and security-posture settings (dark mode, Do Not Disturb,
  Remote Desktop, Edge policies) are left alone.
- **Nothing elevates itself, and nothing is upgraded.** Package installs skip
  anything already present, and every layer is safe to re-run.

## Conventions both platforms follow

- **Layers.** Each installer is split into named layers, selectable with
  `--only` / `--skip` (`-Only` / `-Skip`). Each layer is idempotent: it inspects
  state, skips what is satisfied, and says so. `--dry-run` / `-DryRun` prints
  every mutating command and runs none.
- **The default shell.** Each installer is written for the shell the OS ships:
  bash 3.2 on macOS and Windows PowerShell 5.1 on Windows. On a fresh machine
  there is nothing else.
- **Dotfiles are symlinked, not copied.** Editing `~/.gitconfig` or the shell
  profile edits this repo. Anything a linked file replaces is backed up first
  to `~/.dotfiles-backup-<timestamp>`.
- **Check, apply, check again.** Every step is checked before it runs and
  re-checked after, so a change that did not stick is reported as a failure
  rather than trusted. The run ends with a summary:

  | Status | Means |
  | --- | --- |
  | already fine | Nothing needed doing |
  | changed | Applied, and the re-check confirmed it |
  | failed | Applied, but the re-check still fails. The script exits 1 |
  | flagged | Best-effort work that could not be done here (no virtualization for WSL, Terminal never launched). The run continues |
  | manual | Needs something the script deliberately does not do, such as elevation. The commands are printed together at the end |

  A second run on a configured machine reports nothing changed.
- **Retries, one run at a time, and a log.** Network installs retry twice,
  after 5 and 15 seconds. A second copy started while one runs exits with
  code 3. Every run, dry runs included, is logged to
  `~/.machines-setups/logs/install-<timestamp>.log`.
- **Tested on clean machines.** [`.github/workflows/ci.yml`](.github/workflows/ci.yml)
  runs both installers on fresh GitHub-hosted Windows and macOS runners, on
  every push, every pull request and weekly. Each job installs core plus go,
  python and web, runs a second time and requires it to change nothing, then
  checks the toolchains from a fresh shell.

## Secrets and personal config

The root [`.gitignore`](.gitignore) is the boundary. Nothing credential-bearing
is checked in: no `~/.ssh`, no `gh` hosts file, no keys, no `.netrc`, no AWS
credentials. Every pattern matches at any depth, so check with
`git check-ignore -v <path>` rather than assuming.

Nothing personal is tracked either. Identity, secrets and employer-specific
setup live in optional files under `$HOME`. The installers detect these files
but never create them:

| File | Holds |
| --- | --- |
| `~/.gitconfig-local` | Git identity, credential helpers, URL rewrites, org-specific `includeIf` rules |
| `~/.gitconfig-work` | A work identity, used for repos under `~/work/` or `~/development/work/` |
| `~/.zshrc.local` | macOS per-machine env: API keys, `GOPRIVATE`, internal registries |
| `~/.powershell.local.ps1` | The same for PowerShell on Windows |

The rule for anything new is simple. If a setting would be wrong on another
developer's machine, it belongs in a local override, not here. That covers a
hardcoded home path, a private org, an internal registry and a personal app.
