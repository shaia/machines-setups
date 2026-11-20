<#
.SYNOPSIS
Checks that every winget id and PowerShell module in windows/profiles/*.txt
still resolves.

.DESCRIPTION
Asks winget (`winget show --id <id> --exact --source winget`) and the
PowerShell Gallery about each entry, and installs nothing. CI installs only a
few profiles; this catches a renamed or removed package in the rest.

Lines are read the way install.ps1 reads them: comments stripped, a bare
single word is a winget id, `psmodule <name>` is a module, and every other
line kind (vscode, requires) is skipped.

Exit status: 0 when every entry resolves, 1 otherwise. Needs PowerShell 7.4+
for Find-PSResource.
#>

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$inCi = $env:GITHUB_ACTIONS -eq 'true'

function Write-Problem([string]$File, [int]$Line, [string]$Message) {
    if ($inCi) { Write-Host "::error file=$File,line=$Line::$Message" }
    else { Write-Host "ERROR    ${File}:${Line}: $Message" -ForegroundColor Red }
}

# First place each entry appears; ids listed in two profiles are checked once.
$winget = [ordered]@{}
$modules = [ordered]@{}
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $repo 'windows\profiles') -Filter *.txt | Sort-Object Name) {
    $rel = "windows/profiles/$($file.Name)"
    $n = 0
    foreach ($line in [IO.File]::ReadAllLines($file.FullName)) {
        $n++
        $parts = @((($line -replace '#.*$', '').Trim() -split '\s+') | Where-Object { $_ })
        $where = @{ File = $rel; Line = $n }
        if ($parts.Count -eq 1 -and -not $winget.Contains($parts[0])) { $winget[$parts[0]] = $where }
        elseif ($parts.Count -eq 2 -and $parts[0] -eq 'psmodule' -and -not $modules.Contains($parts[1])) { $modules[$parts[1]] = $where }
    }
}

$failed = 0

foreach ($id in $winget.Keys) {
    # One retry: a source refresh or a network blip fails a single lookup.
    $out = ''
    foreach ($attempt in 1..2) {
        $out = winget show --id $id --exact --source winget --accept-source-agreements --disable-interactivity 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) { break }
        if ($attempt -eq 1) { Start-Sleep -Seconds 5 }
    }
    if ($LASTEXITCODE -eq 0) { Write-Host "ok       winget $id" }
    else {
        $at = $winget[$id]
        $why = ($out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
        Write-Problem $at.File $at.Line "winget id '$id' not found (exit $LASTEXITCODE): $why"
        $failed++
    }
}

foreach ($name in $modules.Keys) {
    try {
        $null = Find-PSResource -Name $name -Repository PSGallery -ErrorAction Stop
        Write-Host "ok       psmodule $name"
    }
    catch {
        $at = $modules[$name]
        Write-Problem $at.File $at.Line "PowerShell module '$name' not found in the PowerShell Gallery: $($_.Exception.Message)"
        $failed++
    }
}

Write-Host ""
Write-Host "$($winget.Count) winget ids and $($modules.Count) modules checked: $failed not found."
if ($failed -gt 0) { exit 1 }
exit 0
