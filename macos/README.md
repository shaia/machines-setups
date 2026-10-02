# macOS

```sh
git clone <this repo> ~/development/machines-setups
~/development/machines-setups/macos/install.sh --dry-run --profile go,python   # read it first
~/development/machines-setups/macos/install.sh --profile go,python
```

See the [root README](../README.md) for the profiles and the reasoning behind
them. This file covers what is specific to macOS.

## Layers

Preflight always runs. It checks for the Xcode Command Line Tools and installs
Homebrew if it is missing. Then five layers run:

| Layer | Does |
| --- | --- |
| `packages` | `brew bundle --no-upgrade` for `profiles/core.Brewfile` and each selected profile's Brewfile |
| `zsh` | Installs oh-my-zsh and makes zsh the login shell |
| `dotfiles` | Backs up, then symlinks, `.zshrc`, `.zprofile`, `.gitconfig`, `.config/git/ignore` and `.config/starship.toml`. Also `.config/git/delta.gitconfig` once delta is installed |
| `tooling` | `go install` tools, npm globals, `uv python install`, and `rustup default stable` |
| `extensions` | VS Code extensions from `common/profiles/` |

## Things worth knowing

**bash 3.2.** The script targets the bash that macOS ships. That rules out
`mapfile`, `${var,,}` and associative arrays. Sets of layers and profiles are
space-padded strings, because bash 3.2 errors on `"${empty[@]}"` under
`set -u`, and `--skip` can empty a set.

**Apple Silicon and Intel.** `.zprofile` looks for Homebrew in both
`/opt/homebrew` and `/usr/local`. `.zshrc` uses `$HOMEBREW_PREFIX`, so nothing
hardcodes either path.

**oh-my-zsh for plugins, starship for the prompt.** `ZSH_THEME` is empty and
starship is initialised near the end of `.zshrc`.
zsh-autosuggestions and zsh-syntax-highlighting come from Homebrew. Syntax
highlighting must be sourced last, so it is.
oh-my-zsh is installed with `KEEP_ZSHRC=yes`. Without that, the installer
overwrites the `.zshrc` this repo links.

**The font is installed, not selected.** iTerm2 does not pick fonts up
automatically. Set JetBrainsMono Nerd Font under Settings › Profiles › Text,
or the prompt shows boxes where its glyphs should be.

**Node is the current release, not LTS.** Homebrew's `node` formula tracks the
current release, and the LTS formulae are keg-only. Windows gets LTS because
that is what winget ships.

**Git uses https.** The old personal snapshot rewrote every `github.com` URL to
ssh. A new machine has no ssh key yet, and that rewrite broke `git clone`
until it did. If you prefer ssh, put the rewrite in `~/.gitconfig-local`.

**A trap.** `git config --global` writes to `~/.gitconfig`, which is a link
into this repo. So `gh auth setup-git` and `git lfs install` add their
sections **to the repo**. Move them into `~/.gitconfig-local`.

**Not verified on a Mac.** The script was rewritten on Windows. It passes
`bash -n`, and argument parsing and the dotfiles, tooling and extensions layers
were exercised in dry-run mode under Git Bash against a scratch `$HOME`. Every
Homebrew formula and cask name resolves on formulae.brew.sh. Run `--dry-run`
first on a real Mac.
