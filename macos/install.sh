#!/usr/bin/env bash
#
# Set up an opinionated macOS development machine: a core every developer
# gets, plus the language and tool profiles you pick.
#
#   ./install.sh                          # core only; lists the profiles
#   ./install.sh --profile go,python,web  # core plus those profiles
#   ./install.sh --profile all            # everything
#   ./install.sh --only dotfiles          # just that layer
#   ./install.sh --skip extensions        # every layer but that one
#   ./install.sh --dry-run                # print every mutating command, run none
#
# Profiles live in two halves: macos/profiles/<name>.Brewfile and
# common/profiles/<name>.txt (VS Code extensions, Go tools, npm globals, uv
# Pythons, shared with Windows). Preflight (Command Line Tools + Homebrew)
# always runs. Every layer is safe to re-run: it inspects the current state,
# skips what is already satisfied, and says what it skipped.
#
# Written for the bash 3.2 that ships with macOS - no mapfile, no ${x,,}, no
# associative arrays - so it runs on a box where nothing has been installed yet.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMON_DIR="$REPO_ROOT/common"
BACKUP_DIR="$HOME/.dotfiles-backup-$(date +%Y%m%d-%H%M%S)"

case "$(uname -m)" in
  arm64) BREW_PREFIX="/opt/homebrew" ;;
  *)     BREW_PREFIX="/usr/local" ;;
esac

ALL_LAYERS="packages zsh dotfiles tooling extensions"
LAYERS="$ALL_LAYERS"
DRY_RUN=false
REQUESTED_PROFILES=""

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

# --- Profiles ----------------------------------------------------------------

