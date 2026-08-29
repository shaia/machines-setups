# macOS bootstrap

A reproducible snapshot of a macOS development environment, and a script that
replays it onto a fresh machine — any Mac, not just the one it was taken from.

```sh
git clone <this repo> ~/development/machines-setups
~/development/machines-setups/macos/install.sh --dry-run   # read it first
~/development/machines-setups/macos/install.sh
```

## What it does

Preflight always runs (Xcode Command Line Tools, Homebrew), then five layers:

| Layer | Covers |
| --- | --- |
| `brew` | `Brewfile` — 51 formulae, 34 casks, via `brew bundle --no-upgrade` |
| `zsh` | oh-my-zsh, the powerlevel10k theme symlink, `~/.docker/completions`, login shell |
| `dotfiles` | Backs up then symlinks `.zshrc`, `.zprofile`, `.p10k.zsh`, `.gitconfig`, `~/.config/git/ignore` |
| `tooling` | `gopls`, `dlv`, `mcp-language-server`, the Claude Code CLI, the four `~/.claude` symlinks |
| `extensions` | ~93 VS Code and ~76 Cursor extensions |

Select layers with `--only brew,dotfiles` or `--skip extensions`. Every layer is
idempotent — it checks state, skips what is satisfied, and reports what it skipped.

`--dry-run` routes every mutating command through a printer instead of executing
it, so the full transcript can be reviewed before anything touches the machine.

## Things worth knowing

**bash 3.2.** The script targets the bash macOS actually ships, because on a
fresh machine there is no other one. No `mapfile`, no `${var,,}`, no associative
arrays, and layer sets are space-padded strings rather than arrays — bash 3.2
errors on `"${empty[@]}"` under `set -u`, and `--skip` can empty the set.

**Apple Silicon only.** The dotfiles hardcode `/opt/homebrew` paths, so preflight
refuses to run on Intel rather than producing a half-broken shell.

**Secrets are not here.** `~/.ssh`, `~/.config/gh/hosts.yml` and friends are
excluded by the repo-root `.gitignore`. `.zshrc` reads `LINEAR_API_KEY` from the
login keychain; the `dotfiles` layer prints the `security add-generic-password`
command rather than storing a value. `gh auth login` stays manual.

**The `.zshrc` here is not byte-identical to the original.** Four deliberate
changes, and nothing else:

| Change | Why |
| --- | --- |
| Dropped a trailing `eval "$(brew shellenv)"` | Duplicated `.zprofile`, and contradicted the comment at the top of the same file saying brew env lives there |
| `fpath=(/Users/shaia/...)` → `$HOME/...` | The literal path is correct on exactly one machine |
| Removed `GOPRIVATE` for a private org | Employer-specific; moved to `~/.zshrc.local` |
| Added `[[ -r ~/.zshrc.local ]] && source` | The escape hatch the previous two rows depend on |

The last three exist to keep this file portable; see the two rows below.

**`.gitconfig` holds preferences, never identity.** It was once 29 lines; 24 of
them had no business in a portable snapshot. What is left is `defaultBranch`,
`autoSetupRemote`, and an https→ssh rewrite — settings that are correct on any
Mac. Three kinds of thing moved out:

- **Identity.** Personal to you, and public the moment it is committed.
- **`gh` and `git-lfs` sections.** Both tools write their own config on any
  machine they run on, and the `gh` helper hardcodes `/opt/homebrew`.
- **The `github.com-shaia` URL rewrite.** This is the one that mattered: it
  routes `github.com/shaia/*` through an SSH host alias defined only in
  `~/.ssh/config`, which is gitignored as a secret. Restoring it on a fresh
  machine does not merely fail to help — it makes `git clone` of your own repos
  die with `Could not resolve hostname github.com-shaia`. A snapshot that
  breaks git is worse than one that omits a preference.

**There is a trap here.** `git config --global` writes to `~/.gitconfig`, which
the `dotfiles` layer symlinks to the tracked file — so `gh auth setup-git` or
`git lfs install` will silently add their sections back **into the repo**.
Nothing prevents this; the file says so at the top, and `install.sh` says so in
its closing manual-steps list. Move what they add into `~/.gitconfig-local`.

