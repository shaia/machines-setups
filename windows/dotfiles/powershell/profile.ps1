
# --- Machine-local overrides -------------------------------------------------
# Anything specific to one machine or one employer - API keys, work-only PATH
# entries, an internal registry - belongs in ~\.powershell.local.ps1, not in
# this repo. GEMINI_API_KEY for ~\.claude\scripts is read from the User
# environment (install.ps1 prints the command that sets it); that file is the
# fallback for a shell that does not inherit it. Absent on a fresh machine.
$__local = Join-Path $HOME '.powershell.local.ps1'
if (Test-Path $__local) { . $__local }

#region conda initialize
# !! Contents within this block are managed by 'conda init' !!
If (Test-Path "$HOME\miniconda3\Scripts\conda.exe") {
    (& "$HOME\miniconda3\Scripts\conda.exe" "shell.powershell" "hook") | Out-String | ?{$_} | Invoke-Expression
}
#endregion

# Interactive shell experience: starship prompt, PSReadLine predictions, fzf, zoxide,
# git completion and aliases. Kept in its own file so it can be re-sourced if a later
# profile (e.g. Launch-VsDevShell) ever clobbers the prompt. See shell-ux.ps1.
$__ux = Join-Path $PSScriptRoot 'shell-ux.ps1'
if (Test-Path $__ux) { . $__ux }