# Every name with a file in either half; core is implicit, never listed.
available_profiles() {
  {
    for f in "$SCRIPT_DIR"/profiles/*.Brewfile; do
      [[ -e "$f" ]] && basename "$f" .Brewfile
    done
    for f in "$COMMON_DIR"/profiles/*.txt; do
      [[ -e "$f" ]] && basename "$f" .txt
    done
  } | { grep -vx core || true; } | sort -u | tr '\n' ' ' | sed 's/ $//'
}
AVAILABLE_PROFILES="$(available_profiles)"

# Space-padded sets rather than arrays: bash 3.2 errors on "${empty[@]}" under
# `set -u`, and --skip can legitimately empty the layer set.
in_set() {
  case " $2 " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

wants() { in_set "$1" "$LAYERS"; }

# Second field of every "<kind> <value>" line across the selected profiles'
# common halves, comments stripped, first occurrence kept.
common_entries() {
  kind="$1"
  for p in $PROFILES; do
    f="$COMMON_DIR/profiles/$p.txt"
    [[ -f "$f" ]] || continue
    sed -e 's/#.*$//' "$f" | awk -v k="$kind" '$1 == k && NF >= 2 { print $2 }'
  done | awk '!seen[tolower($0)]++'
}

# --- Argument parsing --------------------------------------------------------

usage() {
  cat <<EOF
Usage: install.sh [options]

  --profile <names>  Add these profiles to core (comma-separated), or 'all'.
  --only    <layers> Run only these layers (comma-separated).
  --skip    <layers> Run every layer except these.
  --dry-run          Print every mutating command without running it.
  -h, --help         This message.

Profiles: $AVAILABLE_PROFILES
Layers:   $ALL_LAYERS
EOF
  exit "${1:-0}"
}

# Validates a comma-separated list against a space-separated set; prints it
# space-separated.
parse_list() {
  what="$1"; valid="$2"; raw="$3"
  out=""
  for name in $(printf '%s' "$raw" | tr ',' ' '); do
    in_set "$name" "$valid" || { error "Unknown $what '$name'. Valid: $valid"; exit 2; }
    out="$out $name"
  done
  printf '%s' "$out"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only|--skip|--profile)
      [[ $# -ge 2 ]] || { error "$1 needs a comma-separated list"; exit 2; }
      case "$1" in
        --profile) REQUESTED_PROFILES="$(parse_list profile "$AVAILABLE_PROFILES all" "$2")" ;;
        --only)    LAYERS="$(parse_list layer "$ALL_LAYERS" "$2")" ;;
        --skip)
          skipping="$(parse_list layer "$ALL_LAYERS" "$2")"
          kept=""
          for layer in $LAYERS; do
            in_set "$layer" "$skipping" || kept="$kept $layer"
          done
          LAYERS="$kept"
          ;;
      esac
      shift 2
      ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage 0 ;;
    *) error "Unknown option: $1"; usage 2 ;;
  esac
done

in_set all "$REQUESTED_PROFILES" && REQUESTED_PROFILES="$AVAILABLE_PROFILES"
PROFILES="core"
for p in $AVAILABLE_PROFILES; do
  in_set "$p" "$REQUESTED_PROFILES" && PROFILES="$PROFILES $p"
done

# --- Preflight ---------------------------------------------------------------
#
# Always runs. Its mutating actions are all guarded by "if missing", so on an
# already-configured machine this is read-only.

preflight() {
  step "Preflight"

  [[ "$(uname -s)" == "Darwin" ]] || { error "macOS only; this is $(uname -s)."; exit 1; }
  info "macOS on $(uname -m); Homebrew prefix $BREW_PREFIX."

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

# --- Layer: packages ---------------------------------------------------------

layer_packages() {
  step "Homebrew packages"

  for p in $PROFILES; do
    brewfile="$SCRIPT_DIR/profiles/$p.Brewfile"
    [[ -f "$brewfile" ]] || continue
    info "Profile $p: $(grep -cE '^(brew|cask) "' "$brewfile" || true) entries."
    # --no-upgrade: install what is missing, leave existing versions alone.
    if run brew bundle install --file="$brewfile" --no-upgrade; then
      :
    else
      warn "brew bundle reported failures for $p; the check below lists what is missing."
    fi
    if [[ "$DRY_RUN" == false ]] && ! brew bundle check --file="$brewfile" --no-upgrade >/dev/null 2>&1; then
      warn "Profile $p: some entries are still missing:"
      brew bundle check --file="$brewfile" --verbose --no-upgrade || true
    fi
  done
}

# --- Layer: zsh --------------------------------------------------------------

layer_zsh() {
  step "zsh and oh-my-zsh"

  omz="$HOME/.oh-my-zsh"
  if [[ -d "$omz" ]]; then
    info "oh-my-zsh already installed at $omz."
  else
    # KEEP_ZSHRC stops the installer replacing the .zshrc this repo owns;
    # RUNZSH and CHSH stop it taking over the terminal mid-script.
    info "Installing oh-my-zsh (keeping any existing .zshrc)."
    run_sh 'KEEP_ZSHRC=yes RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"'
  fi

  if [[ "${SHELL:-}" == */zsh ]]; then
    info "Login shell is already zsh."
  else
    warn "Login shell is ${SHELL:-unknown}; switching to /bin/zsh (may prompt for your password)."
    run chsh -s /bin/zsh
  fi
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
  backup_then_link "$d/zshrc"                       "$HOME/.zshrc"
  backup_then_link "$d/zprofile"                    "$HOME/.zprofile"
  backup_then_link "$COMMON_DIR/git/gitconfig"      "$HOME/.gitconfig"
  backup_then_link "$COMMON_DIR/git/ignore"         "$HOME/.config/git/ignore"
  backup_then_link "$COMMON_DIR/starship.toml"      "$HOME/.config/starship.toml"
  if command -v delta >/dev/null 2>&1; then
    backup_then_link "$COMMON_DIR/git/delta.gitconfig" "$HOME/.config/git/delta.gitconfig"
  else
    info "delta not on PATH; git keeps its default pager. Re-run --only dotfiles once it is installed."
  fi

  # Machine-local by design: identity, a work identity and per-machine env do
  # not belong in a shared baseline. All optional: git ignores a missing
  # include, .zshrc guards its source.
  if [[ -e "$HOME/.gitconfig-local" ]]; then
    info "~/.gitconfig-local present (machine-local, not managed here)."
  else
    warn "No ~/.gitconfig-local. Git has no identity, so commits will fail with"
    warn "  'unable to auto-detect email address'. Create it with:"
    printf '    printf "[user]\\n\\tname = NAME\\n\\temail = EMAIL\\n" > ~/.gitconfig-local\n'
  fi
  if [[ -e "$HOME/.gitconfig-work" ]]; then
    info "~/.gitconfig-work present (machine-local, not managed here)."
  else
    info "No ~/.gitconfig-work; repos under ~/work/ or ~/development/work/ use the default identity."
  fi
  if [[ -e "$HOME/.zshrc.local" ]]; then
    info "~/.zshrc.local present (machine-local, not managed here)."
  else
    info "No ~/.zshrc.local; add one for per-machine env and secrets."
  fi
}

# --- Layer: tooling ----------------------------------------------------------

# golang.org/x/tools/gopls@latest -> gopls; .../golangci-lint/v2/cmd/golangci-lint -> golangci-lint.
go_binary_name() {
  path="${1%@*}"
  last="${path##*/}"
  case "$last" in
    v[0-9]*) path="${path%/*}"; last="${path##*/}" ;;
  esac
  printf '%s' "$last"
}

