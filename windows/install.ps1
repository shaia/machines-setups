#Requires -Version 5.1
<#
.SYNOPSIS
Set up an opinionated Windows development machine: a core every developer
gets, plus the language and tool profiles you pick.

.DESCRIPTION
  .\install.ps1                            # core only; lists the profiles
  .\install.ps1 -Profile go,python,web     # core plus those profiles
  .\install.ps1 -Profile all               # everything
  .\install.ps1 -Only dotfiles             # just that layer
  .\install.ps1 -Skip extensions           # every layer but that one
  .\install.ps1 -DryRun                    # print every mutating command, run none

A fresh Windows install refuses to run local scripts until the execution
policy allows it; this form works regardless:

  powershell -ExecutionPolicy Bypass -File .\install.ps1 -DryRun

Profiles live in two halves: windows\profiles\<name>.txt (winget ids and
PowerShell modules) and ..\common\profiles\<name>.txt (VS Code extensions, Go
tools, npm globals, uv Pythons, shared with macOS). Preflight (winget, git,
elevation, symlink ability) always runs. Every layer is safe to re-run: it
inspects the current state, skips what is already satisfied, and says so.

Written for the Windows PowerShell 5.1 that ships with Windows - no ternary,
no &&, no $IsWindows, every function result wrapped in @() - so it runs on a
box where nothing has been installed yet. Kept ASCII-only because 5.1 reads a
BOM-less file as the ANSI code page.
#>
[CmdletBinding()]
param(
    # Not named $Profile: PowerShell variables are case-insensitive, and that
    # would shadow the automatic $PROFILE. -Profile still works as an alias.
    [Alias('Profile')]
    [string[]]$Profiles,
    [string[]]$Only,
    [string[]]$Skip,
    [switch]$DryRun,
    [switch]$Help
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$ScriptDir = $PSScriptRoot
$RepoRoot = Split-Path -Parent $ScriptDir
$CommonDir = Join-Path $RepoRoot 'common'
$BackupDir = Join-Path $HOME ".dotfiles-backup-$(Get-Date -Format yyyyMMdd-HHmmss)"
# Honours a Documents folder redirected into OneDrive, which is where
# PowerShell itself looks for profiles.
$Documents = [Environment]::GetFolderPath('MyDocuments')
$WindowsTerminalState = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState'
# Windows Terminal derives the GUID of its generated PowerShell 7 profile from
# the generator and profile name, so it is the same on every machine.
$PwshProfileGuid = '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
$NerdFontFace = 'JetBrainsMono NF'

# The cpp profile's Visual Studio: VS 2026 (installer major version 18) Community.
$VsProductId = 'Microsoft.VisualStudio.Product.Community'
$VsVersionRange = '[18.0,19.0)'

$AllLayers = @('packages', 'vs', 'dotfiles', 'tooling', 'extensions')
$Layers = $AllLayers

# --- Output helpers ----------------------------------------------------------

function Write-Info { param([string]$Message) Write-Host "[INFO] $Message" }
function Write-Warn { param([string]$Message) Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Err  { param([string]$Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }
function Write-Step { param([string]$Message) Write-Host ""; Write-Host "=== $Message ===" }

function Format-Arg {
    param([string]$Arg)
    if ($Arg -match '\s' -or $Arg -eq '') { return "`"$Arg`"" }
    return $Arg
}

# Everything that changes the machine goes through Run or RunBlock, so -DryRun
# is total rather than a decision each layer has to remember to make.
#
# Native commands write progress to stderr, and under 'Stop' Windows PowerShell
# turns a redirected stderr line into a terminating error; so native commands
# run with 'Continue' in effect and report through their exit code instead.
#
# Their stdout goes to the host, not the pipeline: a function's output is
# everything it emits, so a bare `& winget ...` would make the returned exit
# code an array of winget's lines plus the code, and `$code -eq 0` on that is
# false even after a successful install.
function Run {
    param([Parameter(Mandatory)][string[]]$Command, [switch]$Quiet)
    $printed = ($Command | ForEach-Object { Format-Arg $_ }) -join ' '
    if ($DryRun) {
        Write-Host "  + $printed"
        return 0
    }
    $exe = $Command[0]
    $rest = @()
    if ($Command.Count -gt 1) { $rest = $Command[1..($Command.Count - 1)] }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Quiet) { & $exe @rest 2>&1 | Out-Null }
        else { & $exe @rest | Out-Host }
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prev
    }
    if ($null -eq $code) { $code = 0 }
    return $code
}

# For PowerShell-side mutations (New-Item, Move-Item) that have no argv form.
function RunBlock {
    param([Parameter(Mandatory)][string]$Description, [Parameter(Mandatory)][scriptblock]$Block)
    if ($DryRun) {
        Write-Host "  + $Description"
        return
    }
    & $Block
}

# Read-only native call: stdout lines plus exit code, stderr discarded.
function Invoke-Capture {
    param([Parameter(Mandatory)][string[]]$Command)
    $exe = $Command[0]
    $rest = @()
    if ($Command.Count -gt 1) { $rest = $Command[1..($Command.Count - 1)] }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $exe @rest 2>$null
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prev
    }
    $lines = @()
    foreach ($o in @($out)) { $lines += [string]$o }
    return [pscustomobject]@{ Output = $lines; ExitCode = $code }
}

function Test-Command {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# Lines of a list file with comments and blanks stripped and whitespace collapsed.
function Get-Entries {
    param([string]$Path)
    $entries = @()
    if (-not (Test-Path -LiteralPath $Path)) { return $entries }
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $t = ($line -replace '#.*$', '').Trim()
        if ($t) { $entries += ($t -replace '\s+', ' ') }
    }
    return $entries
}

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-DeveloperMode {
    $k = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -ErrorAction SilentlyContinue
    if ($null -eq $k) { return $false }
    $p = $k.PSObject.Properties['AllowDevelopmentWithoutDevLicense']
    return ($null -ne $p -and $p.Value -eq 1)
}

# Junctions never need a privilege; file symlinks need elevation or Developer
# Mode. Asking the registry is a guess, so probe for real in TEMP instead.
function Test-SymlinkAbility {
    $dir = Join-Path $env:TEMP "install-ps1-probe-$PID"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $dir 'target') -Value 'probe'
    $r = Invoke-Capture @('cmd', '/c', 'mklink', (Join-Path $dir 'link'), (Join-Path $dir 'target'))
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    return ($r.ExitCode -eq 0)
}

function Get-NormalizedPath {
    param([string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd('\').ToLowerInvariant()
}

# .Target is a string in PowerShell 7 and a string[] in Windows PowerShell.
function Get-LinkTarget {
    param($Item)
    return [string](@($Item.Target)[0])
}

function Test-LinkedTo {
    param($Item, [string]$Source, [string[]]$LinkTypes)
    if ($null -eq $Item) { return $false }
    if ($LinkTypes -notcontains [string]$Item.LinkType) { return $false }
    return ((Get-NormalizedPath (Get-LinkTarget $Item)) -eq (Get-NormalizedPath $Source))
}

# Installers append to the machine and User PATH, which this process does not
# see. Re-read both so later layers find what earlier ones installed.
function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

# --- Profiles ----------------------------------------------------------------

# Every name that has a file in either half; core is implicit, never listed.
function Get-AvailableProfiles {
    $names = @()
    foreach ($dir in @((Join-Path $ScriptDir 'profiles'), (Join-Path $CommonDir 'profiles'))) {
        $names += @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -eq '.txt' } | ForEach-Object { $_.BaseName.ToLowerInvariant() })
    }
    return ($names | Where-Object { $_ -ne 'core' } | Sort-Object -Unique)
}

$AvailableProfiles = @(Get-AvailableProfiles)

# Entries of one kind across the selected profiles, deduplicated in order.
#   winget, psmodule      windows\profiles\<name>.txt (a bare line is a winget id)
#   vscode, go, npm, uv-python   ..\common\profiles\<name>.txt
function Get-ProfileEntries {
    param([string]$Kind)
    $out = @()
    foreach ($p in $SelectedProfiles) {
        if ($Kind -eq 'winget' -or $Kind -eq 'psmodule') {
            foreach ($e in @(Get-Entries (Join-Path $ScriptDir "profiles\$p.txt"))) {
                $parts = $e -split ' ', 2
                if ($Kind -eq 'psmodule' -and $parts[0] -eq 'psmodule' -and $parts.Count -eq 2) { $out += $parts[1] }
                elseif ($Kind -eq 'winget' -and $parts.Count -eq 1) { $out += $parts[0] }
            }
        }
        else {
            foreach ($e in @(Get-Entries (Join-Path $CommonDir "profiles\$p.txt"))) {
                $parts = $e -split ' ', 2
                if ($parts.Count -eq 2 -and $parts[0] -eq $Kind) { $out += $parts[1] }
            }
        }
    }
    $seen = @{}
    $unique = @()
    foreach ($x in $out) {
        $k = $x.ToLowerInvariant()
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $unique += $x }
    }
    return $unique
}

# --- Argument parsing --------------------------------------------------------

function Show-Usage {
    @"
Usage: install.ps1 [options]

  -Profile <names>  Add these profiles to core (comma-separated), or 'all'.
  -Only    <layers> Run only these layers (comma-separated).
  -Skip    <layers> Run every layer except these.
  -DryRun           Print every mutating command without running it.
  -Help             This message.

Profiles: $($AvailableProfiles -join ', ')
Layers:   $($AllLayers -join ', ')
"@ | Write-Host
}

function ConvertTo-NameList {
    param([string[]]$Raw, [string[]]$Valid, [string]$What)
    $out = @()
    foreach ($chunk in $Raw) {
        foreach ($name in ($chunk -split ',')) {
            $n = $name.Trim().ToLowerInvariant()
            if (-not $n) { continue }
            if ($Valid -notcontains $n) {
                Write-Err "Unknown $What '$n'. Valid: $($Valid -join ', ')"
                exit 2
            }
            $out += $n
        }
    }
    return $out
}

if ($Help) { Show-Usage; exit 0 }
if ($Only) { $Layers = @(ConvertTo-NameList $Only $AllLayers 'layer') }
if ($Skip) {
    $skipping = @(ConvertTo-NameList $Skip $AllLayers 'layer')
    $Layers = @($Layers | Where-Object { $skipping -notcontains $_ })
}
# Always in canonical order, whatever order -Only listed them in.
$Layers = @($AllLayers | Where-Object { $Layers -contains $_ })

$requested = @()
if ($Profiles) { $requested = @(ConvertTo-NameList $Profiles ($AvailableProfiles + @('all')) 'profile') }
if ($requested -contains 'all') { $requested = $AvailableProfiles }
$SelectedProfiles = @('core') + @($AvailableProfiles | Where-Object { $requested -contains $_ })

function Wants { param([string]$Layer) return ($Layers -contains $Layer) }

# --- Preflight ---------------------------------------------------------------
#
# Always runs. Its one mutating action (installing git) is guarded by "if
# missing", so on an already-configured machine this is read-only.

$script:Elevated = $false
$script:DeveloperMode = $false

function Invoke-Preflight {
    Write-Step "Preflight"

    if ($env:OS -ne 'Windows_NT') {
        Write-Err "Windows only; this is $env:OS."
        exit 1
    }
    $os = [Environment]::OSVersion.Version
    Write-Info "Windows $os on $env:PROCESSOR_ARCHITECTURE; PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))."

    $script:Elevated = Test-Elevated
    $script:DeveloperMode = Test-DeveloperMode
    if ($script:Elevated) { Write-Info "Running elevated: file symlinks work, and winget installs will not prompt." }
    else { Write-Info "Not elevated: each machine-scope winget install raises its own UAC prompt." }
    if ($script:DeveloperMode) { Write-Info "Developer Mode is on: file symlinks work without elevation." }
    elseif (-not $script:Elevated) { Write-Warn "Developer Mode is off and the shell is not elevated; the dotfiles layer cannot create file symlinks." }

    if (Test-Command winget) {
        $v = (Invoke-Capture @('winget', '--version')).Output | Select-Object -First 1
        Write-Info "winget present ($v)."
    }
    else {
        Write-Err "winget is missing. It ships with Windows 11 as 'App Installer'; update that from the"
        Write-Err "Microsoft Store (or https://aka.ms/getwinget), open a new shell, and re-run."
        exit 1
    }

    if (Test-Command git) {
        Write-Info "git present at $((Get-Command git).Source)."
    }
    else {
        Write-Warn "git missing; installing Git.Git with winget."
        Run @('winget', 'install', '--id', 'Git.Git', '--exact', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity') | Out-Null
        Update-SessionPath
        if (-not (Test-Command git) -and -not $DryRun) {
            Write-Err "git still not on PATH. Open a new shell and re-run."
            exit 1
        }
    }
}

# --- Layer: packages ---------------------------------------------------------

# What winget considers installed, keyed by lower-case id.
# `winget export` is the only view that is not a truncated fixed-width table.
function Get-WingetInstalled {
    $tmp = Join-Path $env:TEMP "winget-export-$PID.json"
    $r = Invoke-Capture @('winget', 'export', '-o', $tmp, '--accept-source-agreements', '--disable-interactivity')
    if (-not (Test-Path -LiteralPath $tmp)) { throw "winget export produced no file (exit $($r.ExitCode))." }
    $json = Get-Content -LiteralPath $tmp -Raw | ConvertFrom-Json
    Remove-Item -LiteralPath $tmp -Force
    $keys = @()
    foreach ($source in @($json.Sources)) {
        foreach ($pkg in @($source.Packages)) { $keys += $pkg.PackageIdentifier.ToLowerInvariant() }
    }
    return $keys
}

function Invoke-LayerPackages {
    Write-Step "winget packages"

    $ids = @(Get-ProfileEntries 'winget')
    if ($ids.Count -eq 0) {
        Write-Info "No winget packages in the selected profiles."
        return
    }
    Write-Info "$($ids.Count) packages across: $($SelectedProfiles -join ', ')."
    Write-Info "Asking winget what is installed (winget export; read-only, takes a while)."
    $present = @(Get-WingetInstalled)

    $already = 0; $added = 0; $failed = 0
    foreach ($id in $ids) {
        if ($present -contains $id.ToLowerInvariant()) { $already++; continue }
        # Installing a package winget already knows would upgrade it; the
        # presence check above is what keeps this a no-upgrade install.
        $code = Run @('winget', 'install', '--id', $id, '--exact', '--source', 'winget',
            '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
        if ($code -eq 0) { $added++ } else { Write-Warn "  failed ($code): $id"; $failed++ }
    }
    Write-Info "winget: $($ids.Count) listed, $already already present, $added installed, $failed failed."
    if ($failed -gt 0) {
        Write-Warn "Failures are usually an installer that insists on a prompt, or an id that was renamed;"
        Write-Warn "'winget search <name>' finds the current id."
    }
    if ($added -gt 0 -and -not $DryRun) { Update-SessionPath }
}

# --- Layer: vs ---------------------------------------------------------------
#
# winget installs Visual Studio with its default workloads. vsconfig\cpp.vsconfig
# holds the curated C++ selection; the installer's `modify --config` adds
# whatever is missing. vswhere -requires answers "is every listed component
# present" without launching the installer.

function Invoke-LayerVs {
    Write-Step "Visual Studio workloads"

    if ($SelectedProfiles -notcontains 'cpp') {
        Write-Info "The cpp profile is not selected; nothing to do."
        return
    }
    $installer = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer'
    $vswhere = Join-Path $installer 'vswhere.exe'
    $setup = Join-Path $installer 'setup.exe'
    if (-not ((Test-Path -LiteralPath $vswhere) -and (Test-Path -LiteralPath $setup))) {
        Write-Warn "Visual Studio Installer not found; the packages layer installs Visual Studio."
        Write-Warn "Re-run with -Profile cpp -Only vs afterwards."
        return
    }

    $installPath = (Invoke-Capture @($vswhere, '-products', $VsProductId, '-version', $VsVersionRange, '-property', 'installationPath')).Output | Select-Object -First 1
    if (-not $installPath) {
        Write-Warn "Visual Studio 2026 Community is not installed; the packages layer installs it."
        return
    }

    $cfg = Join-Path $ScriptDir 'vsconfig\cpp.vsconfig'
    $components = @((Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json).components)
    $query = @($vswhere, '-products', $VsProductId, '-version', $VsVersionRange, '-requires') + $components + @('-property', 'installationPath')
    $satisfied = (Invoke-Capture $query).Output | Select-Object -First 1
    if ($satisfied) {
        Write-Info "cpp.vsconfig: all $($components.Count) components present."
        return
    }

    Write-Info "cpp.vsconfig: adding missing components (the installer elevates itself and may prompt)."
    $code = Run @($setup, 'modify', '--installPath', $installPath, '--config', $cfg, '--passive', '--norestart')
    if ($code -ne 0) { Write-Warn "  setup.exe modify exited $code." }
}

# --- Layer: dotfiles ---------------------------------------------------------

# Backups keep the path relative to $HOME (or the drive root when outside it),
# so files with the same name cannot collide in the backup directory.
function Backup-Path {
    param([string]$Path, [switch]$Copy)
    $full = [IO.Path]::GetFullPath($Path)
    $homeFull = [IO.Path]::GetFullPath($HOME).TrimEnd('\')
    if ($full.StartsWith($homeFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $rel = $full.Substring($homeFull.Length + 1)
    }
    else {
        $rel = $full -replace '^[A-Za-z]:\\', ''
    }
    $dest = Join-Path $BackupDir $rel
    Write-Info "Backing up $Path -> $dest"
    RunBlock "$(if ($Copy) { 'Copy' } else { 'Move' }) $Path -> $dest" {
        $parent = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        if ($Copy) { Copy-Item -LiteralPath $Path -Destination $dest -Force }
        else { Move-Item -LiteralPath $Path -Destination $dest -Force }
    }
}

function New-FileLink {
    param([string]$Source, [string]$Target)

    $item = Get-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
    if (Test-LinkedTo -Item $item -Source $Source -LinkTypes @('SymbolicLink')) {
        Write-Info "$(Split-Path -Leaf $Target) already linked."
        return
    }
    if ($null -ne $item) { Backup-Path $Target }

    $parent = Split-Path -Parent $Target
    if (-not (Test-Path -LiteralPath $parent)) {
        RunBlock "New-Item -ItemType Directory $parent" { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    }
    # cmd's mklink honours Developer Mode without elevation; New-Item does not
    # under Windows PowerShell.
    $code = Run @('cmd', '/c', 'mklink', $Target, $Source) -Quiet
    if ($code -eq 0) { Write-Info "Linked $Target -> $Source" }
    else { Write-Err "mklink failed ($code) for $Target" }
}

# Sets Windows Terminal's default profile to PowerShell 7 and its font to the
# Nerd Font, inside whatever settings.json the machine already has. Terminal
# writes every machine's generated profiles into that file, so it is merged
# rather than linked: a linked copy would carry one machine's profiles into
# the repo.
function Set-TerminalDefaults {
    $settings = Join-Path $WindowsTerminalState 'settings.json'
    if (-not (Test-Path -LiteralPath $settings)) {
        Write-Warn "Windows Terminal has not been launched yet (no settings.json); launch it once, then re-run -Only dotfiles."
        return
    }
    try { $json = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json }
    catch {
        Write-Warn "Windows Terminal settings.json is not plain JSON (comments?); set the default profile to PowerShell"
        Write-Warn "and the font to '$NerdFontFace' in Terminal's Settings instead."
        return
    }
    $profilesProp = $json.PSObject.Properties['profiles']
    if ($null -eq $profilesProp -or $profilesProp.Value -is [array]) {
        Write-Warn "Windows Terminal settings.json uses an old layout; set the default profile and font in Terminal's Settings."
        return
    }

    $changes = @()
    $current = $json.PSObject.Properties['defaultProfile']
    if ($null -eq $current -or $current.Value -ne $PwshProfileGuid) { $changes += 'default profile -> PowerShell' }

    $prof = $profilesProp.Value
    $defaults = $null; $font = $null; $face = $null
    if ($prof.PSObject.Properties['defaults']) { $defaults = $prof.defaults }
    if ($defaults -and $defaults.PSObject.Properties['font']) { $font = $defaults.font }
    if ($font -and $font.PSObject.Properties['face']) { $face = $font.face }
    if ($face -ne $NerdFontFace) { $changes += "font -> $NerdFontFace" }

    if ($changes.Count -eq 0) {
        Write-Info "Windows Terminal already defaults to PowerShell with $NerdFontFace."
        return
    }
    Backup-Path $settings -Copy
    RunBlock "Windows Terminal settings.json: $($changes -join ', ')" {
        if ($null -eq $current) { $json | Add-Member -NotePropertyName defaultProfile -NotePropertyValue $PwshProfileGuid }
        else { $json.defaultProfile = $PwshProfileGuid }
        if ($null -eq $defaults) { $defaults = New-Object psobject; $prof | Add-Member -NotePropertyName defaults -NotePropertyValue $defaults }
        if ($null -eq $font) { $font = New-Object psobject; $defaults | Add-Member -NotePropertyName font -NotePropertyValue $font }
        if ($font.PSObject.Properties['face']) { $font.face = $NerdFontFace }
        else { $font | Add-Member -NotePropertyName face -NotePropertyValue $NerdFontFace }
        $text = $json | ConvertTo-Json -Depth 32
        [IO.File]::WriteAllText($settings, $text, (New-Object System.Text.UTF8Encoding($false)))
    }
    Write-Info "Windows Terminal: $($changes -join ', ')."
}

function Invoke-LayerDotfiles {
    Write-Step "Dotfiles"

    if (Test-SymlinkAbility) {
        $git = Join-Path $CommonDir 'git'
        New-FileLink (Join-Path $git 'gitconfig')               (Join-Path $HOME '.gitconfig')
        New-FileLink (Join-Path $git 'ignore')                  (Join-Path $HOME '.config\git\ignore')
        if (Test-Command delta) {
            New-FileLink (Join-Path $git 'delta.gitconfig')     (Join-Path $HOME '.config\git\delta.gitconfig')
        }
        else {
            Write-Info "delta not on PATH; git keeps its default pager. Re-run -Only dotfiles once it is installed."
        }
        New-FileLink (Join-Path $CommonDir 'starship.toml')     (Join-Path $HOME '.config\starship.toml')

        # profile.ps1 is PowerShell 7's all-hosts profile. shell-ux.ps1 is found
        # through $PSScriptRoot, the directory of the link, so it is linked
        # alongside. Windows PowerShell 5.1 is left with its own profile.
        $pwshDir = Join-Path $Documents 'PowerShell'
        foreach ($name in @('profile.ps1', 'shell-ux.ps1')) {
            New-FileLink (Join-Path $ScriptDir "dotfiles\powershell\$name") (Join-Path $pwshDir $name)
        }
    }
    else {
        Write-Err "This shell cannot create file symlinks: it is not elevated and Developer Mode is off."
        Write-Err "Turn on Settings > System > For developers > Developer Mode (or open an elevated"
        Write-Err "shell), then re-run with: .\install.ps1 -Only dotfiles"
    }

    Set-TerminalDefaults

    # Machine-local by design: identity, a work identity and per-machine env do
    # not belong in a shared baseline. All optional: git ignores a missing
    # include, profile.ps1 guards its dot-source.
    if (Test-Path -LiteralPath (Join-Path $HOME '.gitconfig-local')) {
        Write-Info "~\.gitconfig-local present (machine-local, not managed here)."
    }
    else {
        Write-Warn "No ~\.gitconfig-local. Git has no identity, so commits will fail with"
        Write-Warn "  'unable to auto-detect email address'. Create it with:"
        Write-Host '    "[user]`n`tname = NAME`n`temail = EMAIL" | Set-Content ~\.gitconfig-local'
        Write-Warn "  then 'gh auth setup-git', which writes its credential helper into ~\.gitconfig:"
        Write-Warn "  move that block into ~\.gitconfig-local too."
    }
    if (Test-Path -LiteralPath (Join-Path $HOME '.gitconfig-work')) {
        Write-Info "~\.gitconfig-work present (machine-local, not managed here)."
    }
    else {
        Write-Info "No ~\.gitconfig-work; repos under ~\work\ or ~\development\work\ use the default identity."
    }
    if (Test-Path -LiteralPath (Join-Path $HOME '.powershell.local.ps1')) {
        Write-Info "~\.powershell.local.ps1 present (machine-local, not managed here)."
    }
    else {
        Write-Info "No ~\.powershell.local.ps1; add one for per-machine shell setup and secrets."
    }
}

# --- Layer: tooling ----------------------------------------------------------

# golang.org/x/tools/gopls -> gopls; .../golangci-lint/v2/cmd/golangci-lint -> golangci-lint.
function Get-GoBinaryName {
    param([string]$Module)
    $path = ($Module -split '@')[0]
    $parts = @($path -split '/')
    $last = $parts[-1]
    if ($last -match '^v\d+$' -and $parts.Count -gt 1) { $last = $parts[-2] }
    return $last
}

function Invoke-LayerTooling {
    Write-Step "PowerShell modules, Go tools, npm globals, uv Pythons"

    # Installed from inside pwsh 7 so they land on its module path; the user
    # module path of Windows PowerShell is invisible to pwsh.
    $modules = @(Get-ProfileEntries 'psmodule')
    if ($modules.Count -gt 0) {
        if (Test-Command pwsh) {
            $present = @((Invoke-Capture @('pwsh', '-NoProfile', '-NonInteractive', '-Command',
                'Get-InstalledPSResource -Scope CurrentUser | Select-Object -ExpandProperty Name')).Output |
                ForEach-Object { $_.ToLowerInvariant() })
            foreach ($name in $modules) {
                if ($present -contains $name.ToLowerInvariant()) { Write-Info "PowerShell module $name already installed." }
                else {
                    Write-Info "Install-PSResource $name (in pwsh)"
                    Run @('pwsh', '-NoProfile', '-NonInteractive', '-Command',
                        "Install-PSResource -Name '$name' -Scope CurrentUser -Repository PSGallery -TrustRepository -Quiet") | Out-Null
                }
            }
        }
        else { Write-Warn "pwsh not on PATH; skipping PowerShell modules. Run the packages layer first." }
    }

    $goModules = @(Get-ProfileEntries 'go')
    if ($goModules.Count -gt 0) {
        if (Test-Command go) {
            $goBin = Join-Path ((Invoke-Capture @('go', 'env', 'GOPATH')).Output | Select-Object -First 1) 'bin'
            foreach ($module in $goModules) {
                $name = Get-GoBinaryName $module
                if (Test-Path -LiteralPath (Join-Path $goBin "$name.exe")) { Write-Info "$name already installed." }
                else {
                    Write-Info "go install $module"
                    Run @('go', 'install', $module) | Out-Null
                }
            }
        }
        else { Write-Warn "go not on PATH; skipping Go tools. Run the packages layer first." }
    }

    $npmPackages = @(Get-ProfileEntries 'npm')
    if ($npmPackages.Count -gt 0) {
        if (Test-Command npm) {
            $present = @()
            $json = (Invoke-Capture @('npm', 'ls', '-g', '--depth=0', '--json')).Output -join "`n"
            if ($json.Trim()) {
                $tree = $json | ConvertFrom-Json
                if ($tree.PSObject.Properties['dependencies']) { $present = @($tree.dependencies.PSObject.Properties.Name) }
            }
            foreach ($pkg in $npmPackages) {
                if ($present -contains $pkg) { Write-Info "npm: $pkg already installed." }
                else {
                    Write-Info "npm install -g $pkg"
                    Run @('npm', 'install', '-g', $pkg) | Out-Null
                }
            }
        }
        else { Write-Warn "npm not on PATH; skipping npm globals. Run the packages layer first." }
    }

    $pythons = @(Get-ProfileEntries 'uv-python')
    if ($pythons.Count -gt 0) {
        if (Test-Command uv) {
            $installed = @((Invoke-Capture @('uv', 'python', 'list', '--only-installed')).Output)
            foreach ($v in $pythons) {
                if (@($installed | Where-Object { $_ -match "^cpython-$([regex]::Escape($v))\." }).Count -gt 0) {
                    Write-Info "Python $v already installed."
                }
                else {
                    Write-Info "uv python install $v"
                    Run @('uv', 'python', 'install', $v) | Out-Null
                }
            }
        }
        else { Write-Warn "uv not on PATH; skipping Python. Run the packages layer first." }
    }

    Write-Step "Manual steps this script deliberately leaves to you"
    Write-Host "  gh auth login          # then move what it writes into ~\.gitconfig (a link into"
    Write-Host "                         # this repo) over to ~\.gitconfig-local"
    Write-Host "  ~\.gitconfig-local     # your git identity; see the dotfiles layer's message"
    Write-Host "  ssh keys               # not in this repo; generate or restore your own"
    Write-Host "  Developer Mode         # Settings > System > For developers; symlinks without elevation"
    Write-Host "  Docker Desktop         # containers profile: launch once; it provisions its WSL distro"
    Write-Host "  devshell               # cpp profile: run in pwsh to put MSVC on PATH for that session"
}

# --- Layer: extensions -------------------------------------------------------

function Invoke-LayerExtensions {
    Write-Step "VS Code extensions"

    $ids = @(Get-ProfileEntries 'vscode')
    if ($ids.Count -eq 0) {
        Write-Info "No extensions in the selected profiles."
        return
    }
    if (-not (Test-Command 'code')) {
        Write-Warn "VS Code CLI ('code') not on PATH; skipping. Open a new shell after the packages layer."
        return
    }

    # One listing up front, so a re-run costs one call instead of one per extension.
    $present = @((Invoke-Capture @('code', '--list-extensions')).Output | ForEach-Object { $_.ToLowerInvariant() })

    $already = 0; $added = 0; $failed = 0
    foreach ($id in $ids) {
        if ($present -contains $id.ToLowerInvariant()) { $already++; continue }
        if ($DryRun) {
            Write-Host "  + code --install-extension $id"
            $added++
            continue
        }
        $r = Invoke-Capture @('code', '--install-extension', $id)
        if ($r.ExitCode -eq 0) { Write-Host "  installed $id"; $added++ }
        else { Write-Warn "  failed: $id"; $failed++ }
    }
    Write-Info "VS Code: $($ids.Count) listed, $already already present, $added installed, $failed failed."
    if ($failed -gt 0) { Write-Warn "Failures are usually extensions that were unpublished or renamed." }
}

# --- Main --------------------------------------------------------------------

function Invoke-Main {
    if ($DryRun) {
        Write-Info "DRY RUN - nothing is changed. Mutating commands are printed with '+'."
    }
    $layerText = $Layers -join ' '
    if (-not $layerText) { $layerText = 'none' }
    Write-Info "Profiles: $($SelectedProfiles -join ' ')"
    if ($SelectedProfiles.Count -eq 1) {
        Write-Info "  Core only. Add any of these with -Profile: $($AvailableProfiles -join ', ')"
    }
    Write-Info "Layers: $layerText"

    Invoke-Preflight

    if (Wants 'packages')   { Invoke-LayerPackages }
    if (Wants 'vs')         { Invoke-LayerVs }
    if (Wants 'dotfiles')   { Invoke-LayerDotfiles }
    if (Wants 'tooling')    { Invoke-LayerTooling }
    if (Wants 'extensions') { Invoke-LayerExtensions }

    Write-Step "Done"
    if (Test-Path -LiteralPath $BackupDir) {
        Write-Info "Replaced files were backed up to $BackupDir"
    }
    Write-Info "Open a new terminal: installers append to PATH, and this shell cannot see that."
}

Invoke-Main
