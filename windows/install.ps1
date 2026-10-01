#Requires -Version 5.1
<#
.SYNOPSIS
Rebuild this Windows machine's development environment from the snapshot in
this directory.

.DESCRIPTION
  .\install.ps1                          # every layer
  .\install.ps1 -Only winget,dotfiles    # just those layers
  .\install.ps1 -Skip extensions         # everything but that layer
  .\install.ps1 -DryRun                  # print every mutating command, run none

A fresh Windows install refuses to run local scripts until the execution
policy allows it; this form works regardless:

  powershell -ExecutionPolicy Bypass -File .\install.ps1 -DryRun

Preflight (winget, git, elevation, symlink ability) always runs; every other
layer depends on it. Every layer is safe to re-run: it inspects the current
state, skips what is already satisfied, and says what it skipped.

Written for the Windows PowerShell 5.1 that ships with Windows - no ternary,
no &&, no $IsWindows, every function result wrapped in @() - so it runs on a
box where nothing has been installed yet. Kept ASCII-only because 5.1 reads a
BOM-less file as the ANSI code page.
#>
[CmdletBinding()]
param(
    [string[]]$Only,
    [string[]]$Skip,
    [switch]$DryRun,
    [switch]$Help
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$ScriptDir = $PSScriptRoot
$ClaudeConfigRepo = Join-Path $HOME 'development\claude\claude'
$BackupDir = Join-Path $HOME ".dotfiles-backup-$(Get-Date -Format yyyyMMdd-HHmmss)"
# Honours a Documents folder redirected into OneDrive, which is where
# PowerShell itself looks for profiles.
$Documents = [Environment]::GetFolderPath('MyDocuments')
$WindowsTerminalState = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState'

# vsconfig\vs<year>-<product>.vsconfig -> the installer's version range and product id.
$VsMajorByYear = @{ '2019' = 16; '2022' = 17; '2026' = 18 }
$VsProductId = @{ 'community' = 'Community'; 'professional' = 'Professional'; 'enterprise' = 'Enterprise'; 'buildtools' = 'BuildTools' }

$AllLayers = @('winget', 'choco', 'vs', 'dotfiles', 'tooling', 'extensions')
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
        else { & $exe @rest }
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

# --- Argument parsing --------------------------------------------------------

function Show-Usage {
    @"
Usage: install.ps1 [options]

  -Only  <layers>   Run only these layers (comma-separated).
  -Skip  <layers>   Run every layer except these.
  -DryRun           Print every mutating command without running it.
  -Help             This message.

Layers: $($AllLayers -join ', ')
"@ | Write-Host
}

function ConvertTo-LayerList {
    param([string[]]$Raw)
    $out = @()
    foreach ($chunk in $Raw) {
        foreach ($name in ($chunk -split ',')) {
            $n = $name.Trim().ToLowerInvariant()
            if (-not $n) { continue }
            if ($AllLayers -notcontains $n) {
                Write-Err "Unknown layer '$n'. Valid: $($AllLayers -join ', ')"
                exit 2
            }
            $out += $n
        }
    }
    return $out
}

if ($Help) { Show-Usage; exit 0 }
if ($Only) { $Layers = @(ConvertTo-LayerList $Only) }
if ($Skip) {
    $skipping = @(ConvertTo-LayerList $Skip)
    $Layers = @($Layers | Where-Object { $skipping -notcontains $_ })
}
# Always in canonical order, whatever order -Only listed them in.
$Layers = @($AllLayers | Where-Object { $Layers -contains $_ })

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
    if ($script:Elevated) { Write-Info "Running elevated: choco and file symlinks are available." }
    else { Write-Info "Not elevated: the choco layer will be skipped." }
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
        # The installer appends to the machine PATH; this process does not see that yet.
        $gitCmd = Join-Path $env:ProgramFiles 'Git\cmd'
        if (Test-Path -LiteralPath $gitCmd) { $env:Path = "$gitCmd;$env:Path" }
        if (-not (Test-Command git) -and -not $DryRun) {
            Write-Err "git still not on PATH. Open a new shell and re-run."
            exit 1
        }
    }
}

