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

# winget writes UTF-8. Windows PowerShell 5.1 decodes child output with the ANSI
# code page and turns winget's progress spinner into scrolling garbage. Some
# hosts (redirected CI output) refuse the assignment; that is only cosmetic.
try {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [Console]::OutputEncoding = $utf8
    $OutputEncoding = $utf8
}
catch { }

$ScriptDir = $PSScriptRoot
$LogDir = Join-Path $HOME '.machines-setups\logs'
$RunStamp = Get-Date -Format yyyyMMdd-HHmmss
$RepoRoot = Split-Path -Parent $ScriptDir
$CommonDir = Join-Path $RepoRoot 'common'
$BackupDir = Join-Path $HOME ".dotfiles-backup-$RunStamp"
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

$AllLayers = @('packages', 'system', 'vs', 'dotfiles', 'tooling', 'extensions')
$WslDistro = 'Ubuntu'
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

# Run with retries for network-bound commands (winget, go, npm, uv, code):
# three attempts, 5 then 15 seconds apart. A dry run never retries, because
# Run returns 0 there.
function RunRetry {
    param([Parameter(Mandatory)][string[]]$Command)
    $delays = @(5, 15)
    $code = Run $Command
    $attempt = 0
    while ($code -ne 0 -and $attempt -lt $delays.Count) {
        Write-Warn "  '$($Command[0..([Math]::Min(2, $Command.Count - 1))] -join ' ')' exited $code; retrying in $($delays[$attempt])s."
        Start-Sleep -Seconds $delays[$attempt]
        $code = Run $Command
        $attempt++
    }
    return $code
}

# --- Results -------------------------------------------------------------------
#
# Every step records one outcome, printed as a summary at the end:
#   ok       already in the desired state; nothing ran
#   changed  applied, and the re-check after applying confirmed it
#   failed   applied, but the re-check still fails (or the command failed)
#   flagged  best-effort work that could not be done here; the run continues
#   manual   needs something this script deliberately does not do (elevation)
# Only `failed` makes the script exit non-zero.

$script:Results = New-Object System.Collections.ArrayList
$script:ElevatedCommands = New-Object System.Collections.ArrayList

function Add-Result {
    param([ValidateSet('ok', 'changed', 'failed', 'flagged', 'manual')][string]$Status, [string]$Name, [string]$Detail = '')
    [void]$script:Results.Add([pscustomobject]@{ Status = $Status; Name = $Name; Detail = $Detail })
}

# A machine-wide setting this shell cannot apply: queue its command for the
# "run these elevated" block at the end, and record it as manual.
function Add-ElevatedCommand {
    param([string]$Name, [string]$Command)
    [void]$script:ElevatedCommands.Add($Command)
    Add-Result manual $Name 'needs an elevated shell'
}

