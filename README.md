# machines-setups

Snapshots of the machines I develop on, and the scripts that replay them onto a
fresh box. The point is that rebuilding a machine is a `git clone` and one
command, not an afternoon of remembering what was installed.

## Layout

One directory per platform. Each is self-contained — clone the repo, run the
script inside the directory that matches the machine.

| Directory | Target |
| --- | --- |
| [`macos/`](macos/) | Apple Silicon Macs — Homebrew, zsh/oh-my-zsh, dotfiles, Go tooling, VS Code + Cursor extensions |

```sh
git clone <this repo> ~/development/machines-setups
~/development/machines-setups/macos/install.sh --dry-run   # read it first
~/development/machines-setups/macos/install.sh
```

See [`macos/README.md`](macos/README.md) for the layer breakdown, what is
deliberately not automated, and what has and has not been verified.

## The shape every platform directory follows

Not enforced by anything — a convention, so a second platform reads like the
first:

- **`install.sh`** — replays the snapshot. Split into named layers selectable
  with `--only` / `--skip`, idempotent layer by layer (it inspects state, skips
  what is satisfied, and says so), and `--dry-run` prints every mutating command
  without running one. Written against the shell the target OS ships by
  default, since on a fresh machine there is nothing else.
- **`snapshot.sh`** — the other direction: regenerates the inventory from the
  live machine so the checked-in copy does not rot. `--diff` reports drift and
  writes nothing.
- **`README.md`** — the invisible knowledge. Why something is pinned, what the
  script refuses to do, which drift is permanent and expected. Not a
  restatement of what the script plainly says.
- **`dotfiles/`** — stored without leading dots (`zshrc`, not `.zshrc`) so they
  are visible to `ls` and to review, and symlinked into `$HOME` by the
  `dotfiles` layer, which backs up whatever it replaces first.

Because dotfiles are **symlinked** rather than copied, editing `~/.zshrc` edits
this repo. That is the intent — the snapshot cannot drift from the machine — but
it does mean `git status` here reacts to shell tinkering, and `snapshot.sh`
leaves `dotfiles/` alone for the same reason.

## Secrets

The root [`.gitignore`](.gitignore) is the boundary. Nothing credential-bearing
is checked in: no `~/.ssh`, no `gh` hosts file, no keys, no `.netrc`, no AWS
credentials.

Every pattern is written to match at any depth, so a new platform directory
inherits the protection for free. That is why `.aws/credentials` is spelled
`**/.aws/credentials` — a pattern containing a slash is otherwise anchored to
the repo root, and `macos/.aws/credentials` would sail straight through. Keep
new patterns unanchored, and check with `git check-ignore -v <path>` rather
than assuming.

Anything that needs a secret asks for it instead of carrying it. The macOS
`dotfiles` layer prints the `security add-generic-password` command for the one
API key `.zshrc` expects rather than storing a value, and `gh auth login` stays
manual. Keep that arrangement when adding a platform: a script may tell you how
to supply a credential, never ship one.

## Personal, and portable

This is a personal repo, and the snapshots are meant to replay onto *any* Mac —
not one particular machine under one particular employer. So config that is true
of only one machine stays out of it, in optional files under `$HOME` that the
scripts detect but never manage: `~/.gitconfig-local` for git identity,
`~/.gitconfig-work` for a work identity, `~/.zshrc.local` for per-machine
environment such as `GOPRIVATE`. All three are gitignored by name.

The tracked configs keep only what is portable. `.gitconfig`, for instance, is
preferences alone — no identity, and none of the URL rewrites that depend on a
`~/.ssh/config` this repo deliberately does not ship. Restoring those on a
different machine would break `git clone` rather than help it.

The rule for anything new: if it would be wrong on someone else's Mac — a
hardcoded `/Users/<name>` path, an employer's private org, an internal registry
— it belongs in a local override, not here.
