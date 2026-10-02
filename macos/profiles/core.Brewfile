# Core: every machine gets this.
#
# Applied by install.sh with `brew bundle --file=<this> --no-upgrade`. The
# cross-platform half of this profile is common/profiles/core.txt.

# Shell
brew "starship"                 # prompt; common/starship.toml
brew "zsh-autosuggestions"      # sourced from .zshrc
brew "zsh-syntax-highlighting"  # sourced LAST in .zshrc
cask "font-jetbrains-mono-nerd-font"  # the glyphs the prompt draws

# Git
brew "git"
brew "gh"
brew "git-delta"                # pager; common/git/delta.gitconfig
brew "lazygit"

# Modern CLI
brew "ripgrep"
brew "fd"
brew "bat"
brew "eza"                      # `ls` is aliased to it in .zshrc
brew "jq"
brew "fzf"                      # Ctrl+R / Ctrl+T, bound in .zshrc
brew "zoxide"                   # z <dir>
brew "btop"
brew "tlrc"                     # tldr <command>
brew "yq"                       # jq for YAML
brew "hyperfine"                # command benchmarks
brew "dust"                     # disk usage
brew "duf"                      # df
brew "sd"                       # find and replace
brew "glow"                     # Markdown in the terminal
brew "fastfetch"
brew "gping"                    # ping graph
brew "doggo"                    # DNS lookups

# Developer workflow
brew "uv"                       # Python tooling; pre-commit installs through it
brew "act"                      # run GitHub Actions locally
brew "difftastic"               # git dft

# Editor and desktop
cask "warp"                     # the terminal; set its prompt to honour PS1 (see README)
cask "iterm2"
cask "visual-studio-code"
cask "rectangle"