# --- Layer: winget -----------------------------------------------------------

# What winget considers installed, keyed "id" (winget source) or "id source".
# `winget export` is the only view that is not a truncated fixed-width table.
function Get-WingetInstalled {
    $tmp = Join-Path $env:TEMP "winget-export-$PID.json"
    $r = Invoke-Capture @('winget', 'export', '-o', $tmp, '--accept-source-agreements', '--disable-interactivity')
    if (-not (Test-Path -LiteralPath $tmp)) { throw "winget export produced no file (exit $($r.ExitCode))." }
    $json = Get-Content -LiteralPath $tmp -Raw | ConvertFrom-Json
    Remove-Item -LiteralPath $tmp -Force
    $keys = @()
    foreach ($source in @($json.Sources)) {
        $sourceName = $source.SourceDetails.Name
        foreach ($pkg in @($source.Packages)) {
            if ($sourceName -eq 'winget') { $keys += $pkg.PackageIdentifier.ToLowerInvariant() }
            else { $keys += "$($pkg.PackageIdentifier) $sourceName".ToLowerInvariant() }
        }
    }
    return $keys
}

function Invoke-LayerWinget {
    Write-Step "winget packages"

    $list = Join-Path $ScriptDir 'winget-packages.txt'
    $entries = @(Get-Entries $list)
    if ($entries.Count -eq 0) {
        Write-Err "No entries in $list"
        exit 1
    }
    $fromStore = @($entries | Where-Object { $_ -match '\s' }).Count
    Write-Info "Applying winget-packages.txt: $($entries.Count) packages ($($entries.Count - $fromStore) winget, $fromStore msstore)."

    Write-Info "Asking winget what is installed (winget export; read-only, takes a while)."
    $present = @(Get-WingetInstalled)

    $already = 0; $added = 0; $failed = 0
    foreach ($entry in $entries) {
        $parts = $entry -split ' '
        $id = $parts[0]
        $source = 'winget'
        if ($parts.Count -gt 1) { $source = $parts[1] }

        if ($present -contains $entry.ToLowerInvariant()) { $already++; continue }

        # Installing a package winget already knows would upgrade it; the
        # presence check above is what keeps this a no-upgrade install.
        $code = Run @('winget', 'install', '--id', $id, '--exact', '--source', $source,
            '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
        if ($code -eq 0) { $added++ } else { Write-Warn "  failed ($code): $id"; $failed++ }
    }
    Write-Info "winget: $($entries.Count) listed, $already already present, $added installed, $failed failed."
    if ($failed -gt 0) {
        Write-Warn "Failures are usually an installer that insists on a prompt, or an id that was renamed;"
        Write-Warn "`winget search <name>` finds the current id."
    }
    Write-Info "Visual Studio entries install the default workloads only; the vs layer adds the rest."
}

# --- Layer: choco ------------------------------------------------------------

function Invoke-LayerChoco {
    Write-Step "Chocolatey packages"

    if (-not $script:Elevated) {
        Write-Warn "Chocolatey installs into C:\ProgramData and needs an elevated shell; skipping."
        Write-Warn "Re-run from an elevated PowerShell with: .\install.ps1 -Only choco"
        return
    }

    if (-not (Test-Command choco)) {
        Write-Warn "Chocolatey missing; installing."
        RunBlock "Install Chocolatey via https://community.chocolatey.org/install.ps1" {
            Set-ExecutionPolicy Bypass -Scope Process -Force
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
            Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        }
        $chocoBin = Join-Path $env:ProgramData 'chocolatey\bin'
        if (Test-Path -LiteralPath $chocoBin) { $env:Path = "$chocoBin;$env:Path" }
        if (-not (Test-Command choco) -and -not $DryRun) {
            Write-Err "choco still not on PATH. Open a new elevated shell and re-run with -Only choco."
            return
        }
    }

    $entries = @(Get-Entries (Join-Path $ScriptDir 'choco-packages.txt'))
    $present = @()
    if (Test-Command choco) {
        $present = @((Invoke-Capture @('choco', 'list', '--limit-output')).Output |
            Where-Object { $_ -match '\|' } | ForEach-Object { (($_ -split '\|')[0]).ToLowerInvariant() })
    }

    $already = 0; $added = 0; $failed = 0
    foreach ($name in $entries) {
        if ($present -contains $name.ToLowerInvariant()) { $already++; continue }
        $code = Run @('choco', 'install', $name, '-y', '--no-progress')
        if ($code -eq 0) { $added++ } else { Write-Warn "  failed ($code): $name"; $failed++ }
    }
    Write-Info "choco: $($entries.Count) listed, $already already present, $added installed, $failed failed."
}

# --- Layer: vs ---------------------------------------------------------------
#
# winget installs Visual Studio with its default workloads. vsconfig\ holds
# the real component selection, exported per product by snapshot.ps1; the
# installer's `modify --config` adds whatever is missing. vswhere -requires
# answers "is every listed component present" without launching the installer.

function Invoke-LayerVs {
    Write-Step "Visual Studio workloads"

    $installer = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer'
    $vswhere = Join-Path $installer 'vswhere.exe'
    $setup = Join-Path $installer 'setup.exe'
    if (-not ((Test-Path -LiteralPath $vswhere) -and (Test-Path -LiteralPath $setup))) {
        Write-Warn "Visual Studio Installer not found; the winget layer installs Visual Studio."
        Write-Warn "Re-run with -Only vs afterwards."
        return
    }

    # Extension check rather than -Filter: under Windows PowerShell -Filter also
    # matches editor backups like x.vsconfig~ through their 8.3 short names.
    $configs = @(Get-ChildItem -LiteralPath (Join-Path $ScriptDir 'vsconfig') -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq '.vsconfig' })
    if ($configs.Count -eq 0) {
        Write-Info "No vsconfig\*.vsconfig files; nothing to do."
        return
    }

    foreach ($cfg in $configs) {
        if ($cfg.BaseName -notmatch '^vs(\d{4})-([a-z]+)$') {
            Write-Warn "$($cfg.Name): name is not vs<year>-<product>.vsconfig; skipped."
            continue
        }
        $year = $Matches[1]; $productKey = $Matches[2]
        if (-not $VsMajorByYear.ContainsKey($year) -or -not $VsProductId.ContainsKey($productKey)) {
            Write-Warn "$($cfg.Name): unknown year or product; skipped."
            continue
        }
        $major = $VsMajorByYear[$year]
        $productId = "Microsoft.VisualStudio.Product.$($VsProductId[$productKey])"
        $range = "[$major.0,$($major + 1).0)"

        $installPath = (Invoke-Capture @($vswhere, '-products', $productId, '-version', $range, '-property', 'installationPath')).Output | Select-Object -First 1
        if (-not $installPath) {
            Write-Info "$($cfg.BaseName): product not installed; skipped (the winget layer installs it)."
            continue
        }

        $components = @((Get-Content -LiteralPath $cfg.FullName -Raw | ConvertFrom-Json).components)
        $args = @($vswhere, '-products', $productId, '-version', $range, '-requires') + $components + @('-property', 'installationPath')
        $satisfied = (Invoke-Capture $args).Output | Select-Object -First 1
        if ($satisfied) {
            Write-Info "$($cfg.BaseName): all $($components.Count) components present."
            continue
        }

        Write-Info "$($cfg.BaseName): adding missing components (the installer elevates itself and may prompt)."
        $code = Run @($setup, 'modify', '--installPath', $installPath, '--config', $cfg.FullName, '--passive', '--norestart')
        if ($code -ne 0) { Write-Warn "  setup.exe modify exited $code for $($cfg.BaseName)." }
    }
}

