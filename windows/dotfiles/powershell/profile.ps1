# profile.ps1 - PowerShell 7, all hosts (Windows Terminal, VS Code, bare pwsh).
# Linked from Documents\PowerShell by machines-setups/windows/install.ps1.

# --- Machine-local overrides -------------------------------------------------
# Anything specific to one machine or one employer - a conda hook, an API key a
# tool shell does not inherit, a work-only PATH entry - belongs in
# ~\.powershell.local.ps1, which no repo tracks. Absent on a fresh machine.
$__local = Join-Path $HOME '.powershell.local.ps1'
if (Test-Path $__local) { . $__local }

# --- PATH ---------------------------------------------------------------------
# 7-Zip's installer does not add itself to PATH.
$__7z = Join-Path $env:ProgramFiles '7-Zip'
if ((Test-Path $__7z) -and ($env:Path -notlike "*$__7z*")) { $env:Path += ";$__7z" }

# --- Visual Studio developer shell, on demand ----------------------------------
# `devshell` puts cl.exe, link.exe, msbuild and the Windows SDK on PATH for this
# session. Not automatic: entering it costs several seconds per shell.
function Enter-DevShell {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) { Write-Warning 'Visual Studio is not installed (the cpp profile installs it).'; return }
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vs) { Write-Warning 'No Visual Studio with the C++ toolset found.'; return }
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
    & (Join-Path $vs 'Common7\Tools\Launch-VsDevShell.ps1') -Arch $arch -HostArch $arch -SkipAutomaticLocation -NoLogo
}
Set-Alias -Name devshell -Value Enter-DevShell

# --- Interactive shell experience ----------------------------------------------
# Prompt, history, fuzzy finding, git completion and aliases. Kept in its own
# file, found next to this one through $PSScriptRoot (the link's directory).
$__ux = Join-Path $PSScriptRoot 'shell-ux.ps1'
if (Test-Path $__ux) { . $__ux }
