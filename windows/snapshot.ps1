#Requires -Version 5.1
<#
.SYNOPSIS
Regenerate this directory's inventory from the machine it runs on, so the
checked-in snapshot does not rot as packages come and go.

.DESCRIPTION
  .\snapshot.ps1          # rewrite every inventory file
  .\snapshot.ps1 -Diff    # show what would change, write nothing

Two kinds of inventory file, treated differently:

  Curated   winget-packages.txt. Hand-sectioned with comments that winget
            cannot know about. New packages are appended under an "Unsorted"
            header for you to file; packages that are listed but no longer
            installed are reported, never removed, because the list is also
            where "installed by other means" lives.

  Generated tools.txt, vscode-extensions.txt, cursor-extensions.txt and
            vsconfig\*.vsconfig. Rewritten wholesale from the live machine.

dotfiles\ is not touched: install.ps1 links those into place, so edits to
~\.gitconfig or the PowerShell profile land in this repo already.

Written for Windows PowerShell 5.1 as well as PowerShell 7, and kept ASCII-only
because 5.1 reads a BOM-less file as the ANSI code page.
#>
[CmdletBinding()]
param(
    [switch]$Diff
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$ScriptDir = $PSScriptRoot
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Visual Studio's installationVersion major -> the product year in the file name.
$VsYearByMajor = @{ 16 = '2019'; 17 = '2022'; 18 = '2026' }

# --- Output helpers ----------------------------------------------------------

function Write-Info { param([string]$Message) Write-Host "[INFO] $Message" }
function Write-Warn { param([string]$Message) Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Err  { param([string]$Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }

# Native commands write progress and warnings to stderr, and under 'Stop'
# Windows PowerShell turns a redirected stderr line into a terminating error.
# Run with 'Continue' in effect and hand back stdout plus the exit code.
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

# --- List-file helpers -------------------------------------------------------

function Read-Lines {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return @([IO.File]::ReadAllLines($Path)) }
    return @()
}

function Write-Lines {
    param([string]$Path, [string[]]$Lines)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    [IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"), $Utf8NoBom)
}

# Entries are lines with comments and blanks stripped and whitespace collapsed,
# so "Git.Git   # version control" and "Git.Git" are the same entry.
function Get-Entries {
    param([string[]]$Lines)
    $entries = @()
    foreach ($line in $Lines) {
        $t = ($line -replace '#.*$', '').Trim()
        if ($t) { $entries += ($t -replace '\s+', ' ') }
    }
    return $entries
}

function Compare-Entries {
    param([string[]]$Tracked, [string[]]$Live)
    $trackedLower = @($Tracked | ForEach-Object { $_.ToLowerInvariant() })
    $liveLower = @($Live | ForEach-Object { $_.ToLowerInvariant() })
    $added = @($Live | Where-Object { $trackedLower -notcontains $_.ToLowerInvariant() })
    $removed = @($Tracked | Where-Object { $liveLower -notcontains $_.ToLowerInvariant() })
    return [pscustomobject]@{ Added = $added; Removed = $removed }
}

function Show-Delta {
    param($Delta)
    foreach ($a in $Delta.Added) { Write-Host "    + $a" }
    foreach ($r in $Delta.Removed) { Write-Host "    - $r" }
}

# Curated lists keep their comments and ordering. Additions go under an
# Unsorted header; removals are reported and left for a human to judge.
function Update-CuratedList {
    param([string]$Path, [string[]]$Live, [string]$Label, [string[]]$Header)

    # Every function result is wrapped in @(): PowerShell unrolls a returned
    # array, so an empty one arrives as $null and a single entry as a string.
    $lines = @(Read-Lines $Path)
    $tracked = @(Get-Entries $lines)
    $delta = Compare-Entries -Tracked $tracked -Live $Live
    $name = Split-Path -Leaf $Path

    if ($delta.Added.Count -eq 0 -and $delta.Removed.Count -eq 0) {
        Write-Info "$Label up to date ($($tracked.Count) listed)."
        return
    }

    Write-Warn "$Label differs from the live machine:"
    Show-Delta $delta
    if ($Diff) { return }

    if ($delta.Added.Count -gt 0) {
        if ($lines.Count -eq 0) { $lines = $Header }
        $lines += ''
        $lines += "# --- Unsorted: added by snapshot.ps1 on $(Get-Date -Format yyyy-MM-dd). Move each line under a section. ---"
        $lines += $delta.Added
        Write-Lines $Path $lines
        Write-Info "Appended $($delta.Added.Count) line(s) to $name under an Unsorted header."
    }
    if ($delta.Removed.Count -gt 0) {
        Write-Warn "$name lists $($delta.Removed.Count) package(s) the machine no longer has. Delete the"
        Write-Warn "lines by hand if that is intended; the file's comments say which ones to keep."
    }
}

# Generated lists are mechanical: header plus live content, rewritten whole.
function Update-GeneratedList {
    param([string]$Path, [string[]]$Header, [string[]]$Lines, [string]$Label)

    $tracked = @(Get-Entries (Read-Lines $Path))
    $live = @(Get-Entries $Lines)
    $delta = Compare-Entries -Tracked $tracked -Live $live
    $name = Split-Path -Leaf $Path

    if ($delta.Added.Count -eq 0 -and $delta.Removed.Count -eq 0) {
        Write-Info "$Label unchanged ($($live.Count) listed)."
        return
    }

    Write-Warn "$Label changed:"
    Show-Delta $delta
    if ($Diff) { return }
    Write-Lines $Path ($Header + $Lines)
    Write-Info "Wrote $name."
}

# --- winget ------------------------------------------------------------------
#
# `winget export` is the only reliable "what is installed" view: `winget list`
# is a fixed-width table that truncates ids. The export skips every package no
# source can match (drivers, Store-only apps, JetBrains Toolbox IDEs); those are
# listed in README.md rather than here.

function Get-WingetEntries {
    $tmp = Join-Path $env:TEMP "winget-export-$PID.json"
    $r = Invoke-Capture @('winget', 'export', '-o', $tmp, '--accept-source-agreements', '--disable-interactivity')
    if (-not (Test-Path -LiteralPath $tmp)) {
        throw "winget export produced no file (exit $($r.ExitCode))."
    }
    $json = Get-Content -LiteralPath $tmp -Raw | ConvertFrom-Json
    Remove-Item -LiteralPath $tmp -Force
    $entries = @()
    foreach ($source in @($json.Sources)) {
        $sourceName = $source.SourceDetails.Name
        foreach ($pkg in @($source.Packages)) {
            if ($sourceName -eq 'winget') { $entries += $pkg.PackageIdentifier }
            else { $entries += "$($pkg.PackageIdentifier) $sourceName" }
        }
    }
    return ($entries | Sort-Object)
}

if (Test-Command winget) {
    Write-Info "Exporting the winget package list (takes a while)."
    try {
        $live = @(Get-WingetEntries)
        Update-CuratedList -Path (Join-Path $ScriptDir 'winget-packages.txt') -Live $live -Label 'winget-packages.txt' -Header @(
            '# winget packages - snapshot of this machine. One package id per line, optional',
            '# source as a second column (default: winget). Applied by install.ps1 with',
            '#   winget install --id <id> --exact --source <source>',
            '# for every id that `winget export` does not report as installed.',
            '# Refresh with .\snapshot.ps1 (new ids land under an Unsorted header at the bottom).'
        )
    }
    catch {
        Write-Err "$($_.Exception.Message) Leaving winget-packages.txt alone."
    }
}
else {
    Write-Warn "winget not on PATH; leaving winget-packages.txt alone."
}

# --- Other package managers --------------------------------------------------
#
# The snapshot is winget-only. Chocolatey and scoop are reported rather than
# inventoried, so a machine that still carries them sees the drift on every
# run; README.md has the one-time migration off them.

if (Test-Command choco) {
    $names = @((Invoke-Capture @('choco', 'list', '--limit-output')).Output |
        Where-Object { $_ -match '\|' } | ForEach-Object { ($_ -split '\|')[0] })
    Write-Warn "choco is installed ($($names -join ', ')) but is not part of this snapshot; see 'Consolidated onto winget' in README.md."
}
if (Test-Command scoop) {
    Write-Warn "scoop is installed but is not part of this snapshot; see 'Consolidated onto winget' in README.md."
}

# --- Visual Studio workloads -------------------------------------------------
#
# winget installs Visual Studio with its default workloads only. The installer
# can export the real component selection as a .vsconfig, and `setup.exe modify
# --config` replays it, so one file per installed product goes in vsconfig\.

$vsInstaller = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer'
$vswhere = Join-Path $vsInstaller 'vswhere.exe'
$vssetup = Join-Path $vsInstaller 'setup.exe'

if ((Test-Path -LiteralPath $vswhere) -and (Test-Path -LiteralPath $vssetup)) {
    # No @() here: Windows PowerShell's ConvertFrom-Json hands a JSON array back
    # as one object, and wrapping it would nest it. foreach enumerates either way.
    $instances = (Invoke-Capture @($vswhere, '-all', '-products', '*', '-format', 'json')).Output -join "`n" | ConvertFrom-Json
    foreach ($inst in $instances) {
        $major = [int]($inst.installationVersion.Split('.')[0])
        $year = $VsYearByMajor[$major]
        if (-not $year) { $year = "v$major" }
        $product = (($inst.productId -split '\.')[-1]).ToLowerInvariant()
        $name = "vs$year-$product"
        $out = Join-Path $ScriptDir "vsconfig\$name.vsconfig"
        $tmp = Join-Path $env:TEMP "$name-$PID.vsconfig"
        $log = Join-Path $env:TEMP "$name-$PID.log"

        Write-Info "Exporting $($inst.displayName) workloads (takes a moment)."
        $p = Start-Process -FilePath $vssetup -Wait -PassThru -NoNewWindow -RedirectStandardOutput $log -ArgumentList @(
            'export', '--installPath', "`"$($inst.installationPath)`"", '--config', "`"$tmp`"", '--quiet', '--noUpdateInstaller')
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $tmp)) {
            Write-Warn "Export of $($inst.displayName) failed (exit $($p.ExitCode)); leaving $name.vsconfig alone."
            continue
        }

        $liveComponents = @((Get-Content -LiteralPath $tmp -Raw | ConvertFrom-Json).components | Sort-Object)
        $trackedComponents = @()
        if (Test-Path -LiteralPath $out) {
            $trackedComponents = @((Get-Content -LiteralPath $out -Raw | ConvertFrom-Json).components | Sort-Object)
        }
        $delta = Compare-Entries -Tracked $trackedComponents -Live $liveComponents
        if ($delta.Added.Count -eq 0 -and $delta.Removed.Count -eq 0) {
            Write-Info "$name.vsconfig unchanged ($($liveComponents.Count) components)."
            Remove-Item -LiteralPath $tmp -Force
            continue
        }
        Write-Warn "$name.vsconfig changed:"
        Show-Delta $delta
        if ($Diff) {
            Remove-Item -LiteralPath $tmp -Force
            continue
        }
        $dir = Split-Path -Parent $out
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        Move-Item -LiteralPath $tmp -Destination $out -Force
        Write-Info "Wrote vsconfig\$name.vsconfig."
    }
}
else {
    Write-Warn "Visual Studio Installer not found; leaving vsconfig\ alone."
}

# --- tools.txt: go install, npm -g, dotnet tool, PowerShell modules ----------
#
# Each kind is enumerated from the tool that owns it. When that tool is not on
# PATH the kind's existing lines are kept rather than dropped, so a run on a
# half-built machine cannot silently empty a section.

$toolsPath = Join-Path $ScriptDir 'tools.txt'
$toolsExisting = @(Get-Entries (Read-Lines $toolsPath))

function Get-ExistingKind {
    param([string]$Kind)
    return @($toolsExisting | Where-Object { $_ -like "$Kind *" })
}

$toolLines = @()

# go: the module path is recorded in every binary `go install` produces.
$goBin = Join-Path $HOME 'go\bin'
if ((Test-Command go) -and (Test-Path -LiteralPath $goBin)) {
    $goLines = @()
    # Not -Filter '*.exe': under Windows PowerShell that also matches gopls.exe~
    # through its 8.3 short name, and the editor backup would be listed twice.
    foreach ($exe in (Get-ChildItem -LiteralPath $goBin -File | Where-Object { $_.Extension -eq '.exe' })) {
        $info = Invoke-Capture @('go', 'version', '-m', $exe.FullName)
        $pathLine = $info.Output | Where-Object { $_ -match '^\s+path\s+(\S+)' } | Select-Object -First 1
        if ($pathLine -and $pathLine -match '^\s+path\s+(\S+)') { $goLines += "go $($Matches[1])@latest" }
        else { Write-Warn "go: $($exe.Name) carries no module path (not built by go install?); skipped." }
    }
    $toolLines += @($goLines | Sort-Object -Unique)
}
else {
    Write-Warn "go not on PATH; keeping the existing go lines."
    $toolLines += Get-ExistingKind 'go'
}

# npm: global packages, minus npm itself and minus anything `npm link`ed from a
# local checkout (a junction in node_modules), which no registry can restore.
if (Test-Command npm) {
    $prefix = (Invoke-Capture @('npm', 'prefix', '-g')).Output | Select-Object -First 1
    $json = (Invoke-Capture @('npm', 'ls', '-g', '--depth=0', '--json')).Output -join "`n"
    $npmLines = @()
    if ($json.Trim()) {
        $tree = $json | ConvertFrom-Json
        if ($tree.PSObject.Properties['dependencies']) {
            foreach ($dep in $tree.dependencies.PSObject.Properties.Name) {
                if ($dep -eq 'npm') { continue }
                $modDir = Join-Path (Join-Path $prefix 'node_modules') $dep
                $item = Get-Item -LiteralPath $modDir -Force -ErrorAction SilentlyContinue
                if ($item -and $item.LinkType) {
                    Write-Warn "npm: $dep is linked from $(@($item.Target)[0]), not installed from a registry; skipped."
                    continue
                }
                $npmLines += "npm $dep"
            }
        }
    }
    $toolLines += @($npmLines | Sort-Object -Unique)
}
else {
    Write-Warn "npm not on PATH; keeping the existing npm lines."
    $toolLines += Get-ExistingKind 'npm'
}

# dotnet: `dotnet tool list -g` is a table with a two-line header.
if (Test-Command dotnet) {
    $rows = (Invoke-Capture @('dotnet', 'tool', 'list', '-g')).Output
    $dotnetLines = @()
    foreach ($row in $rows) {
        if ($row -match '^(Package Id|-+)') { continue }
        if ($row -match '^(\S+)\s+\S+') { $dotnetLines += "dotnet $($Matches[1])" }
    }
    $toolLines += @($dotnetLines | Sort-Object -Unique)
}
else {
    Write-Warn "dotnet not on PATH; keeping the existing dotnet lines."
    $toolLines += Get-ExistingKind 'dotnet'
}

# psmodule: PSResourceGet's view from inside pwsh 7, because that is where the
# profile loads them from (Windows PowerShell's user module path is invisible to
# pwsh). Microsoft.Graph installs 37 Microsoft.Graph.* parts alongside itself;
# a module whose name extends another installed module's name with a dot is
# treated as that module's part and left out.
if (Test-Command pwsh) {
    $names = (Invoke-Capture @('pwsh', '-NoProfile', '-NonInteractive', '-Command',
        'Get-InstalledPSResource -Scope CurrentUser | Select-Object -ExpandProperty Name | Sort-Object -Unique')).Output
    $names = @($names | Where-Object { $_ })
    $psLines = @()
    foreach ($n in $names) {
        $isPart = $false
        foreach ($other in $names) {
            if ($other -ne $n -and $n.StartsWith("$other.", [StringComparison]::OrdinalIgnoreCase)) { $isPart = $true; break }
        }
        if (-not $isPart) { $psLines += "psmodule $n" }
    }
    $toolLines += @($psLines | Sort-Object -Unique)
}
else {
    Write-Warn "pwsh not on PATH; keeping the existing psmodule lines."
    $toolLines += Get-ExistingKind 'psmodule'
}

Update-GeneratedList -Path $toolsPath -Lines $toolLines -Label 'tools.txt' -Header @(
    '# Developer tools outside winget - restored by install.ps1 (tooling layer).',
    '# Regenerate with .\snapshot.ps1',
    '#',
    '#   go <module>@latest   go install <module>',
    '#   npm <package>        npm install -g <package>',
    '#   dotnet <id>          dotnet tool install -g <id>',
    '#   psmodule <name>      Install-PSResource -Scope CurrentUser, run inside pwsh 7',
    ''
)

# --- Editor extensions -------------------------------------------------------

function Update-Extensions {
    param([string]$Cmd, [string]$Path, [string]$Label, [string]$HeaderLine)

    if (-not (Test-Command $Cmd)) {
        Write-Warn "$Label CLI ('$Cmd') not on PATH; leaving $(Split-Path -Leaf $Path) alone."
        return
    }
    $r = Invoke-Capture @($Cmd, '--list-extensions')
    $ids = @($r.Output | Where-Object { $_ } | Sort-Object)
    Update-GeneratedList -Path $Path -Lines $ids -Label "$Label extensions" -Header @(
        "# $HeaderLine",
        '# Regenerate with .\snapshot.ps1'
    )
}

Update-Extensions -Cmd 'code' -Path (Join-Path $ScriptDir 'vscode-extensions.txt') -Label 'VS Code' `
    -HeaderLine 'VS Code extensions - restored by install.ps1 via: code --install-extension'
Update-Extensions -Cmd 'cursor' -Path (Join-Path $ScriptDir 'cursor-extensions.txt') -Label 'Cursor' `
    -HeaderLine 'Cursor extensions - restored by install.ps1 via: cursor --install-extension'

Write-Info "Done. dotfiles\ needs no refresh - install.ps1 links them into place."
