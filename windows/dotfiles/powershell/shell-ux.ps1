# shell-ux.ps1 -- interactive shell experience (the "oh-my-zsh" layer).
#
# Loaded from profile.ps1 (CurrentUserAllHosts), so it applies to every PowerShell 7
# host for this user: Windows Terminal, the VS Code terminal, bare pwsh.
#
# ORDER IS LOAD-BEARING. Starship must be initialised LAST: it defines the `prompt`
# function, and posh-git also defines one on import. Last writer wins.
#
# NOTE: Microsoft.PowerShell_profile.ps1 contains a coreutils block that rewrites ~85
# command names (ls, la, cat, grep, find, rm, cp, sort, head, tail, date, sleep, test,
# pwd, ...) at the PSReadLine layer. Do NOT define aliases for any of those names here --
# the rewriter fires first and the alias would silently never run.

# --- bail out for non-interactive sessions -----------------------------------
# Nothing below is useful to a script runner, and it all costs startup time.
$__cmdline = [Environment]::GetCommandLineArgs()
if ($__cmdline -contains '-NonInteractive' -or $__cmdline -contains '-noni') { return }
if ($Host.Name -notin 'ConsoleHost', 'Visual Studio Code Host') { return }

# Keep starship.toml on OneDrive instead of ~\.config (uncomment to sync it):
# $env:STARSHIP_CONFIG = Join-Path $PSScriptRoot 'starship.toml'


