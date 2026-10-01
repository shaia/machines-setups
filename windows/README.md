# Windows bootstrap

A reproducible snapshot of a Windows 11 development environment, and a script
that replays it onto a fresh machine — any Windows box, not just the one it was
taken from.

```powershell
git clone <this repo> $HOME\development\machines-setups
cd $HOME\development\machines-setups\windows
powershell -ExecutionPolicy Bypass -File .\install.ps1 -DryRun   # read it first
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

`git` is the one thing the clone itself needs; `winget install --id Git.Git -e`
gets it on a box that has nothing. The script's preflight does the same if it
finds the repo extracted from a zip instead.

## What it does

Preflight always runs (winget present, git present, whether the shell is
elevated and whether Developer Mode is on), then six layers:

| Layer | Covers |
| --- | --- |
| `winget` | `winget-packages.txt` — 119 packages, via `winget install --id --exact` for every id that `winget export` does not already report, so nothing is ever upgraded |
| `choco` | `choco-packages.txt` — 7 packages. Needs an elevated shell; skipped with a notice otherwise |
| `vs` | `vsconfig\*.vsconfig` — the workloads of Visual Studio 2022 Community, 2026 Community and Build Tools 2022, applied with `setup.exe modify --config` only when `vswhere -requires` says a component is missing |
| `dotfiles` | Backs up then symlinks `.gitconfig`, `.config\git\ignore`, `.config\starship.toml`, `.bashrc`, `.profile`, `.condarc`, both PowerShell profile sets and Windows Terminal's `settings.json`; junctions `~\.git-global-hooks` |
| `tooling` | `tools.txt` — 9 `go install` tools, 4 npm globals, 1 dotnet tool, 4 PowerShell modules; the `~\.claude` junction |
| `extensions` | 96 VS Code and 94 Cursor extensions |

Select layers with `-Only winget,dotfiles` or `-Skip extensions`. Every layer is
idempotent — it checks state, skips what is satisfied, and reports what it skipped.

`-DryRun` routes every mutating command through a printer instead of executing
it, so the full transcript can be reviewed before anything touches the machine.
The read-only probes still run (`winget export`, `vswhere`, a symlink test in
`%TEMP%`), because the plan depends on their answers.

## Things worth knowing

**Windows PowerShell 5.1.** Both scripts target the PowerShell that ships with
Windows, because on a fresh machine there is no other one; they run unchanged
under PowerShell 7. That rules out `&&`, the ternary, `??` and `$IsWindows`, and
it forces two habits worth knowing before editing: every function result is
wrapped in `@()`, because PowerShell unrolls a returned array (an empty one
arrives as `$null`, a single entry as a string, and under `Set-StrictMode`
neither has `.Count`); and files are enumerated by `.Extension` rather than
`-Filter '*.exe'`, because 5.1 also matches `gopls.exe~` through its 8.3 short
name. The scripts are ASCII-only, since 5.1 reads a BOM-less file as the ANSI
code page.

**Execution policy.** A fresh Windows 11 ships with `Restricted`, which refuses
`.\install.ps1`. The `powershell -ExecutionPolicy Bypass -File` form above works
regardless, and a `git clone` carries no mark-of-the-web, so `RemoteSigned`
would do too.

**Nothing elevates itself.** Junctions need no privilege at all. File symlinks
need either an elevated shell or Developer Mode (Settings › System › For
developers). Chocolatey needs elevation, so its layer skips itself when it has
none. `wsl --install` needs elevation and a reboot, so it is a manual step. The
Visual Studio installer is the exception: `setup.exe modify` raises its own UAC
prompt. The links are made with cmd's `mklink` rather than `New-Item`, because
under Windows PowerShell `New-Item -ItemType SymbolicLink` demands elevation
even with Developer Mode on; `mklink` honours it.

**The machine this was written on has Developer Mode off**, and the session that
wrote it was not elevated — so the `dotfiles` layer has only ever been dry-run
here. See the verification note at the end.

**Documents lives in OneDrive here.** `$PROFILE` is
`...\OneDrive\Documents\PowerShell\...`, which is where the links go — the
script asks `[Environment]::GetFolderPath('MyDocuments')`, exactly as
PowerShell does. OneDrive uploads a symlink's *content* as a plain file and
materialises a plain file on another machine; `install.ps1` there backs that
copy up and replaces it with a link. Harmless, but do not be surprised to see
the profile files "synced" somewhere they are not links.

**Secrets are not here.** `~\.ssh`, gh's `hosts.yml` and friends are excluded
by the repo-root `.gitignore`. The live `profile.ps1` and `.bashrc` on this
machine each carried a plaintext `GEMINI_API_KEY`; the tracked copies do not.
The key lives in the User environment, which every process inherits, and
`~\.powershell.local.ps1` / `~\.bashrc.local` are the escape hatch for a shell
that somehow does not. The `dotfiles` layer checks the User environment and
prints the `[Environment]::SetEnvironmentVariable` command rather than storing
a value. `gh auth login` stays manual.

**The dotfiles are not byte-identical to the originals.** Every deliberate
change, and nothing else:

| File | Change | Why |
| --- | --- | --- |
| `powershell\profile.ps1` | Dropped `$env:GEMINI_API_KEY = "..."` | A secret in a public repo |
| `powershell\profile.ps1`, `windowspowershell\profile.ps1` | Conda hook `C:\Users\shaia\miniconda3` → `$HOME\miniconda3` | Correct on exactly one machine |
| both `profile.ps1` | Added a guarded dot-source of `~\.powershell.local.ps1` | The escape hatch the rows above depend on |
| `windowspowershell\Microsoft.PowerShell_profile.ps1` | `C:\Users\shaia\.local\bin;C:\Users\shaia\AppData\Local\...` → `$HOME\.local\bin;$env:LOCALAPPDATA\...` | Same |
| `bashrc` | Dropped `export GEMINI_API_KEY=...`; added `[ -r ~/.bashrc.local ] && . ~/.bashrc.local` | Secret, and its escape hatch |
| `profile` | `/c/Users/shaia/AppData/Local/...` → `$HOME/AppData/Local/...` | Git Bash sets `$HOME` from `%USERPROFILE%` |
| `config\git\ignore` | One line instead of 23 | Twenty-two were the same line with a backslash, from a `>>` repeated once per session; git matched only the forward-slash one |
| `windows-terminal\settings.json` | `C:\\Users\\shaia` → `%USERPROFILE%` in the four conda profiles (16 places) | Correct on exactly one machine |
| `gitconfig` | Rewritten; see below | — |

`powershell\Microsoft.PowerShell_profile.ps1`, `shell-ux.ps1`, `starship.toml`,
`condarc` and the ten hook files are byte-identical bar line endings: LF in the
repo, and `.gitattributes` pins the files that `sh` reads to LF on checkout,
because Git for Windows would otherwise give them CRLF and `sh` chokes on `\r`.

**`.gitconfig` holds preferences, never identity.** The live file is 27 lines;
what is tracked keeps two settings and adds two includes. Four kinds of thing
moved out:

- **Identity.** Personal to you, and public the moment it is committed.
- **The `[filter "lfs"]` block.** Git for Windows already sets every one of
  those four keys in its system-level `gitconfig` (`git config --system --list
  --show-origin` shows it), so the global copy did nothing.
- **The two gh `[credential]` sections.** `gh auth setup-git` writes them, and
  they are gh's to write back; on a rebuild it will.
- **The three employer-specific `includeIf` rules.** One matched a work
  directory by name, two matched the employer's org in remote URLs. The
  directory rule is generalised to `gitdir/i:~/development/work/` →
  `~\.gitconfig-work`, so any employer fits; the two `hasconfig:remote.*.url`
  rules name a private org and belong in `~\.gitconfig-local`, where git
  honours `includeIf` just the same.

What stayed: `push.autoSetupRemote`, and `core.hooksPath`, now spelled
`~/.git-global-hooks` instead of `C:/Users/shaia/.git-global-hooks` — git
expands `~` in path-typed values, verified with `git rev-parse --git-path
hooks`. Note what is *not* there: no `init.defaultBranch`, because the live
machine never set one; the installer's system config says `master`, and this
snapshot records what is, not what might be nicer.

**Before running the `dotfiles` layer on this machine**, write
`~\.gitconfig-local` with the `[user]` block, both `[credential]` blocks and the
two `hasconfig` rules (pointing at `~\.gitconfig-work`), and rename the
existing employer-named identity file to `~\.gitconfig-work`. Otherwise the
first commit after linking fails with `unable to auto-detect email address`.
The layer warns when the file is absent and prints a starting point; the backup
it makes in `~\.dotfiles-backup-<timestamp>` has every line you need.

**There are three traps here.** `git config --global` writes to `~\.gitconfig`,
which is a symlink into this repo — so `gh auth setup-git` and `git lfs install`
add their sections back **into the repo**; move them to `~\.gitconfig-local`.
`conda init` writes its block into `profile.ps1` the same way (the block is
already there, so a re-run is a no-op unless conda moves). And the
`Microsoft.Coreutils` package owns a marked `DO NOT MODIFY` block in the pwsh
`Microsoft.PowerShell_profile.ps1`; whatever its installer does to that block
on a rebuild lands in the repo too.

**Machine-specific config is deliberately absent.** Anything true of only one
machine or one employer lives in optional files that the repo never tracks:

| File | Holds | If missing |
| --- | --- | --- |
| `~\.gitconfig-local` | Identity, gh's credential helper, org-specific `includeIf` rules. Pulled in by `.gitconfig`'s `[include]` | Git refuses to commit. The `dotfiles` layer warns and prints the command to create one |
| `~\.gitconfig-work` | A work git identity, pulled in by `includeIf "gitdir/i:~/development/work/"` | Git ignores a missing include silently; work repos fall back to the default identity |
| `~\.powershell.local.ps1` | Per-machine env for both PowerShell editions — an API key a tool shell does not inherit, a work-only PATH entry | Both `profile.ps1` guard the dot-source with `Test-Path` |
| `~\.bashrc.local` | The same for Git Bash | `.bashrc` guards it with `[ -r ]` |

Include order in `.gitconfig` is load-bearing: git applies config in file order
and the last value wins, so the work include must come after the local include
to override the identity it sets. All four files are gitignored by name so a
stray copy cannot drag them back in.

**Windows Terminal's `settings.json` is tracked and linked.** It carries the
default profile (pwsh), the `JetBrainsMono NF` font that `starship.toml`
depends on, four keybindings, a hand-written "Developer PowerShell for VS 2026"
profile and four conda prompts. It is portable because Terminal derives the
GUIDs of generated profiles deterministically from their source, so they are
the same on every machine, and because `%USERPROFILE%` is expanded in
`commandline` and `startingDirectory` (documented) and in `icon` (not in the
docs, but Terminal's media resolver runs every icon and background path
through `ExpandEnvironmentStringsW` before checking it exists). Terminal
rewrites the whole file whenever a setting changes in its UI; it is expected to
write through the link rather than replace it, but that has not been verified
here, for the reason above.

**`winget` cannot see everything.** `winget export` only lists packages it can
match to a source, so these are installed here and absent from
`winget-packages.txt` by construction: the JetBrains IDEs (CLion, GoLand,
IntelliJ IDEA, PyCharm, Rider, RustRover, Fleet — all installed by the Toolbox,
which *is* listed), MATLAB R2025a and R2026a, Wolfram 14.2, ParaView, WezTerm,
Google Chrome, Brave, WhatsApp, Spotify, the .NET SDKs 9 and 10 that Visual
Studio bundles, SQL Server LocalDB 2019 and 2025, the Windows Driver Kit, IIS
Express, and every driver and OEM utility (NVIDIA, Razer, ASUS, Dell, Garmin,
Wacom, Brother, HP). They come back by hand or through their own installers.

**Some winget entries are hardware-specific**, and the file says which: the
NVIDIA entries (CUDA 13, Nsight Compute, PhysX), the Wacom and Dell utilities,
the Garmin and GPS-mapping tools, and the HP print app from the Store. Drop the
section on a box without the hardware; the snapshot keeps them because they are
what is installed.

**Two package managers hold duplicates.** Chocolatey has 5 real packages, every
one of which winget also carries, and three are installed twice: `cmake` (with
`Kitware.CMake`, same `C:\Program Files\CMake` target), `llvm` (with
`LLVM.LLVM`) and `golangci-lint` (with the `go install` in `tools.txt`). Scoop
is installed too, with one package (`7zip`) and buckets last updated in 2024;
it has no layer. Consolidating is a separate decision; the snapshot records
what is.

**Visual Studio workloads are a layer of their own** because winget installs
Visual Studio with its defaults, and this machine's selections (Linux CMake,
Unreal, Python, the Windows Driver Kit, four Windows SDKs) are nothing like the
defaults. `snapshot.ps1` exports each product's real selection with
`setup.exe export`; `install.ps1` checks it with `vswhere -requires <every
component>` — which returns the install path only when all of them are present
— and runs `setup.exe modify --config` otherwise. The file names encode what
the installer needs to find the instance: `vs2022-community` is product
`Microsoft.VisualStudio.Product.Community` in version range `[17.0,18.0)`;
`vs2026-community` is the same product at 18. Both scripts carry the year→major
table.

**`winget export` is slow and both scripts run it.** About a minute each on this
machine, mostly spent matching installed programs against the catalogue. The
alternative, parsing `winget list`, truncates long ids with an ellipsis
whenever the console is narrow; the export is the only honest view.

**`tools.txt` has one deliberate omission.** `clangd-mcp-server` is a global npm
package here, but it is an `npm link` to a checkout under `%TEMP%` — no
registry has it, so `snapshot.ps1` skips linked packages and says so on every
run. The four PowerShell modules are installed from *inside* `pwsh`, because
Windows PowerShell's user module path is invisible to PowerShell 7 and the
profile that loads them is a pwsh profile. `Microsoft.Graph` installs 37
`Microsoft.Graph.*` parts alongside itself; the snapshot lists a module only
when its name does not extend another installed module's name with a dot.

**`~\.claude` is one junction**, to the whole config repo, runtime state
included — not the four per-directory links the macOS layer makes. The config
repo's own `.gitignore` is what keeps sessions and credentials out of git.

**The full rebuild path has not been executed.** There is no clean machine to
try it on. What is verified, under both Windows PowerShell 5.1 and PowerShell
7.6: both scripts parse; a full `-DryRun` transcript; `snapshot.ps1 -Diff`
reports no drift against the live machine; and a real
`install.ps1 -Skip dotfiles,choco` run that found every package, workload, tool
and extension present and installed nothing. What is not: the `dotfiles` layer
for real (no symlink privilege in the session that wrote it — only the
`mklink` probe and the junction path have run), the `choco` layer (not
elevated), `setup.exe modify` (every component was already present), and
Windows Terminal writing through its linked `settings.json`.

## Keeping it current

```powershell
.\snapshot.ps1          # rewrite the generated files, append new winget/choco ids
.\snapshot.ps1 -Diff    # report drift, write nothing
```

Two kinds of inventory file. `tools.txt`, the two extension lists and
`vsconfig\*.vsconfig` are **generated**: rewritten wholesale from the live
machine. `winget-packages.txt` and `choco-packages.txt` are **curated**: they
keep their section headers and comments, and `snapshot.ps1` only ever appends
to them, under a dated `Unsorted` header for you to file. Packages that are
listed but no longer installed are reported, never deleted — the usual causes
are an uninstall, which you will recognise, and an app that updated itself in a
way winget no longer matches, which you will want to keep.

`dotfiles\` needs no refresh: `install.ps1` links them into place, so editing
`~\.gitconfig` or the PowerShell profile edits this repo.