# --- Layer: dotfiles ---------------------------------------------------------

# Backups keep the path relative to $HOME (or the drive root when outside it),
# so the two profile.ps1 files cannot collide in the flat backup directory.
function Backup-Path {
    param([string]$Path)
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
    RunBlock "Move $Path -> $dest" {
        $parent = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Move-Item -LiteralPath $Path -Destination $dest -Force
    }
}

function Link-File {
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

function Link-Directory {
    param([string]$Source, [string]$Target)

    $item = Get-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
    if (Test-LinkedTo -Item $item -Source $Source -LinkTypes @('Junction', 'SymbolicLink')) {
        Write-Info "$(Split-Path -Leaf $Target) already linked."
        return
    }
    if ($null -ne $item) { Backup-Path $Target }

    $parent = Split-Path -Parent $Target
    if (-not (Test-Path -LiteralPath $parent)) {
        RunBlock "New-Item -ItemType Directory $parent" { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    }
    RunBlock "New-Item -ItemType Junction $Target -> $Source" {
        New-Item -ItemType Junction -Path $Target -Target $Source | Out-Null
    }
    Write-Info "Linked $Target -> $Source (junction)"
}

function Invoke-LayerDotfiles {
    Write-Step "Dotfiles"

    $d = Join-Path $ScriptDir 'dotfiles'
    if (-not (Test-Path -LiteralPath $d)) {
        Write-Err "dotfiles\ not found at $d"
        exit 1
    }

    # Directory links never need a privilege.
    Link-Directory (Join-Path $d 'git-global-hooks') (Join-Path $HOME '.git-global-hooks')

    if (Test-SymlinkAbility) {
        Link-File (Join-Path $d 'gitconfig')           (Join-Path $HOME '.gitconfig')
        Link-File (Join-Path $d 'config\git\ignore')   (Join-Path $HOME '.config\git\ignore')
        Link-File (Join-Path $d 'config\starship.toml') (Join-Path $HOME '.config\starship.toml')
        Link-File (Join-Path $d 'bashrc')              (Join-Path $HOME '.bashrc')
        Link-File (Join-Path $d 'profile')             (Join-Path $HOME '.profile')
        Link-File (Join-Path $d 'condarc')             (Join-Path $HOME '.condarc')

        # PowerShell 7 reads Documents\PowerShell, Windows PowerShell 5.1 reads
        # Documents\WindowsPowerShell; profile.ps1 is all-hosts, the other file
        # console-host only. shell-ux.ps1 is found via $PSScriptRoot, which is
        # the directory of the link, so it must be linked alongside.
        $pwshDir = Join-Path $Documents 'PowerShell'
        foreach ($name in @('profile.ps1', 'Microsoft.PowerShell_profile.ps1', 'shell-ux.ps1')) {
            Link-File (Join-Path (Join-Path $d 'powershell') $name) (Join-Path $pwshDir $name)
        }
        $wpsDir = Join-Path $Documents 'WindowsPowerShell'
        foreach ($name in @('profile.ps1', 'Microsoft.PowerShell_profile.ps1')) {
            Link-File (Join-Path (Join-Path $d 'windowspowershell') $name) (Join-Path $wpsDir $name)
        }

        # Windows Terminal creates LocalState on first launch; before that there
        # is nowhere to put the link.
        if (Test-Path -LiteralPath $WindowsTerminalState) {
            Link-File (Join-Path $d 'windows-terminal\settings.json') (Join-Path $WindowsTerminalState 'settings.json')
        }
        else {
            Write-Warn "Windows Terminal has never been launched (no LocalState folder); skipping its settings.json."
            Write-Warn "Launch it once, then re-run with -Only dotfiles."
        }
    }
    else {
        Write-Err "This shell cannot create file symlinks: it is not elevated and Developer Mode is off."
        Write-Err "Turn on Settings > System > For developers > Developer Mode (or open an elevated"
        Write-Err "shell), then re-run with: .\install.ps1 -Only dotfiles"
        Write-Err "Skipped: .gitconfig, .config\git\ignore, starship.toml, .bashrc, .profile, .condarc,"
        Write-Err "both PowerShell profiles, Windows Terminal settings.json."
    }

    # These are machine-local by design: a personal identity, a work identity,
    # and per-machine env do not belong in a portable snapshot. All optional:
    # git ignores a missing include, both profiles guard their dot-source.
    if (Test-Path -LiteralPath (Join-Path $HOME '.gitconfig-local')) {
        Write-Info "~\.gitconfig-local present (machine-local, not managed here)."
    }
    else {
        Write-Warn "No ~\.gitconfig-local. Git has no identity, so commits will fail with"
        Write-Warn "  'unable to auto-detect email address'. Create it with:"
        Write-Host '    "[user]`n`tname = NAME`n`temail = EMAIL" | Set-Content ~\.gitconfig-local'
        Write-Warn "  then `gh auth setup-git`, which writes its credential helper into ~\.gitconfig:"
        Write-Warn "  move that block into ~\.gitconfig-local too."
    }
    if (Test-Path -LiteralPath (Join-Path $HOME '.gitconfig-work')) {
        Write-Info "~\.gitconfig-work present (machine-local, not managed here)."
    }
    else {
        Write-Info "No ~\.gitconfig-work; ~\development\work\ repos use the default git identity."
    }
    if (Test-Path -LiteralPath (Join-Path $HOME '.powershell.local.ps1')) {
        Write-Info "~\.powershell.local.ps1 present (machine-local, not managed here)."
    }
    else {
        Write-Info "No ~\.powershell.local.ps1; add one for per-machine env both PowerShell profiles should load."
    }
    if (Test-Path -LiteralPath (Join-Path $HOME '.bashrc.local')) {
        Write-Info "~\.bashrc.local present (machine-local, not managed here)."
    }
    else {
        Write-Info "No ~\.bashrc.local; add one for per-machine env Git Bash should load."
    }

    # ~\.claude\scripts reads GEMINI_API_KEY. The value is a secret and is
    # deliberately absent from this repo; the User environment is where the
    # profiles expect it.
    if ([Environment]::GetEnvironmentVariable('GEMINI_API_KEY', 'User')) {
        Write-Info "GEMINI_API_KEY is set in the User environment."
    }
    else {
        Write-Warn "GEMINI_API_KEY is not in the User environment; ~\.claude\scripts\ask_cheap.py will fail. Set it with:"
        Write-Host "    [Environment]::SetEnvironmentVariable('GEMINI_API_KEY', '<value>', 'User')"
    }
}

# --- Layer: tooling ----------------------------------------------------------

# golang.org/x/tools/gopls -> gopls; github.com/sigstore/cosign/v2/cmd/cosign -> cosign.
function Get-GoBinaryName {
    param([string]$Module)
    $path = ($Module -split '@')[0]
    $parts = @($path -split '/')
    $last = $parts[-1]
    if ($last -match '^v\d+$' -and $parts.Count -gt 1) { $last = $parts[-2] }
    return $last
}

function Invoke-LayerTooling {
    Write-Step "Go tools, npm globals, dotnet tools, PowerShell modules, ~\.claude"

    $entries = @(Get-Entries (Join-Path $ScriptDir 'tools.txt'))
    $byKind = @{ go = @(); npm = @(); dotnet = @(); psmodule = @() }
    foreach ($entry in $entries) {
        $parts = $entry -split ' ', 2
        if ($parts.Count -ne 2 -or -not $byKind.ContainsKey($parts[0])) {
            Write-Warn "tools.txt: cannot parse '$entry'; skipped."
            continue
        }
        $byKind[$parts[0]] += $parts[1]
    }

    if (Test-Command go) {
        $goBin = Join-Path ((Invoke-Capture @('go', 'env', 'GOPATH')).Output | Select-Object -First 1) 'bin'
        foreach ($module in $byKind['go']) {
            $exe = Join-Path $goBin "$(Get-GoBinaryName $module).exe"
            if (Test-Path -LiteralPath $exe) { Write-Info "$(Get-GoBinaryName $module) already installed." }
            else {
                Write-Info "go install $module"
                Run @('go', 'install', $module) | Out-Null
            }
        }
    }
    elseif ($byKind['go'].Count -gt 0) {
        Write-Warn "go not on PATH; skipping Go tools. Run the winget layer first."
    }

    if (Test-Command npm) {
        $present = @()
        $json = (Invoke-Capture @('npm', 'ls', '-g', '--depth=0', '--json')).Output -join "`n"
        if ($json.Trim()) {
            $tree = $json | ConvertFrom-Json
            if ($tree.PSObject.Properties['dependencies']) { $present = @($tree.dependencies.PSObject.Properties.Name) }
        }
        foreach ($pkg in $byKind['npm']) {
            if ($present -contains $pkg) { Write-Info "npm: $pkg already installed." }
            else {
                Write-Info "npm install -g $pkg"
                Run @('npm', 'install', '-g', $pkg) | Out-Null
            }
        }
    }
    elseif ($byKind['npm'].Count -gt 0) {
        Write-Warn "npm not on PATH; skipping npm globals. Run the winget layer first."
    }

    if (Test-Command dotnet) {
        $present = @()
        foreach ($row in (Invoke-Capture @('dotnet', 'tool', 'list', '-g')).Output) {
            if ($row -match '^(Package Id|-+)') { continue }
            if ($row -match '^(\S+)\s+\S+') { $present += $Matches[1].ToLowerInvariant() }
        }
        foreach ($id in $byKind['dotnet']) {
            if ($present -contains $id.ToLowerInvariant()) { Write-Info "dotnet tool $id already installed." }
            else {
                Write-Info "dotnet tool install -g $id"
                Run @('dotnet', 'tool', 'install', '-g', $id) | Out-Null
            }
        }
    }
    elseif ($byKind['dotnet'].Count -gt 0) {
        Write-Warn "dotnet not on PATH; skipping dotnet tools. Run the winget layer first."
    }

    # Installed from inside pwsh 7 so they land on its module path; the user
    # module path of Windows PowerShell is invisible to pwsh.
    if (Test-Command pwsh) {
        $present = @((Invoke-Capture @('pwsh', '-NoProfile', '-NonInteractive', '-Command',
            'Get-InstalledPSResource -Scope CurrentUser | Select-Object -ExpandProperty Name')).Output |
            ForEach-Object { $_.ToLowerInvariant() })
        foreach ($name in $byKind['psmodule']) {
            if ($present -contains $name.ToLowerInvariant()) { Write-Info "PowerShell module $name already installed." }
            else {
                Write-Info "Install-PSResource $name (in pwsh)"
                Run @('pwsh', '-NoProfile', '-NonInteractive', '-Command',
                    "Install-PSResource -Name '$name' -Scope CurrentUser -Repository PSGallery -TrustRepository -Quiet") | Out-Null
            }
        }
    }
    elseif ($byKind['psmodule'].Count -gt 0) {
        Write-Warn "pwsh not on PATH; skipping PowerShell modules. Run the winget layer first."
    }

    # ~\.claude is a junction to the config repo: the whole directory, runtime
    # state included, unlike the four per-directory links on macOS. See
    # ~\.claude\CLAUDE.md.
    $claudeDir = Join-Path $HOME '.claude'
    if (Test-Path -LiteralPath $ClaudeConfigRepo) {
        Link-Directory $ClaudeConfigRepo $claudeDir
    }
    else {
        Write-Warn "Claude config repo not found at $ClaudeConfigRepo."
        Write-Warn "Clone it, then re-run with -Only tooling:"
        Write-Host "    git clone git@github.com:shaia/claude.git $ClaudeConfigRepo"
    }

    Write-Step "Manual steps this script deliberately leaves to you"
    Write-Host "  gh auth login          # writes credential.helper into ~\.gitconfig, which is a"
    Write-Host "                         # symlink into this repo - move what it adds into"
    Write-Host "                         # ~\.gitconfig-local so the tracked file stays portable"
    Write-Host "  wsl --install -d Ubuntu  # elevated; enables the Windows features and reboots"
    Write-Host "  Docker Desktop         # first launch provisions the docker-desktop WSL distro"
    Write-Host "  Developer Mode         # Settings > System > For developers; symlinks without elevation"
    Write-Host "  ssh keys               # not in this repo; restore from your own backup, along with"
    Write-Host "                         # the ~\.ssh\config host alias ~\.gitconfig-local may rewrite to"
    Write-Host "  JetBrains Toolbox      # installs its IDEs itself; winget only installs the Toolbox"
    Write-Host "  rustup, uv, conda      # rustup-init installs stable; extra toolchains, uv-managed"
    Write-Host "                         # Pythons and conda envs are per-project, not snapshotted"
}

# --- Layer: extensions -------------------------------------------------------

function Install-Extensions {
    param([string]$Cmd, [string]$List, [string]$Label)

    if (-not (Test-Command $Cmd)) {
        Write-Warn "$Label CLI ('$Cmd') not on PATH; skipping. Open a new shell after the winget layer, or launch the app once."
        return
    }
    if (-not (Test-Path -LiteralPath $List)) {
        Write-Warn "$List not found; skipping $Label extensions."
        return
    }

    # One listing up front, so a re-run costs one call instead of ~90.
    $present = @((Invoke-Capture @($Cmd, '--list-extensions')).Output | ForEach-Object { $_.ToLowerInvariant() })

    $total = 0; $already = 0; $added = 0; $failed = 0
    foreach ($id in @(Get-Entries $List)) {
        $total++
        if ($present -contains $id.ToLowerInvariant()) { $already++; continue }
        if ($DryRun) {
            Write-Host "  + $Cmd --install-extension $id --force"
            $added++
            continue
        }
        $r = Invoke-Capture @($Cmd, '--install-extension', $id, '--force')
        if ($r.ExitCode -eq 0) { Write-Host "  installed $id"; $added++ }
        else { Write-Warn "  failed: $id"; $failed++ }
    }
    Write-Info "${Label}: $total listed, $already already present, $added installed, $failed failed."
    if ($failed -gt 0) { Write-Warn "${Label}: failures are usually extensions that were unpublished or renamed." }
}

function Invoke-LayerExtensions {
    Write-Step "Editor extensions"
    Install-Extensions -Cmd 'code'   -List (Join-Path $ScriptDir 'vscode-extensions.txt') -Label 'VS Code'
    Install-Extensions -Cmd 'cursor' -List (Join-Path $ScriptDir 'cursor-extensions.txt') -Label 'Cursor'
}

# --- Main --------------------------------------------------------------------

function Invoke-Main {
    if ($DryRun) {
        Write-Info "DRY RUN - nothing is changed. Mutating commands are printed with '+'."
    }
    $layerText = $Layers -join ' '
    if (-not $layerText) { $layerText = 'none' }
    Write-Info "Layers: $layerText"

    Invoke-Preflight

    if (Wants 'winget')     { Invoke-LayerWinget }
    if (Wants 'choco')      { Invoke-LayerChoco }
    if (Wants 'vs')         { Invoke-LayerVs }
    if (Wants 'dotfiles')   { Invoke-LayerDotfiles }
    if (Wants 'tooling')    { Invoke-LayerTooling }
    if (Wants 'extensions') { Invoke-LayerExtensions }

    Write-Step "Done"
    if (Test-Path -LiteralPath $BackupDir) {
        Write-Info "Replaced dotfiles were backed up to $BackupDir"
    }
    Write-Info "Open a new terminal: installers append to PATH, and this shell cannot see that."
}

Invoke-Main