**Machine-specific config is deliberately absent.** This snapshot is meant to
work on any Mac, so anything true of only one machine or one employer lives in
three optional files in `$HOME` that the repo never tracks:

| File | Holds | If missing |
| --- | --- | --- |
| `~/.gitconfig-local` | Identity, the `github.com-shaia` URL rewrite, and whatever `gh`/`git-lfs` wrote. Pulled in by `.gitconfig`'s `[include]` | Git refuses to commit: `unable to auto-detect email address`. The `dotfiles` layer warns and prints the command to create one |
| `~/.gitconfig-work` | A work git identity, pulled in by `.gitconfig`'s `includeIf "gitdir:~/work/"` | Git ignores a missing include path silently; `~/work/` repos fall back to the default identity |
| `~/.zshrc.local` | Per-machine env — `GOPRIVATE` for a private org, internal registries, work-only `PATH` entries | `.zshrc` guards the `source` with `[[ -r ]]`, so nothing breaks |

Include order in `.gitconfig` is load-bearing: git applies config in file order
and the last value wins, so the `~/work/` include must come after the
`~/.gitconfig-local` include to override the identity it sets.

The `dotfiles` layer reports whether each is present but never creates or links
them. All three are gitignored by name so a stray copy cannot drag them back in.
The tradeoff is real: a rebuild needs `~/.gitconfig-local` written by hand
before the first commit, and a machine that needs a work identity needs that one
too — with nothing to remind you except a wrong author on your first commit.

**oh-my-zsh is installed with `KEEP_ZSHRC=yes`.** Without it the installer
overwrites `.zshrc`, which on a rebuild means silently losing the file this repo
exists to restore.

**`terraform` is frozen at 1.5.7** in homebrew-core — the last MPL release before
the BUSL relicense. That is genuinely what is installed here. `opentofu`, the
maintained fork, is installed alongside it.

**Some things are deliberately not automated**, and the Brewfile's bottom section
says which: MDM-managed apps (Company Portal, Microsoft Defender, OneDrive,
Microsoft 365 Copilot Shim) belong to the corporate channel, and Kindle is Mac
App Store only. A commented-out `font-meslo-lg-nerd-font` sits there too — this
machine runs powerlevel10k with **no Nerd Font installed anywhere**, so some
prompt glyphs cannot render. Worth enabling on a rebuild; left off so the
Brewfile stays an honest snapshot.

**The full rebuild path has not been executed.** There is no clean machine to try
it on. What is verified: syntax, `--dry-run` transcripts, `brew bundle check`
against the live machine, and a real idempotent re-run here.

**`brew bundle check` is not clean on this machine, and cannot be.** It reports
exactly the 14 hand-installed casks listed below as missing, because it consults
Homebrew's registry rather than `/Applications`. Every formula and every
brew-tracked cask is satisfied. Treat any *other* name in that output as a real
typo in the Brewfile.

## Keeping it current

```sh
./snapshot.sh          # rewrite the extension lists, diff the Brewfile
./snapshot.sh --diff   # report drift, write nothing
```

Extension lists are rewritten in place. The Brewfile is **not**: `brew bundle
dump` produces a flat list with no section headers and no knowledge of the
"deliberately NOT installed" block, so `snapshot.sh` writes `Brewfile.generated`
alongside it, prints the token-level diff, and leaves the merge to you. Delete
the generated file once merged — it is gitignored, not tracked.

**Fourteen casks always show up in that diff as removals.** `alfred`, `canva`,
`claude`, `cleanshot`, `google-chrome`, `grammarly-desktop`, `lightburn`,
`notion`, `obsidian`, `rectangle-pro`, `slack`, `utm`, `warp` and `whatsapp`
were installed by hand before Homebrew knew about them, so `brew bundle dump`
cannot see them. The drift is permanent and expected — keep the lines. The
Brewfile says the same thing next to them.

`dotfiles/` needs no refresh: `install.sh` symlinks them into `$HOME`, so editing
`~/.zshrc` edits this repo.