function Write-Summary {
    Write-Step "Summary"
    $counts = [ordered]@{ ok = 0; changed = 0; failed = 0; flagged = 0; manual = 0 }
    foreach ($r in $script:Results) { $counts[$r.Status]++ }
    Write-Host ("  {0} already fine, {1} changed, {2} failed, {3} flagged, {4} manual" -f
        $counts['ok'], $counts['changed'], $counts['failed'], $counts['flagged'], $counts['manual'])
    foreach ($status in @('failed', 'flagged', 'manual')) {
        foreach ($r in @($script:Results | Where-Object { $_.Status -eq $status })) {
            $line = "  [$($status.ToUpperInvariant())] $($r.Name)"
            if ($r.Detail) { $line += " - $($r.Detail)" }
            if ($status -eq 'failed') { Write-Host $line -ForegroundColor Red }
            else { Write-Host $line -ForegroundColor Yellow }
        }
    }
    if ($script:ElevatedCommands.Count -gt 0) {
        Write-Host ""
        Write-Host "  Run these once from an elevated PowerShell (or prefix each with gsudo or sudo):"
        foreach ($c in $script:ElevatedCommands) { Write-Host "    $c" }
    }
    return $counts['failed']
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
# Merges rather than replaces: entries this process already has (a Visual
# Studio developer shell, a CI tool cache) stay, and registry entries it
# lacks are appended.
function Update-SessionPath {
    $current = @($env:Path -split ';' | Where-Object { $_ })
    $known = @{}
    foreach ($e in $current) { $known[$e.TrimEnd('\').ToLowerInvariant()] = $true }
    $added = @()
    foreach ($scope in @('Machine', 'User')) {
        $value = [Environment]::GetEnvironmentVariable('Path', $scope)
        if (-not $value) { continue }
        foreach ($raw in ($value -split ';')) {
            if (-not $raw) { continue }
            # The registry keeps some entries unexpanded (%USERPROFILE%\...);
            # the session has them expanded, so compare the expanded form.
            $e = [Environment]::ExpandEnvironmentVariables($raw)
            $key = $e.TrimEnd('\').ToLowerInvariant()
            if (-not $known.ContainsKey($key)) { $known[$key] = $true; $added += $e }
        }
    }
    $env:Path = (@($current) + @($added)) -join ';'
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
            # Shared lines first. A Windows profile file may add its own vscode
            # lines too, for Windows-only extensions (Remote WSL, Hex Editor).
            $files = @(Join-Path $CommonDir "profiles\$p.txt")
            if ($Kind -eq 'vscode') { $files += Join-Path $ScriptDir "profiles\$p.txt" }
            foreach ($file in $files) {
                foreach ($e in @(Get-Entries $file)) {
                    $parts = $e -split ' ', 2
                    if ($parts.Count -eq 2 -and $parts[0] -eq $Kind) { $out += $parts[1] }
                }
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
# `requires <profile>` lines pull other profiles in (lowlevel needs cpp's
# compilers); expand until nothing new appears.
$wanted = @($requested)
do {
    $added = $false
    foreach ($p in @($wanted)) {
        foreach ($e in @(Get-Entries (Join-Path $ScriptDir "profiles\$p.txt"))) {
            $parts = $e -split ' ', 2
            if ($parts[0] -eq 'requires' -and $parts.Count -eq 2 -and $wanted -notcontains $parts[1]) {
                $wanted += $parts[1]; $added = $true
            }
        }
    }
} while ($added)
$SelectedProfiles = @('core') + @($AvailableProfiles | Where-Object { $wanted -contains $_ })

function Wants { param([string]$Layer) return ($Layers -contains $Layer) }

# --- Preflight ---------------------------------------------------------------
#
# Always runs. Its two mutating actions, switching winget's downloader to
# WinINet and installing git, are each guarded by "if not already so", so on
# an already-configured machine this is read-only.

$script:Elevated = $false
$script:DeveloperMode = $false

function Invoke-Preflight {
    Write-Step "Preflight"

    # A shell opened before an earlier run installed things has a stale PATH;
    # without this, a re-run from it cannot see uv, go or npm and skips their
    # steps.
    Update-SessionPath

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

    # Before any winget download, the git install just below included.
    Set-WingetDownloader

    if (Test-Command git) {
        Write-Info "git present at $((Get-Command git).Source)."
    }
    else {
        Write-Warn "git missing; installing Git.Git with winget."
        RunRetry @('winget', 'install', '--id', 'Git.Git', '--exact', '--source', 'winget',
            '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity') | Out-Null
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
    # winget's source refresh is network-bound and occasionally fails; one retry.
    foreach ($attempt in 1..2) {
        $r = Invoke-Capture @('winget', 'export', '-o', $tmp, '--accept-source-agreements', '--disable-interactivity')
        if (Test-Path -LiteralPath $tmp) { break }
        if ($attempt -eq 1) { Write-Warn "winget export failed (exit $($r.ExitCode)); retrying in 10s."; Start-Sleep -Seconds 10 }
    }
    if (-not (Test-Path -LiteralPath $tmp)) { throw "winget export produced no file (exit $($r.ExitCode))." }
    $json = Get-Content -LiteralPath $tmp -Raw | ConvertFrom-Json
    Remove-Item -LiteralPath $tmp -Force
    $keys = @()
    foreach ($source in @($json.Sources)) {
        foreach ($pkg in @($source.Packages)) { $keys += $pkg.PackageIdentifier.ToLowerInvariant() }
    }
    return $keys
}

# winget's own answer for one id: exit code 0 when it is installed.
function Test-WingetInstalled {
    param([string]$Id)
    $r = Invoke-Capture @('winget', 'list', '--id', $Id, '--exact', '--accept-source-agreements', '--disable-interactivity')
    return ($r.ExitCode -eq 0)
}

# Packages whose installer writes no uninstall entry, so neither winget list
# nor winget export ever sees them: presence is the file they install. NASM's
# per-user installer also leaves its directory off PATH, so this adds it.
$script:UnlistedPackages = @{
    'NASM.NASM' = Join-Path $env:LOCALAPPDATA 'bin\NASM\nasm.exe'
}

function Test-UnlistedPackage {
    param([string]$Id)
    $exe = $script:UnlistedPackages[$Id]
    if (-not $exe -or -not (Test-Path -LiteralPath $exe)) { return $false }
    $dir = Split-Path -Parent $exe
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (@($userPath -split ';' | Where-Object { $_.TrimEnd('\') -eq $dir }).Count -eq 0) {
        RunBlock "Add $dir to the user PATH" {
            $joined = (@($userPath -split ';' | Where-Object { $_ }) + $dir) -join ';'
            [Environment]::SetEnvironmentVariable('Path', $joined, 'User')
        }
    }
    return $true
}

# winget's own name for an install exit code (`winget error`, in winget 1.8+),
# plus what to do about the causes seen in practice.
function Get-WingetFailureReason {
    param([int]$Code)
    if ($Code -eq 0) { return "winget exited 0; the installer may need a reboot, or it registers nothing winget can see" }
    $hex = '0x{0:X8}' -f $Code
    $text = ((Invoke-Capture @('winget', 'error', $hex)).Output | Select-Object -First 1)
    $reason = "winget exited $hex"
    if ($text -match 'APPINSTALLER_CLI_ERROR_(\w+)') { $reason += " ($($Matches[1]))" }
    switch ($hex) {
        '0x8A150011' { $reason += '; the publisher replaced the download behind the manifest, so wait for winget-pkgs to update it or install from the vendor site' }
        '0x8A150014' { $reason += "; the id is gone, so 'winget search' may find it renamed" }
        '0x8A150101' { $reason += '; close the app and re-run' }
        '0x8A150109' { $reason += '; reboot and re-run' }
    }
    return $reason
}

# EarTrumpet ships only as an x86 MSIX, so it needs the x86 build of the UWP
# C++ runtime (Microsoft.VCLibs.140.00). winget treats the x64 build as
# satisfying that dependency, then the install fails with 0x80073cf3. Desktops
# usually have both builds; Windows Server images (CI runners) have only x64.
# Ask the Appx store for the x86 build itself, through Windows PowerShell,
# whose Appx module works everywhere.
function Test-X86UwpRuntime {
    $r = Invoke-Capture @('powershell', '-NoProfile', '-NonInteractive', '-Command',
        "@(Get-AppxPackage -Name 'Microsoft.VCLibs.140.00' | Where-Object { `$_.Architecture -eq 'X86' }).Count")
    $n = 0
    [void][int]::TryParse(([string]($r.Output | Select-Object -Last 1)).Trim(), [ref]$n)
    return ($n -gt 0)
}

function Install-X86UwpRuntime {
    $label = 'UWP C++ runtime, x86 (for EarTrumpet)'
    if (Test-X86UwpRuntime) { Add-Result ok $label; return }
    # --force: winget already counts the x64 build as this package installed.
    $code = RunRetry @('winget', 'install', '--id', 'Microsoft.VCLibs.14', '--exact', '--source', 'winget',
        '--architecture', 'x86', '--force', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    if ($DryRun) { Add-Result changed $label 'dry run'; return }
    if (Test-X86UwpRuntime) { Add-Result changed $label }
    else { Add-Result failed $label "winget exited $code; EarTrumpet will fail to install without it" }
}

# winget's default downloader, Delivery Optimization, can freeze partway
# through a large download and never recover (microsoft/winget-cli #4648 and
# #2124). On a fresh machine that shows up as the run hanging on Warp, the first
# large package in core; newer winget falls back after a minute without
# progress, but the winget a new machine ships with may predate that. WinINet
# is the downloader winget's maintainers point to. It is a per-user winget
# setting, so it is set before the first download.
function Get-WingetSettingsPath {
    # `winget --info` names the file (%LOCALAPPDATA% unexpanded). It differs
    # between the Store-packaged winget and an unpackaged one.
    foreach ($line in @((Invoke-Capture @('winget', '--info')).Output)) {
        if ($line -match '^\s*User Settings\s+(\S.*)$') {
            return [Environment]::ExpandEnvironmentVariables($Matches[1].Trim())
        }
    }
    return Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\settings.json'
}

# The settings file as an object, $null when it is missing or empty. winget
# allows // comments, which ConvertFrom-Json in Windows PowerShell rejects, so
# whole-line comments are dropped first. Throws when the rest is not JSON.
function Read-WingetSettings {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $text = [string](Get-Content -LiteralPath $Path -Raw)
    $text = $text -replace '(?m)^\s*//.*$', ''
    if (-not $text.Trim()) { return $null }
    return ($text | ConvertFrom-Json)
}

function Get-WingetDownloader {
    param($Settings)
    if ($null -eq $Settings) { return $null }
    $network = $Settings.PSObject.Properties['network']
    if ($null -eq $network -or $null -eq $network.Value) { return $null }
    $downloader = $network.Value.PSObject.Properties['downloader']
    if ($null -eq $downloader) { return $null }
    return [string]$downloader.Value
}

function Set-WingetDownloader {
    $label = 'winget downloader is WinINet'
    $path = Get-WingetSettingsPath
    try { $settings = Read-WingetSettings $path }
    catch {
        Add-Result flagged $label "cannot parse $path; set `"network`": { `"downloader`": `"wininet`" } in it by hand"
        return
    }
    if ((Get-WingetDownloader $settings) -eq 'wininet') { Add-Result ok $label; return }

    if (Test-Path -LiteralPath $path) { Backup-Path $path -Copy }
    RunBlock "Set network.downloader = wininet in $path" {
        $s = $settings
        if ($null -eq $s) { $s = New-Object psobject -Property @{ '$schema' = 'https://aka.ms/winget-settings.schema.json' } }
        if ($null -eq $s.PSObject.Properties['network'] -or $null -eq $s.network) {
            $s | Add-Member -NotePropertyName network -NotePropertyValue (New-Object psobject) -Force
        }
        $s.network | Add-Member -NotePropertyName downloader -NotePropertyValue 'wininet' -Force
        $dir = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::WriteAllText($path, ($s | ConvertTo-Json -Depth 16), (New-Object System.Text.UTF8Encoding($false)))
    }
    if ($DryRun) { Add-Result changed $label 'dry run'; return }
    $after = $null
    try { $after = Get-WingetDownloader (Read-WingetSettings $path) } catch { }
    if ($after -eq 'wininet') { Add-Result changed $label "in $path" }
    else { Add-Result failed $label "wrote $path but it reads back as '$after'" }
}

function Invoke-LayerPackages {
    Write-Step "winget packages"

    # The Visual C++ runtime many tools link against (uv among them), for the
    # machine's own architecture. Not in a profile file because the id differs
    # per architecture.
    $arch = 'x64'
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $arch = 'arm64' }
    $ids = @("Microsoft.VCRedist.2015+.$arch") + @(Get-ProfileEntries 'winget')
    Write-Info "$($ids.Count) packages across: $($SelectedProfiles -join ', ')."
    Write-Info "Asking winget what is installed (winget export; read-only)."
    $present = @(Get-WingetInstalled)

    if ($ids -contains 'File-New-Project.EarTrumpet' -and $present -notcontains 'file-new-project.eartrumpet') {
        Install-X86UwpRuntime
    }

    $already = 0; $added = 0; $failed = 0
    foreach ($id in $ids) {
        $name = "winget $id"
        if ($present -contains $id.ToLowerInvariant() -or (Test-UnlistedPackage $id)) { Add-Result ok $name; $already++; continue }
        # Installing a package winget already knows would upgrade it; the
        # presence check above is what keeps this a no-upgrade install.
        $code = RunRetry @('winget', 'install', '--id', $id, '--exact', '--source', 'winget',
            '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
        if ($DryRun) { Add-Result changed $name 'dry run'; $added++; continue }
        # Verify rather than trust the exit code: some installers report a
        # pending reboot as failure, and some failures exit 0.
        # winget list can miss a package that winget export does see (seen with
        # a portable package on a clean runner), and export is what the
        # presence check above uses, so it decides when the two disagree.
        if ((Test-WingetInstalled $id) -or (@(Get-WingetInstalled) -contains $id.ToLowerInvariant())) {
            Add-Result changed $name; $added++
        }
        elseif (Test-UnlistedPackage $id) {
            Add-Result changed $name; $added++
        }
        else {
            Add-Result failed $name "does not list it after install: $(Get-WingetFailureReason $code)"
            $failed++
        }
    }
    Write-Info "winget: $($ids.Count) listed, $already already present, $added installed, $failed failed."
    if ($added -gt 0 -and -not $DryRun) { Update-SessionPath }
}


# --- Layer: system -----------------------------------------------------------
#
# Windows settings every developer machine wants. Each is checked, applied, and
# checked again. Per-user settings are applied directly. Machine-wide ones are
# applied only from an elevated shell; otherwise their commands are collected
# for the summary, because nothing here elevates itself.

# A registry key created only when missing: New-Item -Force on an existing
# registry key replaces it, values and subkeys included.
function Initialize-RegistryKey {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
}

function Get-RegistryValue {
    param([string]$Path, [string]$Name)
    $item = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    $p = $item.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

# Returns $true when it changed the value (or would, in a dry run).
function Set-RegistrySetting {
    param([string]$Label, [string]$Path, [string]$Name, [int]$Value, [switch]$Machine)

    $current = Get-RegistryValue $Path $Name
    if ($null -ne $current -and [int]$current -eq $Value) {
        Add-Result ok $Label
        return $false
    }
    if ($Machine -and -not $script:Elevated) {
        $cmd = "Set-ItemProperty -Path '$Path' -Name $Name -Value $Value -Type DWord"
        if (-not (Test-Path -LiteralPath $Path)) { $cmd = "New-Item -Path '$Path' -Force | Out-Null; $cmd" }
        Add-ElevatedCommand $Label $cmd
        return $false
    }
    RunBlock "Set $Path $Name = $Value" {
        Initialize-RegistryKey $Path
        Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -Type DWord
    }
    if ($DryRun) { Add-Result changed $Label 'dry run'; return $true }
    $after = Get-RegistryValue $Path $Name
    if ($null -ne $after -and [int]$after -eq $Value) { Add-Result changed $Label }
    else { Add-Result failed $Label "wrote $Name = $Value but it reads back as '$after'" }
    return $true
}

function Invoke-LayerSystem {
    Write-Step "Windows settings"

    $explorer = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'
    $explorerChanged = $false

    # File Explorer: show extensions ("report.pdf.exe" stops looking like a PDF),
    # hidden files (.git, .vscode, .env), and the full path in the title bar.
    $explorerChanged = (Set-RegistrySetting 'Explorer shows file extensions' "$explorer\Advanced" 'HideFileExt' 0) -or $explorerChanged
    $explorerChanged = (Set-RegistrySetting 'Explorer shows hidden files' "$explorer\Advanced" 'Hidden' 1) -or $explorerChanged
    $explorerChanged = (Set-RegistrySetting 'Explorer shows the full path in the title bar' "$explorer\CabinetState" 'FullPath' 1) -or $explorerChanged
    # Taskbar: "End Task" on right-click, which kills a hung process without Task Manager.
    $explorerChanged = (Set-RegistrySetting 'Taskbar right-click offers End Task' "$explorer\Advanced\TaskbarDeveloperSettings" 'TaskbarEndTask' 1) -or $explorerChanged
    # Start search finds local files and apps, not Bing results.
    $explorerChanged = (Set-RegistrySetting 'Start search shows no web results' 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1) -or $explorerChanged
    if ($explorerChanged) { Write-Info "Explorer and taskbar changes show after signing out and back in, or restarting Explorer." }

    # Machine-wide. Long paths: deep node_modules, CMake and vcpkg build trees
    # exceed 260 characters and fail with "path not found"; core.longpaths in
    # common/git/gitconfig covers git, which ignores this setting.
    $null = Set-RegistrySetting 'Long path support' 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled' 1 -Machine
    # Developer Mode: file symlinks without elevation, which the dotfiles layer uses.
    $null = Set-RegistrySetting 'Developer Mode' 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' 'AllowDevelopmentWithoutDevLicense' 1 -Machine
    # Windows' own sudo, inline mode (runs in the current window). Builds without
    # sudo.exe skip this; gsudo from core covers them.
    if (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\sudo.exe')) {
        $null = Set-RegistrySetting 'Windows sudo, inline mode' 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo' 'Enabled' 3 -Machine
    }
    else {
        Write-Info "This Windows build has no built-in sudo; gsudo from core covers it."
    }

    Invoke-WslSetup
    if ($SelectedProfiles -contains 'lowlevel') { Invoke-HyperVSetup }
}

# Whether WSL 2 and Hyper-V have hardware virtualization to run on. With a
# hypervisor already running, the processor reports firmware virtualization
# as off, so a present hypervisor settles it first.
function Test-HardwareVirtualization {
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $hypervisor = ($null -ne $cs -and $cs.HypervisorPresent)
    $firmware = ($null -ne $cpu -and $cpu.VirtualizationFirmwareEnabled)
    return ($hypervisor -or $firmware)
}

$NoVirtualizationDetail = ('hardware virtualization is off: enable VT-x/AMD-V in the BIOS/UEFI, ' +
    'or on a VM expose nested virtualization (Hyper-V: Set-VMProcessor -ExposeVirtualizationExtensions $true)')

# WSL 2 with a Linux distro. Best-effort: a machine without hardware
# virtualization (or a VM without nested virtualization) cannot run it, and
# that must not fail the whole run.
function Invoke-WslSetup {
    $status = Invoke-Capture @('wsl.exe', '--status')
    if ($status.ExitCode -ne 0) {
        if (-not (Test-HardwareVirtualization)) {
            Add-Result flagged 'WSL 2' $NoVirtualizationDetail
            return
        }
        Add-ElevatedCommand 'WSL 2 platform' ('wsl --install --no-distribution   # then reboot and re-run -Only system. ' +
            'If that is unavailable: dism /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart; ' +
            'dism /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart')
        return
    }

    # Distros are read from the registry: `wsl -l` prints UTF-16. Docker
    # Desktop's own distros do not count.
    $distros = @(Get-WslDistros)
    if ($distros.Count -gt 0) {
        Add-Result ok "WSL 2 distro ($($distros -join ', '))"
        return
    }
    # `wsl --status` exits 0 even when it reports that the Virtual Machine
    # Platform is off, and right after enabling it (from winget installing
    # WSL or Docker) it stays unusable until a reboot, while `wsl --install -d`
    # still exits 0 without registering anything.
    $vmp = Get-CimInstance Win32_OptionalFeature -Filter "Name='VirtualMachinePlatform'" -ErrorAction SilentlyContinue
    if ($null -ne $vmp -and $vmp.InstallState -ne 1) {
        Add-ElevatedCommand 'WSL 2 platform' 'wsl --install --no-distribution   # then reboot and re-run -Only system'
        return
    }
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        Add-Result flagged "WSL 2 distro $WslDistro" 'Windows has a reboot pending, and WSL cannot start until it reboots; reboot and re-run -Only system'
        return
    }
    Write-Info "WSL 2 is enabled but has no distro; installing $WslDistro."
    $code = RunRetry @('wsl.exe', '--install', '-d', $WslDistro, '--no-launch')
    if ($code -ne 0 -and -not $DryRun) {
        # The Store route fails on machines without Store access.
        Write-Warn "  Store install exited $code; retrying with --web-download."
        $code = Run @('wsl.exe', '--install', '-d', $WslDistro, '--no-launch', '--web-download')
    }
    if ($DryRun) { Add-Result changed "WSL 2 distro $WslDistro" 'dry run'; return }
    if (@(Get-WslDistros) -contains $WslDistro) {
        Add-Result changed "WSL 2 distro $WslDistro" 'launch it once from the Start menu to create your Linux user'
    }
    else { Add-Result flagged "WSL 2 distro $WslDistro" "wsl --install exited $code" }
}

function Get-WslDistros {
    return @(Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction SilentlyContinue |
        ForEach-Object { (Get-ItemProperty $_.PSPath).PSObject.Properties['DistributionName'] } |
        Where-Object { $null -ne $_ } | ForEach-Object { $_.Value } |
        Where-Object { $_ -and $_ -notlike 'docker-desktop*' })
}

# Hyper-V, for the lowlevel profile: a VM is the safe target for kernel
# debugging with WinDbg and for test-loading drivers. Best-effort like WSL:
# Home editions have no Hyper-V, and it needs hardware virtualization.
$HyperVFeature = 'Microsoft-Hyper-V-All'

# 'Enabled', 'Disabled', 'EnablePending', or $null when this edition has no
# Hyper-V. Only DISM reports the pending state, and it needs elevation;
# Win32_OptionalFeature does not, so it answers for a non-elevated shell.
function Get-HyperVState {
    if ($script:Elevated) {
        try {
            $f = Get-WindowsOptionalFeature -Online -FeatureName $HyperVFeature -ErrorAction Stop
            if ($null -ne $f) { return [string]$f.State }
        }
        catch { }
    }
    $f = Get-CimInstance Win32_OptionalFeature -Filter "Name='$HyperVFeature'" -ErrorAction SilentlyContinue
    if ($null -eq $f) { return $null }
    if ($f.InstallState -eq 1) { return 'Enabled' }
    return 'Disabled'
}

function Invoke-HyperVSetup {
    $label = 'Hyper-V'
    $state = Get-HyperVState
    if ($null -eq $state) {
        Add-Result flagged $label 'this Windows edition has no Hyper-V; it needs Pro, Enterprise or Education'
        return
    }
    if ($state -eq 'Enabled') { Add-Result ok $label; return }
    if ($state -eq 'EnablePending') { Add-Result flagged $label 'enabled, but Windows has to reboot to finish'; return }
    if (-not (Test-HardwareVirtualization)) { Add-Result flagged $label $NoVirtualizationDetail; return }

    $command = @('dism.exe', '/online', '/enable-feature', "/featurename:$HyperVFeature", '/all', '/norestart')
    if (-not $script:Elevated) {
        Add-ElevatedCommand $label (($command -join ' ') + '   # then reboot')
        return
    }
    $code = Run $command
    if ($DryRun) { Add-Result changed $label 'dry run'; return }
    $after = Get-HyperVState
    if ($after -eq 'Enabled') { Add-Result changed $label }
    # 3010: enabled, and the reboot it needs is pending.
    elseif ($after -eq 'EnablePending' -or $code -eq 3010) { Add-Result changed $label 'reboot to finish enabling it' }
    else { Add-Result failed $label "dism exited $code and Hyper-V is still '$after'" }
}

# --- Layer: vs ---------------------------------------------------------------
#
# winget installs Visual Studio with its default workloads. Each profile that
# needs more ships vsconfig\<profile>.vsconfig (cpp: the C++ toolset; lowlevel:
# the WDK, Spectre-mitigated libraries and the Performance Toolkit); the
# installer's `modify --config` adds whatever is missing. vswhere -requires
# answers "is every listed component present" without launching the installer.

function Invoke-LayerVs {
    Write-Step "Visual Studio workloads"

    $configs = @($SelectedProfiles | ForEach-Object { Join-Path $ScriptDir "vsconfig\$_.vsconfig" } |
        Where-Object { Test-Path -LiteralPath $_ })
    if ($configs.Count -eq 0) {
        Write-Info "No selected profile needs Visual Studio workloads; nothing to do."
        return
    }
    $installer = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer'
    $vswhere = Join-Path $installer 'vswhere.exe'
    $setup = Join-Path $installer 'setup.exe'
    if (-not ((Test-Path -LiteralPath $vswhere) -and (Test-Path -LiteralPath $setup))) {
        Add-Result flagged 'Visual Studio workloads' 'Visual Studio Installer not found yet; re-run with the same -Profile and -Only vs after the packages layer'
        return
    }

    $installPath = (Invoke-Capture @($vswhere, '-products', $VsProductId, '-version', $VsVersionRange, '-property', 'installationPath')).Output | Select-Object -First 1
    if (-not $installPath) {
        Add-Result flagged 'Visual Studio workloads' 'Visual Studio 2026 Community is not installed yet; re-run -Only vs after the packages layer'
        return
    }

    foreach ($cfg in $configs) {
        $name = Split-Path -Leaf $cfg
        $components = @((Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json).components)
        $query = @($vswhere, '-products', $VsProductId, '-version', $VsVersionRange, '-requires') + $components + @('-property', 'installationPath')
        $satisfied = (Invoke-Capture $query).Output | Select-Object -First 1
        if ($satisfied) {
            Add-Result ok "Visual Studio $name ($($components.Count) components)"
            continue
        }
        # --passive does not elevate itself: from a non-elevated shell the
        # installer exits 5007 ("should be run elevated from the beginning").
        if (-not $script:Elevated) {
            Add-ElevatedCommand "Visual Studio $name" ("& '$setup' modify --installPath '$installPath' --config '$cfg' --passive --norestart")
            continue
        }
        Write-Info "${name}: adding missing components."
        $code = Run @($setup, 'modify', '--installPath', $installPath, '--config', $cfg, '--passive', '--norestart')
        if ($DryRun) { Add-Result changed "Visual Studio $name" 'dry run'; continue }
        if ((Invoke-Capture $query).Output | Select-Object -First 1) { Add-Result changed "Visual Studio $name" }
        elseif ($code -in 1641, 3010) { Add-Result flagged "Visual Studio $name" "setup.exe modify exited $code; reboot and re-run -Only vs" }
        else { Add-Result failed "Visual Studio $name" "setup.exe modify exited $code and components are still missing; close Visual Studio and re-run -Only vs (logs: %TEMP%\dd_installer_*.log)" }
    }
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
    $label = "link $Target"
    if (Test-LinkedTo -Item $item -Source $Source -LinkTypes @('SymbolicLink')) {
        Add-Result ok $label
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
    if ($DryRun) { Add-Result changed $label 'dry run'; return }
    $after = Get-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
    if (Test-LinkedTo -Item $after -Source $Source -LinkTypes @('SymbolicLink')) { Add-Result changed $label }
    else { Add-Result failed $label "mklink exited $code; the original is in $BackupDir" }
}

# Sets Windows Terminal's default profile to PowerShell 7 and its font to the
# Nerd Font, inside whatever settings.json the machine already has. Terminal
# writes every machine's generated profiles into that file, so it is merged
# rather than linked: a linked copy would carry one machine's profiles into
# the repo.
function Set-TerminalDefaults {
    $settings = Join-Path $WindowsTerminalState 'settings.json'
    if (-not (Test-Path -LiteralPath $settings)) {
        Add-Result flagged 'Windows Terminal defaults' 'not launched yet (no settings.json); launch it once, then re-run -Only dotfiles'
        return
    }
    try { $json = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json }
    catch {
        Add-Result flagged 'Windows Terminal defaults' "settings.json is not plain JSON (comments?); set PowerShell and '$NerdFontFace' in Terminal's Settings"
        return
    }
    $profilesProp = $json.PSObject.Properties['profiles']
    if ($null -eq $profilesProp -or $profilesProp.Value -is [array]) {
        Add-Result flagged 'Windows Terminal defaults' "settings.json uses an old layout; set the default profile and font in Terminal's Settings"
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
        Add-Result ok 'Windows Terminal defaults (PowerShell, Nerd Font)'
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
    Add-Result changed 'Windows Terminal defaults' ($changes -join ', ')
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
        Add-Result manual 'dotfile links' ('this shell cannot create file symlinks: turn on Developer Mode (the system ' +
            'layer queues the command) or run elevated, then re-run -Only dotfiles')
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
    Write-Step "PowerShell modules, Go tools, npm globals, uv Pythons and tools"

    # Each kind: what is installed now, how to install one, and the tool it
    # needs on PATH. The same check runs again after installing.
    $kinds = @(
        @{
            Kind = 'psmodule'; Needs = 'pwsh'; Label = 'PowerShell module'
            # Installed from inside pwsh 7 so they land on its module path; the
            # user module path of Windows PowerShell is invisible to pwsh.
            List = { @((Invoke-Capture @('pwsh', '-NoProfile', '-NonInteractive', '-Command',
                    'Get-InstalledPSResource -Scope CurrentUser | Select-Object -ExpandProperty Name')).Output) }
            Install = { param($n) RunRetry @('pwsh', '-NoProfile', '-NonInteractive', '-Command',
                    "Install-PSResource -Name '$n' -Scope CurrentUser -Repository PSGallery -TrustRepository -Quiet") }
        },
        @{
            Kind = 'go'; Needs = 'go'; Label = 'go install'
            List = {
                $bin = Join-Path ((Invoke-Capture @('go', 'env', 'GOPATH')).Output | Select-Object -First 1) 'bin'
                @(Get-ChildItem -LiteralPath $bin -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Extension -eq '.exe' } | ForEach-Object { $_.BaseName })
            }
            Key = { param($m) Get-GoBinaryName $m }
            Install = { param($m) RunRetry @('go', 'install', $m) }
        },
        @{
            Kind = 'npm'; Needs = 'npm'; Label = 'npm global'
            List = {
                $json = (Invoke-Capture @('npm', 'ls', '-g', '--depth=0', '--json')).Output -join "`n"
                if (-not $json.Trim()) { return @() }
                $tree = $json | ConvertFrom-Json
                if ($tree.PSObject.Properties['dependencies']) { return @($tree.dependencies.PSObject.Properties.Name) }
                return @()
            }
            Install = { param($p) RunRetry @('npm', 'install', '-g', $p) }
        },
        @{
            Kind = 'uv-python'; Needs = 'uv'; Label = 'Python'
            # "cpython-3.13.7-windows-x86_64-none ..." -> 3.13
            List = { @((Invoke-Capture @('uv', 'python', 'list', '--only-installed')).Output |
                    Where-Object { $_ -match '^cpython-(\d+\.\d+)\.' } | ForEach-Object { $Matches[1] }) }
            Install = { param($v) RunRetry @('uv', 'python', 'install', $v) }
        },
        @{
            Kind = 'uv-tool'; Needs = 'uv'; Label = 'uv tool'
            # `uv tool list` prints "<name> v<version>" for each tool, then its executables.
            List = { @((Invoke-Capture @('uv', 'tool', 'list')).Output |
                    Where-Object { $_ -match '^(\S+) v' } | ForEach-Object { $Matches[1] }) }
            Install = { param($t) RunRetry @('uv', 'tool', 'install', $t) }
        }
    )

    foreach ($k in $kinds) {
        $entries = @(Get-ProfileEntries $k.Kind)
        if ($entries.Count -eq 0) { continue }
        if (-not (Test-Command $k.Needs)) {
            Add-Result flagged "$($k.Label)s" "$($k.Needs) not on PATH; open a new shell after the packages layer and re-run -Only tooling"
            continue
        }
        $present = @(& $k.List | ForEach-Object { ([string]$_).ToLowerInvariant() })
        foreach ($entry in $entries) {
            $key = $entry
            if ($k.ContainsKey('Key')) { $key = & $k.Key $entry }
            $label = "$($k.Label) $entry"
            if ($present -contains $key.ToLowerInvariant()) { Add-Result ok $label; continue }
            Write-Info "Installing $label"
            $code = & $k.Install $entry
            if ($DryRun) { Add-Result changed $label 'dry run'; continue }
            $after = @(& $k.List | ForEach-Object { ([string]$_).ToLowerInvariant() })
            if ($after -contains $key.ToLowerInvariant()) { Add-Result changed $label }
            else { Add-Result failed $label "install exited $code and it is still not listed" }
        }
    }

    # uv puts tool executables in ~\.local\bin, which a fresh machine does not
    # have on PATH. update-shell adds it to the User PATH once; idempotent.
    if (@(Get-ProfileEntries 'uv-tool').Count -gt 0 -and (Test-Command uv)) {
        $uvBin = (Invoke-Capture @('uv', 'tool', 'dir', '--bin')).Output | Select-Object -First 1
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($uvBin -and (@($userPath -split ';') -contains $uvBin)) { Add-Result ok "uv tool bin on PATH" }
        else {
            $null = Run @('uv', 'tool', 'update-shell')
            if ($DryRun) { Add-Result changed "uv tool bin on PATH" 'dry run' }
            elseif (@(([Environment]::GetEnvironmentVariable('Path', 'User')) -split ';') -contains $uvBin) {
                Add-Result changed "uv tool bin on PATH" $uvBin
            }
            else { Add-Result failed "uv tool bin on PATH" "uv tool update-shell did not add $uvBin" }
        }
    }

    Write-Step "Manual steps this script deliberately leaves to you"
    Write-Host "  gh auth login          # then move what it writes into ~\.gitconfig (a link into"
    Write-Host "                         # this repo) over to ~\.gitconfig-local"
    Write-Host "  ~\.gitconfig-local     # your git identity; see the dotfiles layer's message"
    Write-Host "  ssh keys               # not in this repo; generate or restore your own"
    Write-Host "  Warp settings          # Appearance > Prompt: honour the custom prompt (PS1), so starship shows;"
    Write-Host "                         # Appearance > Text: font JetBrainsMono Nerd Font"
    Write-Host "  Docker Desktop         # containers profile: launch once; it provisions its WSL distro"
    Write-Host "  devshell               # cpp profile: run in pwsh to put MSVC on PATH for that session"
    if ($SelectedProfiles -contains 'lowlevel') {
        Write-Host ""
        Write-Host "  lowlevel tools that are not on winget:"
        Write-Host "  Ghidra                 # github.com/NationalSecurityAgency/ghidra/releases; unzip, needs a"
        Write-Host "                         # JDK 21 (the java profile installs Corretto 21)"
        Write-Host "  Intel VTune            # Intel oneAPI site; CPU profiling on Intel hardware"
        Write-Host "  AMD uProf              # AMD developer site; CPU profiling on AMD hardware"
        Write-Host "  OSR Driver Loader      # osronline.com; test-load unsigned drivers in a VM"
    }
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
        $label = "VS Code extension $id"
        if ($present -contains $id.ToLowerInvariant()) { Add-Result ok $label; $already++; continue }
        $code = RunRetry @('code', '--install-extension', $id)
        if ($DryRun) { Add-Result changed $label 'dry run'; $added++; continue }
        $after = @((Invoke-Capture @('code', '--list-extensions')).Output | ForEach-Object { $_.ToLowerInvariant() })
        if ($after -contains $id.ToLowerInvariant()) { Add-Result changed $label; $added++ }
        else { Add-Result failed $label "exited $code; usually an extension that was unpublished or renamed"; $failed++ }
    }
    Write-Info "VS Code: $($ids.Count) listed, $already already present, $added installed, $failed failed."
}

# --- Main --------------------------------------------------------------------

function Invoke-Main {
    # One run at a time: two runs would race over the same winget installs.
    $mutex = New-Object System.Threading.Mutex($false, 'Global\MachinesSetupsInstall')
    $owned = $false
    try { $owned = $mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) {
        Write-Err "Another install.ps1 is already running; let it finish, then re-run."
        exit 3
    }

    # A transcript of every run, dry runs included, for when the console has scrolled away.
    $logFile = Join-Path $LogDir "install-$RunStamp.log"
    $transcribing = $false
    try {
        if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        Start-Transcript -Path $logFile -Append | Out-Null
        $transcribing = $true
    }
    catch { Write-Warn "Could not start a transcript at ${logFile}: $($_.Exception.Message)" }

    $failed = 0
    try {
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
        if (Wants 'system')     { Invoke-LayerSystem }
        if (Wants 'vs')         { Invoke-LayerVs }
        if (Wants 'dotfiles')   { Invoke-LayerDotfiles }
        if (Wants 'tooling')    { Invoke-LayerTooling }
        if (Wants 'extensions') { Invoke-LayerExtensions }

        $failed = Write-Summary
        Write-Host ""
        if (Test-Path -LiteralPath $BackupDir) {
            Write-Info "Replaced files were backed up to $BackupDir"
        }
        if ($transcribing) { Write-Info "Log: $logFile" }
        Write-Info "Open a new terminal: installers append to PATH, and this shell cannot see that."
    }
    finally {
        if ($transcribing) { try { Stop-Transcript | Out-Null } catch { } }
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
    if ($failed -gt 0) { exit 1 }
}

Invoke-Main
