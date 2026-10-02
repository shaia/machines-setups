# machines-setups

An opinionated developer-machine baseline for Windows and macOS. A fresh box
becomes a working development machine with a `git clone` and one command.

It started as a snapshot of two personal machines, and it is still derived
from them, but it is no longer a replica. It installs a deliberate selection
of tools and editor extensions, with the same choices on both platforms
wherever the platforms allow. It does not install whatever happened to be
installed somewhere.

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
- ripgrep, fd, bat, eza, jq, yq, fzf, zoxide, lazygit, sd, glow, tldr, btop, dust, duf, hyperfine, gping, doggo and fastfetch
- uv, and pre-commit installed through it
- VS Code with language-neutral extensions: GitLens, Error Lens, GitHub PRs, Copilot, Todo Tree, Mermaid and Draw.io among them
- on Windows: WSL 2 with Ubuntu, gsudo, PowerToys, Everything, Sysinternals, and the Terminal-Icons, PSScriptAnalyzer and WinGet modules; plus file extensions shown in Explorer and long path support

Everything else is a **profile**, chosen at install time:

| Profile | Adds |
| --- | --- |
| `cpp` | CMake, Ninja and LLVM. On Windows also Visual Studio 2026 with a curated C++ workload and GNU make. clangd, CMake Tools and LLDB extensions |
| `go` | Go, plus gopls, dlv, staticcheck and golangci-lint |
| `python` | Python 3.13 through uv (which is in core). Ruff, Pylance and debugpy |
| `web` | Node, pnpm, xh, mkcert, ESLint and Prettier |
| `dotnet` | .NET SDK 10 (LTS) and C# Dev Kit |
| `rust` | rustup with the stable toolchain, and rust-analyzer |
| `java` | Amazon Corretto 21 and the Java extension pack |
| `containers` | Docker Desktop (with WSL on Windows), kubectl, kubectx, helm, k9s, kind, stern, lazydocker, dive |
| `cloud` | AWS CLI, OpenTofu, Terragrunt |
| `ai` | Ollama, the Claude desktop app, Claude Code, Gemini CLI and Codex CLI, plus the Claude Code extension |
| `gpu` | Windows only: CUDA Toolkit and Nsight Compute |
| `lowlevel` | Windows only, pulls in `cpp`: WinDbg, x64dbg, the WDK with its Visual Studio extension and Spectre libraries, PE-bear, Dependencies, ImHex, HxD, Cutter, Binary Ninja Free, PerfView, Tracy, the Windows Performance Toolkit, System Informer, Cppcheck, sccache, NASM. Ghidra, VTune, uProf, OSR Driver Loader and Hyper-V are listed as manual steps |
| `apps` | Chrome, Arc, Obsidian, Slack, Zoom, Postman. On Windows also ShareX and WizTree |

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
  profiles/<name>.txt   winget ids, `psmodule` lines, and `requires <profile>`
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
- **Git that does not surprise you.** Pulls are fast-forward only, deleted
  remote branches are pruned, rerere and zdiff3 conflict markers are on, and
  `main` is the default branch.
- **Windows settings a build depends on.** Explorer shows file extensions, and
  long paths are on in both Windows and git, so deep build trees do not fail at
  260 characters.
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