# --- PSReadLine: fish-style suggestions, history search, syntax colours ------
# Interactive hosts have already loaded it; importing again costs ~145 ms for nothing.
if (-not (Get-Module PSReadLine)) { Import-Module PSReadLine -ErrorAction SilentlyContinue }
if (Get-Module PSReadLine) {

    Set-PSReadLineOption -HistoryNoDuplicates `
        -HistorySearchCursorMovesToEnd `
        -MaximumHistoryCount 20000 `
        -BellStyle None

    # HistoryAndPlugin adds IntelliSense-driven predictions on top of history, but only
    # works if a predictor plugin is present. Import directly rather than probing with
    # `Get-Module -ListAvailable`, which rescans every module path (~80 ms) to say so.
    Import-Module CompletionPredictor -ErrorAction SilentlyContinue
    $__pred = if (Get-Module CompletionPredictor) { 'HistoryAndPlugin' } else { 'History' }

    # Throws when stdout is redirected or the host has no virtual-terminal support
    # (e.g. `pwsh -File script.ps1 > out.txt`). Predictions just stay off there.
    try {
        Set-PSReadLineOption -PredictionSource $__pred -PredictionViewStyle ListView -ErrorAction Stop
    }
    catch { }

    # Tab cycles a completion menu instead of dumping every match.
    Set-PSReadLineKeyHandler -Key Tab       -Function MenuComplete
    # Up/Down filter history by what you have already typed (omz history-substring-search).
    Set-PSReadLineKeyHandler -Key UpArrow   -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
    # Accept the greyed-out suggestion: whole line, or one word at a time.
    Set-PSReadLineKeyHandler -Chord 'Ctrl+f' -Function AcceptSuggestion
    Set-PSReadLineKeyHandler -Chord 'Alt+f'  -Function AcceptNextSuggestionWord
    # Surround-with-brackets and smart quoting niceties.
    Set-PSReadLineKeyHandler -Chord 'Ctrl+w' -Function BackwardKillWord
    Set-PSReadLineKeyHandler -Chord 'Alt+d'  -Function KillWord

    # Catppuccin Mocha, matching starship.toml.
    Set-PSReadLineOption -Colors @{
        InlinePrediction = '#6c7086'   # overlay0
        Command          = '#89b4fa'   # blue
        Parameter        = '#cba6f7'   # mauve
        Operator         = '#94e2d5'   # teal
        Variable         = '#f5e0dc'   # rosewater
        String           = '#a6e3a1'   # green
        Number           = '#fab387'   # peach
        Type             = '#f9e2af'   # yellow
        Comment          = '#6c7086'   # overlay0
        Keyword          = '#f38ba8'   # red
        Error            = '#f38ba8'   # red
    }
}


# --- posh-git: LAZY `git ch<TAB>` completion ---------------------------------
# Importing posh-git eagerly costs ~620 ms of every single terminal launch, and the
# only part we want is its tab completion (starship renders the git prompt segments).
# So register a stub completer that imports posh-git on the FIRST git completion;
# posh-git then replaces this registration with its own for the rest of the session.
# Verified: importing posh-git *after* starship does not clobber starship's prompt.
Register-ArgumentCompleter -Native -CommandName git, git.exe, g -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    if (-not (Get-Module posh-git)) { Import-Module posh-git -ErrorAction SilentlyContinue }
    if (Get-Command Expand-GitCommand -ErrorAction SilentlyContinue) {
        # posh-git's own padding dance: PowerShell strips the trailing space.
        $padLength = $cursorPosition - $commandAst.Extent.StartOffset
        $textToComplete = $commandAst.ToString().PadRight($padLength, ' ').Substring(0, $padLength)
        Expand-GitCommand $textToComplete
    }
}


# --- PSFzf: LAZY Ctrl+R fuzzy history, Ctrl+T file picker --------------------
# Same trick as posh-git: importing PSFzf costs 200-500 ms at startup for two key
# bindings. Bind cheap stubs instead; the first press imports PSFzf, hands the chords
# over to PSFzf's own handlers via Set-PsFzfOption, and runs the real handler.
if (Get-Command fzf -ErrorAction SilentlyContinue) {

    $env:FZF_DEFAULT_OPTS = '--height 45% --layout=reverse --border=rounded --info=inline ' +
    '--color=bg+:#313244,bg:#1e1e2e,spinner:#f5e0dc,hl:#f38ba8,fg:#cdd6f4,' +
    'header:#f38ba8,info:#cba6f7,pointer:#f5e0dc,marker:#f5e0dc,fg+:#cdd6f4,' +
    'prompt:#cba6f7,hl+:#f38ba8'

    # Returns $true once PSFzf owns the Ctrl+R / Ctrl+T chords.
    function Initialize-PSFzfBinding {
        if (Get-Module PSFzf) { return $true }
        Import-Module PSFzf -ErrorAction SilentlyContinue
        if (-not (Get-Module PSFzf)) { return $false }
        Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordReverseHistory 'Ctrl+r'
        return $true
    }

    Set-PSReadLineKeyHandler -Chord 'Ctrl+r' -Description 'Fzf reverse history (lazy load)' -ScriptBlock {
        if (Initialize-PSFzfBinding) { Invoke-FzfPsReadlineHandlerHistory }
    }
    Set-PSReadLineKeyHandler -Chord 'Ctrl+t' -Description 'Fzf file picker (lazy load)' -ScriptBlock {
        if (Initialize-PSFzfBinding) { Invoke-FzfPsReadlineHandlerProvider }
    }
}


# --- zoxide: the `z` plugin ---------------------------------------------------
# `z rush` jumps to the most-used directory matching "rush"; `zi` picks interactively.
# Default --cmd, so plain `cd` keeps its normal behaviour.
if (Get-Command zoxide -ErrorAction SilentlyContinue) {
    Invoke-Expression (& { (zoxide init powershell | Out-String) })
}


# --- aliases ------------------------------------------------------------------
# Deliberately avoids every name the coreutils rewriter claims (see header).
# `gp` is the one intentional override of a built-in alias (was Get-ItemProperty).

Set-Alias -Name g -Value git

function gst { git status @args }
function gss { git status -s @args }
function ga { git add @args }
function gaa { git add --all @args }
function gcmsg { git commit -m @args }
function gcam { git commit -a -m @args }
function gco { git checkout @args }
function gcob { git checkout -b @args }
function gb { git branch @args }
function gd { git diff @args }
function gds { git diff --staged @args }
function gpl { git pull @args }
function gf { git fetch --all --prune @args }
function grs { git restore @args }
function gsta { git stash push @args }
function gstp { git stash pop @args }
# Aliases resolve BEFORE functions, so a bare `function gp` would lose to the built-in
# `gp` -> Get-ItemProperty alias. These two are deliberate overrides of built-ins
# (gp = Get-ItemProperty, glg = Get-LocalGroup); point the alias at a real function.
function Invoke-GitPush { git push @args }
function Invoke-GitLogGraph { git log --oneline --graph --decorate --all @args }
Set-Alias -Name gp  -Value Invoke-GitPush     -Force
Set-Alias -Name glg -Value Invoke-GitLogGraph -Force

function ll { Get-ChildItem -Force @args }
function .. { Set-Location .. }
function ... { Set-Location ..\.. }
function .... { Set-Location ..\..\.. }
function which { (Get-Command @args -ErrorAction SilentlyContinue).Source }
function mkcd { param([Parameter(Mandatory)][string]$Path) New-Item -ItemType Directory -Force -Path $Path | Out-Null; Set-Location $Path }
function reload { . $PROFILE.CurrentUserAllHosts; . $PROFILE.CurrentUserCurrentHost }


# --- starship: MUST BE LAST ---------------------------------------------------
# Degrade to the default prompt rather than erroring on every shell start.
if (Get-Command starship -ErrorAction SilentlyContinue) {
    $env:STARSHIP_SHELL = 'powershell'
    Invoke-Expression (&starship init powershell)
    # Transient prompt is deliberately NOT enabled: it installs its own PSReadLine
    # Enter handler, and the coreutils block already owns PSConsoleHostReadLine.
    # Enable-TransientPrompt
}
