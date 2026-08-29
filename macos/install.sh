#!/usr/bin/env bash
#
# Rebuild this Mac's development environment from the snapshot in this directory.
#
#   ./install.sh                       # every layer
#   ./install.sh --only brew,dotfiles  # just those layers
#   ./install.sh --skip extensions     # everything but that layer
#   ./install.sh --dry-run             # print every mutating command, run none
#
# Preflight (Xcode CLT + Homebrew) always runs; every other layer depends on it.
# Every layer is safe to re-run: it inspects the current state, skips what is
# already satisfied, and says what it skipped.
#
# Written for the bash 3.2 that ships with macOS — no mapfile, no ${x,,}, no
# associative arrays — so it runs on a box where nothing has been installed yet.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BREW_PREFIX="/opt/homebrew"
CLAUDE_CONFIG_REPO="$HOME/development/claude/claude"
BACKUP_DIR="$HOME/.dotfiles-backup-$(date +%Y%m%d-%H%M%S)"

ALL_LAYERS="brew zsh dotfiles tooling extensions"
LAYERS="$ALL_LAYERS"
DRY_RUN=false

# --- Output helpers ----------------------------------------------------------

info()  { printf "[INFO] %s\n" "$*"; }
warn()  { printf "[WARN] %s\n" "$*"; }
error() { printf "[ERROR] %s\n" "$*" >&2; }
step()  { printf "\n=== %s ===\n" "$*"; }

# Everything that changes the machine goes through run(), so --dry-run is total
# rather than a decision each layer has to remember to make.
run() {
  if [[ "$DRY_RUN" == true ]]; then
    printf "  + %s\n" "$*"
    return 0
  fi
  "$@"
}

# For pipelines and redirections, which run() cannot take as argv.
run_sh() {
  if [[ "$DRY_RUN" == true ]]; then
    printf "  + %s\n" "$1"
    return 0
  fi
  bash -c "$1"
}

# --- Argument parsing --------------------------------------------------------

usage() {
  cat <<'EOF'
Usage: install.sh [options]

  --only  <layers>   Run only these layers (comma-separated).
  --skip  <layers>   Run every layer except these.
  --dry-run          Print every mutating command without running it.
  -h, --help         This message.

Layers: brew, zsh, dotfiles, tooling, extensions
EOF
  exit "${1:-0}"
}

# Layer sets are space-padded strings rather than arrays: bash 3.2 errors on
# "${empty[@]}" under `set -u`, and --skip can legitimately empty the set.
layer_known() {
  case " $ALL_LAYERS " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

wants() {
  case " $LAYERS " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only|--skip)
      [[ $# -ge 2 ]] || { error "$1 needs a comma-separated layer list"; exit 2; }
      requested=$(printf '%s' "$2" | tr ',' ' ')
      for layer in $requested; do
        layer_known "$layer" || { error "Unknown layer '$layer'. Valid: $ALL_LAYERS"; exit 2; }
      done
      if [[ "$1" == "--only" ]]; then
        LAYERS="$requested"
      else
        kept=""
        for layer in $LAYERS; do
          case " $requested " in
            *" $layer "*) ;;
            *) kept="$kept $layer" ;;
          esac
        done
        LAYERS="$kept"
      fi
      shift 2
      ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage 0 ;;
    *) error "Unknown option: $1"; usage 2 ;;
  esac
done

# --- Preflight ---------------------------------------------------------------
#
# Always runs. Its mutating actions are all guarded by "if missing", so on an
# already-configured machine this is read-only.

