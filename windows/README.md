# Windows

```powershell
git clone <this repo> $HOME\development\machines-setups
cd $HOME\development\machines-setups\windows
powershell -ExecutionPolicy Bypass -File .\install.ps1 -DryRun -Profile go,python   # read it first
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Profile go,python
```

`git` is the one thing the clone needs. Get it with
`winget install --id Git.Git -e` on a box that has nothing, or let preflight
install it if you extracted the repo from a zip.

See the [root README](../README.md) for the profiles and the reasoning behind
them. This file covers what is specific to Windows.

## Layers

Preflight always runs. It checks that winget and git are present, whether the
shell is elevated, and whether Developer Mode is on. Then five layers run:

| Layer | Does |
| --- | --- |
| `packages` | `winget install --id --exact` for every id in `profiles\core.txt` and each selected profile that `winget export` does not already report, so nothing is upgraded |
| `vs` | cpp profile only: applies `vsconfig\cpp.vsconfig` to Visual Studio 2026 Community with `setup.exe modify`, when `vswhere -requires` says a component is missing |
| `dotfiles` | Backs up, then symlinks, `.gitconfig`, `.config\git\ignore`, `.config\starship.toml` and the pwsh `profile.ps1` and `shell-ux.ps1`. Also `.config\git\delta.gitconfig` once delta is installed. Sets Windows Terminal's default profile and font |
| `tooling` | PowerShell modules into pwsh 7, `go install` tools, npm globals, `uv python install` |
| `extensions` | VS Code extensions from `common\profiles\` |

The packages layer re-reads PATH from the registry after it installs anything,
so later layers in the same run find the new tools.

## Things worth knowing

**Windows PowerShell 5.1.** The script targets the PowerShell that ships with
Windows and runs unchanged under PowerShell 7. That rules out `&&`, the ternary
operator, `??` and `$IsWindows`. Two habits matter when editing:

- Every function result is wrapped in `@()`. PowerShell unrolls a returned
  array, so an empty one arrives as `$null` and a single entry as a string,
  and under `Set-StrictMode` neither has `.Count`.
- Files are filtered by `.Extension` rather than `-Filter`. In 5.1, `-Filter`
  also matches 8.3 short names, so `x.txt~` would match `*.txt`.

The script is ASCII-only, because 5.1 reads a BOM-less file as the ANSI code
page. `Run` sends a native command's stdout to the host, not the pipeline,
because otherwise the exit code it returns becomes an array of output lines.

**Execution policy.** A fresh Windows 11 ships with `Restricted`, which refuses
to run `.\install.ps1`. The `powershell -ExecutionPolicy Bypass -File` form
above works regardless.

**Symlinks need Developer Mode.** Turn it on in Settings › System › For
developers, or run elevated. The Settings toggle writes
`AllowDevelopmentWithoutDevLicense=1` under
`HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock`, and it takes
effect for new processes at once. Links are made with cmd's `mklink`.
Under Windows PowerShell, `New-Item -ItemType SymbolicLink` demands elevation
even with Developer Mode on, and `mklink` does not.

**Nothing elevates itself.** A machine-scope winget install raises its own UAC
prompt, so a first run is smoother from an elevated shell. The Visual Studio
installer also elevates itself. WSL may need a reboot before Docker Desktop
works.

**PowerShell 7 is the shell.** Only the pwsh profile is managed. Windows
PowerShell 5.1 keeps whatever profile it has. `profile.ps1` dot-sources
`~\.powershell.local.ps1` first, then `shell-ux.ps1`. `shell-ux.ps1` sets up
PSReadLine predictions, fzf on Ctrl+R and Ctrl+T, zoxide, lazily loaded git
completion, git aliases and starship. Its order matters: starship goes last
because it owns the `prompt` function. The whole file is skipped in
non-interactive shells.

**`devshell`, not an automatic developer shell.** Entering Visual Studio's
developer environment costs several seconds, so no shell does it at startup.
Run `devshell` in pwsh when you need `cl.exe`, `link.exe` or msbuild on PATH.
It finds the newest Visual Studio with the C++ tools through vswhere.

**Windows Terminal is merged, not linked.** Terminal writes every machine's
generated profiles (WSL distros, Visual Studio shells, Azure) into its
`settings.json`. A linked copy would carry one machine's profiles into the
repo. The dotfiles layer instead sets two things in whatever file exists: the
default profile becomes PowerShell 7, and the font becomes `JetBrainsMono NF`.
The PowerShell 7 profile's GUID is derived deterministically, so it is the
same on every machine. Terminal must have been launched once, so that the file
exists. A file with comments is left alone, with a message.

**The Nerd Font installs machine-wide**, through the winget package. Windows
Terminal (an MSIX app) and VS Code (Chromium) do not see per-user fonts.

**Documents may live in OneDrive.** The profile links go wherever
`[Environment]::GetFolderPath('MyDocuments')` points, which is where PowerShell
looks for them. OneDrive syncs a link's content as a plain file. On another
machine, `install.ps1` backs that copy up and replaces it with a link.

**Rust needs the C++ tools.** rustup's MSVC toolchain links with Visual
Studio's linker. Select `cpp` together with `rust`, or rustup-init will offer to
install the Build Tools itself.

**Traps.**

- `git config --global` writes to `~\.gitconfig`, which is a link into this
  repo. So `gh auth setup-git` and `git lfs install` add their sections **to
  the repo**. Move them into `~\.gitconfig-local`.
- To check identity, use `git config --global --includes user.email`. Without
  `--includes`, git reads the named file only and does not follow the include.

## What has been verified

The following ran on a Windows 11 machine under both Windows PowerShell 5.1
and PowerShell 7.6:

- Both editions parse the script.
- `-Help` works, and an unknown profile exits with code 2.
- Dry runs of core only, `-Profile all` and `-Profile cpp,go` produce the
  expected plans.
- Every winget id resolves with `winget show --exact`.
- The `dotfiles` layer ran for real, relinking a machine that had been set up
  from the earlier snapshot. Identity, hook path and the pwsh profile were all
  intact afterwards.

Not yet run: a clean machine end to end, `setup.exe modify`, and the Windows
Terminal merge on a file that needs changing.
