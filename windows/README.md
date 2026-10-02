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
shell is elevated, and whether Developer Mode is on. Then six layers run:

| Layer | Does |
| --- | --- |
| `packages` | `winget install --id --exact` for every id in `profiles\core.txt` and each selected profile that `winget export` does not already report, so nothing is upgraded |
| `system` | Per-user, applied directly: Explorer shows file extensions, hidden files and the full path in the title bar; taskbar End Task; no web results in Start search. Machine-wide, applied when elevated and otherwise queued in the summary: long paths, Developer Mode, Windows' inline `sudo`. Then WSL 2 with Ubuntu |
| `vs` | Applies `vsconfig\<profile>.vsconfig` for each selected profile that has one (`cpp`, `lowlevel`) to Visual Studio 2026 Community with `setup.exe modify`, when `vswhere -requires` says a component is missing |
| `dotfiles` | Backs up, then symlinks, `.gitconfig`, `.config\git\ignore`, `.config\starship.toml` and the pwsh `profile.ps1` and `shell-ux.ps1`. Also `.config\git\delta.gitconfig` once delta is installed. Sets Windows Terminal's default profile and font |
| `tooling` | PowerShell modules into pwsh 7, `go install` tools, npm globals, `uv python install`, `uv tool install` |
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

**The Visual C++ runtime installs first.** The packages layer adds
`Microsoft.VCRedist.2015+.x64`, or `.arm64` on an ARM machine, ahead of every
profile. uv and many other tools need it on a clean box, and the id depends on
the architecture, so it is not in a profile file.

**WSL 2 is best-effort.** If `wsl --status` fails, the system layer first asks
why. With no hypervisor running and firmware virtualization off, it flags the
real cause: turn on VT-x/AMD-V in the BIOS/UEFI, or on a VM expose nested
virtualization. Otherwise it queues `wsl --install --no-distribution`, with the
two `dism` commands as the fallback. A running hypervisor makes the processor
report firmware virtualization as off, so the hypervisor check comes first. The
Ubuntu install falls back to `--web-download` on machines without Store access.

**`winget export`, not the WinGet module, answers "what is installed".**
Microsoft's own setup queries the `Microsoft.WinGet.Client` module instead. On
this machine the module query took about 3.8 seconds and the export about 2.6.
That is one uncontrolled measurement, but it gives no reason for a second code
path. The export gets one retry instead. After each install,
`winget list --id <id> --exact` confirms the package is really there, because
some installers report success on failure and failure on a pending reboot.

**Nothing elevates itself.** A machine-scope winget install raises its own UAC
prompt, so a first run is smoother from an elevated shell. Core installs gsudo,
so later one-off elevation is `gsudo <command>`, for example
`gsudo winget install <id>`, without opening an admin terminal. The Visual Studio
installer also elevates itself. WSL may need a reboot before Docker Desktop
works.

**Warp is the terminal.** Two Warp settings live in Warp's own account sync and
cannot be set from here, so the installer lists them. Turn on Appearance ›
Prompt › honour the custom prompt (PS1) so starship shows, and set the font to
JetBrainsMono Nerd Font. Inside Warp, `shell-ux.ps1` skips the PSReadLine
tuning, the fzf key bindings and the lazy posh-git completer, because Warp's
input editor replaces them. They still load in VS Code and Windows Terminal.

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

**Long paths need two switches.** Windows rejects paths over 260 characters
unless `LongPathsEnabled` is set under
`HKLM\SYSTEM\CurrentControlSet\Control\FileSystem`, and Git for Windows ignores
that setting unless `core.longpaths` is true. The shared gitconfig sets the
second. The first is machine-wide, so the system layer sets it only from an
elevated shell and otherwise prints the `gsudo` command for it.

**WSL 2 is in core.** The first `wsl --install` enables the Virtual Machine
Platform feature, which needs elevation and a reboot. Until then the system
layer prints `gsudo wsl --install --no-distribution`. After the reboot it
installs Ubuntu without launching it. Launch Ubuntu once from the Start menu to
create your Linux user.

**Profiles can require profiles.** A `requires <profile>` line in a profile file
pulls that profile in, so `-Profile lowlevel` alone also selects `cpp`. The WDK
package in `lowlevel` is pinned to the same Windows SDK version (26100) as
`cpp.vsconfig`, because a WDK only builds against its matching SDK. Raise both
together.

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

- Both editions parse the script, and it is ASCII-only.
- Dry runs of core, `-Profile go,python,web`, `-Profile all` and `-Profile lowlevel` produce the expected plans and summaries.
- A real run of the `dotfiles` and `vs` layers reports everything already fine and exits 0.
- A run started while another holds the lock exits with code 3.
- The registry helper was run for real against a throwaway key: it created the key and confirmed the value, reported "already fine" on the second call, and queued a machine-wide value as manual without elevation.
- Every winget id resolves with `winget show --exact`.

The CI workflow is the first test on a clean machine. It runs once the
workflow is pushed. Not yet run anywhere: `setup.exe modify`, and the WSL
fallbacks on a machine where WSL is off.