preflight() {
  step "Preflight"

  [[ "$(uname -s)" == "Darwin" ]] || { error "macOS only; this is $(uname -s)."; exit 1; }
  if [[ "$(uname -m)" != "arm64" ]]; then
    error "Apple Silicon expected: the dotfiles hardcode $BREW_PREFIX paths."
    exit 1
  fi
  info "macOS on $(uname -m)."

  if xcode-select -p >/dev/null 2>&1; then
    info "Xcode Command Line Tools present at $(xcode-select -p)."
  else
    warn "Xcode Command Line Tools missing; launching the installer."
    run xcode-select --install || true
    error "Re-run this script once the Command Line Tools installer finishes."
    exit 1
  fi

  if command -v brew >/dev/null 2>&1; then
    info "Homebrew present at $(command -v brew)."
  elif [[ -x "$BREW_PREFIX/bin/brew" ]]; then
    info "Homebrew found at $BREW_PREFIX/bin/brew but not on PATH."
  else
    warn "Homebrew missing; installing."
    run_sh '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  fi

  # Put brew on PATH for the rest of this process, before .zprofile exists.
  if [[ -x "$BREW_PREFIX/bin/brew" ]]; then
    eval "$("$BREW_PREFIX/bin/brew" shellenv)"
  elif [[ "$DRY_RUN" == false ]]; then
    error "Homebrew still not at $BREW_PREFIX/bin/brew. Cannot continue."
    exit 1
  fi
}

# --- Layer: brew -------------------------------------------------------------

layer_brew() {
  step "Homebrew packages"

  brewfile="$SCRIPT_DIR/Brewfile"
  [[ -f "$brewfile" ]] || { error "Brewfile not found at $brewfile"; exit 1; }

  n_formulae=$(grep -c '^brew "' "$brewfile" || true)
  n_casks=$(grep -c '^cask "' "$brewfile" || true)
  info "Applying Brewfile: $n_formulae formulae, $n_casks casks."

  # Several casks correspond to apps that were originally installed by hand and
  # are already sitting in /Applications. Without --adopt, Homebrew refuses with
  # "It seems there is already an App at ..."; with it, it takes them over.
  # A no-op on a machine where nothing is there yet.
  export HOMEBREW_CASK_OPTS="${HOMEBREW_CASK_OPTS:+$HOMEBREW_CASK_OPTS }--adopt"

  # --no-upgrade: install what is missing, leave existing versions alone.
  if run brew bundle install --file="$brewfile" --no-upgrade; then
    info "brew bundle completed."
  else
    warn "brew bundle reported failures; the check below lists what is still missing."
  fi

  # --no-upgrade here too, or check reports merely-outdated packages as
  # unsatisfied and buries anything genuinely absent.
  info "Verifying."
  if [[ "$DRY_RUN" == true ]]; then
    printf "  + brew bundle check --file=%s --verbose --no-upgrade\n" "$brewfile"
  elif brew bundle check --file="$brewfile" --verbose --no-upgrade; then
    info "All Brewfile entries satisfied."
  else
    warn "Some Brewfile entries are still missing (see above)."
  fi
}

# --- Layer: zsh --------------------------------------------------------------

layer_zsh() {
  step "zsh, oh-my-zsh, powerlevel10k"

  omz="$HOME/.oh-my-zsh"

  if [[ -d "$omz" ]]; then
    info "oh-my-zsh already installed at $omz."
  else
    # KEEP_ZSHRC stops the installer replacing the .zshrc this repo owns;
    # RUNZSH and CHSH stop it taking over the terminal mid-script.
    info "Installing oh-my-zsh (keeping any existing .zshrc)."
    run_sh 'KEEP_ZSHRC=yes RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"'
  fi

  # .zshrc sets ZSH_THEME="powerlevel10k/powerlevel10k", which resolves through
  # this symlink to the Homebrew-installed theme.
  theme_link="$omz/custom/themes/powerlevel10k"
  theme_src="$BREW_PREFIX/share/powerlevel10k"
  if [[ -L "$theme_link" && "$(readlink "$theme_link")" == "$theme_src" ]]; then
    info "powerlevel10k theme already linked."
  else
    info "Linking powerlevel10k theme."
    run mkdir -p "$omz/custom/themes"
    run rm -rf "$theme_link"
    run ln -s "$theme_src" "$theme_link"
  fi

  # .zshrc prepends this to fpath unconditionally. Docker Desktop creates it on
  # first launch, and compinit warns about the missing directory until then.
  if [[ -d "$HOME/.docker/completions" ]]; then
    info "Docker completions directory present."
  else
    info "Creating $HOME/.docker/completions (referenced by the .zshrc fpath line)."
    run mkdir -p "$HOME/.docker/completions"
  fi

  if [[ "${SHELL:-}" == */zsh ]]; then
    info "Login shell is already zsh."
  else
    warn "Login shell is ${SHELL:-unknown}; switching to /bin/zsh (may prompt for your password)."
    run chsh -s /bin/zsh
  fi

  info "The oh-my-zsh plugins in use (git, kubectl) ship with oh-my-zsh."
  info "zsh-autosuggestions and zsh-syntax-highlighting come from Homebrew."
}