layer_tooling() {
  step "Go tools, npm globals, uv Pythons, Rust toolchain"

  go_modules="$(common_entries go)"
  if [[ -n "$go_modules" ]]; then
    if command -v go >/dev/null 2>&1; then
      gobin="$(go env GOPATH)/bin"
      for module in $go_modules; do
        name="$(go_binary_name "$module")"
        if [[ -x "$gobin/$name" ]]; then
          info "$name already installed."
        else
          info "go install $module"
          run go install "$module"
        fi
      done
    else
      warn "go not on PATH; skipping Go tools. Run the packages layer first."
    fi
  fi

  npm_packages="$(common_entries npm)"
  if [[ -n "$npm_packages" ]]; then
    if command -v npm >/dev/null 2>&1; then
      present=" $(npm ls -g --depth=0 --parseable 2>/dev/null | tr '\\' '/' | sed -n 's|.*/node_modules/||p' | tr '\n' ' ') "
      for pkg in $npm_packages; do
        if in_set "$pkg" "$present"; then
          info "npm: $pkg already installed."
        else
          info "npm install -g $pkg"
          run npm install -g "$pkg"
        fi
      done
    else
      warn "npm not on PATH; skipping npm globals. Run the packages layer first."
    fi
  fi

  pythons="$(common_entries uv-python)"
  if [[ -n "$pythons" ]]; then
    if command -v uv >/dev/null 2>&1; then
      installed="$(uv python list --only-installed 2>/dev/null || true)"
      for v in $pythons; do
        if printf '%s\n' "$installed" | grep -q "^cpython-$v\."; then
          info "Python $v already installed."
        else
          info "uv python install $v"
          run uv python install "$v"
        fi
      done
    else
      warn "uv not on PATH; skipping Python. Run the packages layer first."
    fi
  fi

  # Homebrew's rustup installs the manager only; it has no toolchain until
  # one is chosen.
  if in_set rust "$PROFILES"; then
    if command -v rustup >/dev/null 2>&1; then
      if rustup default >/dev/null 2>&1; then
        info "Rust toolchain present ($(rustup default 2>/dev/null))."
      else
        info "rustup default stable"
        run rustup default stable
      fi
    else
      warn "rustup not on PATH; skipping the Rust toolchain. Run the packages layer first."
    fi
  fi

  step "Manual steps this script deliberately leaves to you"
  printf '  gh auth login       # then move what it writes into ~/.gitconfig (a link into\n'
  printf '                      # this repo) over to ~/.gitconfig-local\n'
  printf '  ~/.gitconfig-local  # your git identity; see the dotfiles layer message\n'
  printf '  ssh keys            # not in this repo; generate or restore your own\n'
  printf '  Docker Desktop      # containers profile: launch once to finish setup\n'
  printf '  iTerm2 font         # Settings > Profiles > Text: JetBrainsMono Nerd Font\n'
}

# --- Layer: extensions -------------------------------------------------------

layer_extensions() {
  step "VS Code extensions"

  ids="$(common_entries vscode)"
  [[ -n "$ids" ]] || { info "No extensions in the selected profiles."; return 0; }
  if ! command -v code >/dev/null 2>&1; then
    warn "VS Code CLI ('code') not on PATH; skipping. Open a new shell after the packages layer."
    return 0
  fi

  # One listing up front, so a re-run costs one call instead of one per extension.
  present=" $(code --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr '\n' ' ') "

  total=0; already=0; added=0; failed=0
  for id in $ids; do
    total=$((total + 1))
    lower=$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')
    if in_set "$lower" "$present"; then
      already=$((already + 1)); continue
    fi
    if [[ "$DRY_RUN" == true ]]; then
      printf "  + code --install-extension %s\n" "$id"
      added=$((added + 1))
    elif code --install-extension "$id" </dev/null >/dev/null 2>&1; then
      printf "  installed %s\n" "$id"
      added=$((added + 1))
    else
      warn "  failed: $id"
      failed=$((failed + 1))
    fi
  done

  info "VS Code: $total listed, $already already present, $added installed, $failed failed."
  [[ $failed -gt 0 ]] && warn "Failures are usually extensions that were unpublished or renamed."
  return 0
}

# --- Main --------------------------------------------------------------------

main() {
  if [[ "$DRY_RUN" == true ]]; then
    info "DRY RUN - nothing is changed. Mutating commands are printed with '+'."
  fi
  info "Profiles: $PROFILES"
  [[ "$PROFILES" == "core" ]] && info "  Core only. Add any of these with --profile: $AVAILABLE_PROFILES"
  layer_text="$(printf '%s' "$LAYERS" | sed 's/^ *//')"
  info "Layers: ${layer_text:-none}"

  preflight

  if wants packages;   then layer_packages;   fi
  if wants zsh;        then layer_zsh;        fi
  if wants dotfiles;   then layer_dotfiles;   fi
  if wants tooling;    then layer_tooling;    fi
  if wants extensions; then layer_extensions; fi

  step "Done"
  if [[ -d "$BACKUP_DIR" ]]; then
    info "Replaced dotfiles were backed up to $BACKUP_DIR"
  fi
  info "Open a new terminal, or run: exec zsh -l"
}

main "$@"
