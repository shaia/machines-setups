$env:Path = "$HOME\.local\bin;$env:LOCALAPPDATA\Microsoft\WindowsApps;C:\Program Files\Graphviz\bin;$env:Path"
if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
    oh-my-posh init pwsh | Invoke-Expression
}

function ll { Get-ChildItem | Format-Table }

Import-Module PSReadLine
Set-PSReadLineOption -EditMode Windows

# Auto-initialize Visual Studio environment for cl.exe
function Initialize-VSEnvironment {
    $vsPath = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
    if (Test-Path $vsPath) {
        cmd /c "`"$vsPath`" >nul 2>&1 && set" | ForEach-Object {
            if ($_ -match '^([^=]+)=(.*)$') {
                [System.Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
            }
        }
        Write-Host "Visual Studio environment initialized" -ForegroundColor Green
    }
}

# Uncomment the line below to auto-initialize on every PowerShell session:
# Initialize-VSEnvironment