# --- Layer: dotfiles ---------------------------------------------------------

backup_then_link() {
  src="$1"
  dst="$2"

  if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
    info "$(basename "$dst") already linked."
    return 0
  fi

  if [[ -e "$dst" || -L "$dst" ]]; then
    run mkdir -p "$BACKUP_DIR"
    info "Backing up $dst -> $BACKUP_DIR/"
    run mv "$dst" "$BACKUP_DIR/"
  fi

  parent="$(dirname "$dst")"
  [[ -d "$parent" ]] || run mkdir -p "$parent"
  run ln -s "$src" "$dst"
  info "Linked $dst -> $src"
}

layer_dotfiles() {
  step "Dotfiles"

  d="$SCRIPT_DIR/dotfiles"
  [[ -d "$d" ]] || { error "dotfiles/ not found at $d"; exit 1; }

  backup_then_link "$d/zshrc"                 "$HOME/.zshrc"
  backup_then_link "$d/zprofile"              "$HOME/.zprofile"
  backup_then_link "$d/p10k.zsh"              "$HOME/.p10k.zsh"
  backup_then_link "$d/gitconfig"             "$HOME/.gitconfig"
  backup_then_link "$d/config/git/ignore"     "$HOME/.config/git/ignore"

  # ~/.gitconfig-work and ~/.zshrc.local are machine-local by design: a work
  # identity and employer-specific env do not belong in a portable snapshot.
  # Both are optional — git ignores a missing include, .zshrc guards its source.
  [[ -e "$HOME/.gitconfig-work" ]] \
    && info "~/.gitconfig-work present (machine-local, not managed here)." \
    || info "No ~/.gitconfig-work; ~/work/ repos use the default git identity."
  [[ -e "$HOME/.zshrc.local" ]] \
    && info "~/.zshrc.local present (machine-local, not managed here)." \
    || info "No ~/.zshrc.local; add one for per-machine env such as GOPRIVATE."

  # .zshrc reads LINEAR_API_KEY from the login keychain. The value is a secret
  # and is deliberately absent from this repo.
  if security find-generic-password -a "$USER" -s LINEAR_API_KEY >/dev/null 2>&1; then
    info "LINEAR_API_KEY found in the login keychain."
  else
    warn "LINEAR_API_KEY is not in the keychain; .zshrc will export it empty. Add it with:"
    printf '    security add-generic-password -a "$USER" -s LINEAR_API_KEY -w\n'
  fi
}

# --- Layer: tooling ----------------------------------------------------------

go_tool() {
  module="$1"
  binary="$2"
  if [[ -x "$HOME/go/bin/$binary" ]]; then
    info "$binary already installed."
  else
    info "go install $module"
    run go install "$module"
  fi
}

layer_tooling() {
  step "Go tools, Claude Code, ~/.claude symlinks"

  if command -v go >/dev/null 2>&1; then
    go_tool "golang.org/x/tools/gopls@latest"                gopls
    go_tool "github.com/go-delve/delve/cmd/dlv@latest"        dlv
    go_tool "github.com/isaacphi/mcp-language-server@latest"  mcp-language-server
  else
    warn "go not on PATH; skipping Go tools. Run the brew layer first."
  fi

  if command -v claude >/dev/null 2>&1; then
    info "Claude Code CLI present at $(command -v claude)."
  else
    info "Installing the Claude Code CLI to ~/.local/bin."
    run_sh 'curl -fsSL https://claude.ai/install.sh | bash'
  fi

  # ~/.claude is runtime state; these four directories are symlinks into the
  # config repo. See ~/.claude/CLAUDE.md.
  if [[ -d "$CLAUDE_CONFIG_REPO" ]]; then
    for name in agents skills conventions output-styles; do
      link="$HOME/.claude/$name"
      if [[ -L "$link" && "$(readlink "$link")" == "$CLAUDE_CONFIG_REPO/$name" ]]; then
        info "~/.claude/$name already linked."
      else
        run mkdir -p "$HOME/.claude"
        run rm -rf "$link"
        run ln -s "$CLAUDE_CONFIG_REPO/$name" "$link"
        info "Linked ~/.claude/$name"
      fi
    done
  else
    warn "Claude config repo not found at $CLAUDE_CONFIG_REPO."
    warn "Clone it, then re-run with --only tooling:"
    printf '    git clone git@github.com:shaia/claude.git %s\n' "$CLAUDE_CONFIG_REPO"
  fi

  step "Manual steps this script deliberately leaves to you"
  printf '  gh auth login       # .gitconfig uses gh as its credential helper\n'
  printf '  open -a Docker      # first launch provisions the kubectl context\n'
  printf '  p10k configure      # only if you do not want the checked-in .p10k.zsh\n'
  printf '  ssh keys            # not in this repo; restore from your own backup\n'
}

# --- Layer: extensions -------------------------------------------------------

install_extensions() {
  cmd="$1"
  list="$2"
  label="$3"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    warn "$label CLI ('$cmd') not on PATH; skipping. Launch the app once and install its shell command."
    return 0
  fi
  if [[ ! -f "$list" ]]; then
    warn "$list not found; skipping $label extensions."
    return 0
  fi

  # One listing up front, so a re-run costs one call instead of ~90.
  present=" $("$cmd" --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr '\n' ' ') "

  total=0; already=0; added=0; failed=0
  while IFS= read -r id || [[ -n "$id" ]]; do
    case "$id" in ''|'#'*) continue ;; esac
    total=$((total + 1))

    lower=$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')
    case "$present" in
      *" $lower "*) already=$((already + 1)); continue ;;
    esac

    if [[ "$DRY_RUN" == true ]]; then
      printf "  + %s --install-extension %s --force\n" "$cmd" "$id"
      added=$((added + 1))
    elif "$cmd" --install-extension "$id" --force </dev/null >/dev/null 2>&1; then
      printf "  installed %s\n" "$id"
      added=$((added + 1))
    else
      warn "  failed: $id"
      failed=$((failed + 1))
    fi
  done < "$list"

  info "$label: $total listed, $already already present, $added installed, $failed failed."
  [[ $failed -gt 0 ]] && warn "$label: failures are usually extensions that were unpublished or renamed."
  return 0
}

layer_extensions() {
  step "Editor extensions"
  install_extensions code   "$SCRIPT_DIR/vscode-extensions.txt" "VS Code"
  install_extensions cursor "$SCRIPT_DIR/cursor-extensions.txt" "Cursor"
}

# --- Main --------------------------------------------------------------------

main() {
  if [[ "$DRY_RUN" == true ]]; then
    info "DRY RUN — nothing is changed. Mutating commands are printed with '+'."
  fi
  info "Layers:${LAYERS:- none}"

  preflight

  wants brew       && layer_brew
  wants zsh        && layer_zsh
  wants dotfiles   && layer_dotfiles
  wants tooling    && layer_tooling
  wants extensions && layer_extensions

  step "Done"
  if [[ -d "$BACKUP_DIR" ]]; then
    info "Replaced dotfiles were backed up to $BACKUP_DIR"
  fi
  info "Open a new terminal, or run: exec zsh"
}

main "$@"
