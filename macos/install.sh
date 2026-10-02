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
RUN_STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$HOME/.dotfiles-backup-$RUN_STAMP"
LOG_DIR="$HOME/.machines-setups/logs"
LOCK_DIR="${TMPDIR:-/tmp}/machines-setups-install.lock"

# Third-party installers are fetched at a pinned commit and checked against a
# SHA-256 before they run, rather than piped from a moving branch into a shell.
# To update: take a newer commit of the file, hash it, and change both values.
HOMEBREW_INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/09c62fc577ec170172b0a184060f141a2c622dc1/install.sh"
HOMEBREW_INSTALL_SHA256="5f333bbe53bc490e51e7ccb1df8779b3dd6ee73a1a7379efda216edb08ccb148"
OHMYZSH_INSTALL_URL="https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/76ac9fcddc4e93c15dc778b4c6234755ad714e5a/tools/install.sh"
OHMYZSH_INSTALL_SHA256="5574b96e94dbcb769f0d1592fa83aeb6ca2caf41c6ae5d76fcc7f04c524b4f55"

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

# run() with retries for network-bound commands: three attempts, 5 then 15
# seconds apart. A dry run never retries, because run() returns 0 there.
run_retry() {
  if run "$@"; then return 0; fi
  for delay in 5 15; do
    warn "  '$1 ${2:-}' failed; retrying in ${delay}s."
    sleep "$delay"
    if run "$@"; then return 0; fi
  done
  return 1
}

# --- Results -----------------------------------------------------------------
#
# Every step records one outcome, printed as a summary at the end:
#   ok       already in the desired state; nothing ran
#   changed  applied, and the re-check after applying confirmed it
#   failed   applied, but the re-check still fails (or the command failed)
#   flagged  best-effort work that could not be done here; the run continues
#   manual   needs something this script deliberately does not do
# Only failed makes the script exit non-zero. Counters and a newline-separated
# string rather than arrays, for bash 3.2 under set -u.

N_OK=0; N_CHANGED=0; N_FAILED=0; N_FLAGGED=0; N_MANUAL=0
NOTES=""

result() {
  status="$1"; name="$2"; detail="${3:-}"
  case "$status" in
    ok)      N_OK=$((N_OK + 1)) ;;
    changed) N_CHANGED=$((N_CHANGED + 1)) ;;
    failed)  N_FAILED=$((N_FAILED + 1)) ;;
    flagged) N_FLAGGED=$((N_FLAGGED + 1)) ;;
    manual)  N_MANUAL=$((N_MANUAL + 1)) ;;
  esac
  case "$status" in
    failed|flagged|manual)
      line="  [$(printf '%s' "$status" | tr '[:lower:]' '[:upper:]')] $name"
      if [[ -n "$detail" ]]; then line="$line - $detail"; fi
      NOTES="$NOTES$line
"
      ;;
  esac
  return 0
}

summary() {
  step "Summary"
  printf '  %s already fine, %s changed, %s failed, %s flagged, %s manual\n' \
    "$N_OK" "$N_CHANGED" "$N_FAILED" "$N_FLAGGED" "$N_MANUAL"
  if [[ -n "$NOTES" ]]; then printf '%s' "$NOTES"; fi
  return 0
}

# Download a pinned installer, verify its SHA-256, and run it with bash.
# Extra arguments are VAR=value pairs for its environment.
run_pinned_installer() {
  url="$1"; sha="$2"; shift 2
  if [[ "$DRY_RUN" == true ]]; then
    printf "  + curl -fsSL %s  (verify sha256 %s, then run)\n" "$url" "$sha"
    return 0
  fi
  tmp="$(mktemp)"
  if ! curl -fsSL "$url" -o "$tmp"; then
    rm -f "$tmp"; error "Download failed: $url"; return 1
  fi
  actual="$(shasum -a 256 "$tmp" | cut -d' ' -f1)"
  if [[ "$actual" != "$sha" ]]; then
    rm -f "$tmp"; error "Checksum mismatch for $url (expected $sha, got $actual)."; return 1
  fi
  if env "$@" /bin/bash "$tmp"; then status=0; else status=$?; fi
  rm -f "$tmp"
  return $status
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
    warn "Homebrew missing; installing (pinned installer, checksum verified)."
    # Interactive at a terminal (it asks for the admin password); unattended
    # only without one, as in CI, where sudo needs no password.
    brew_env="NONINTERACTIVE="
    [[ -t 0 ]] || brew_env="NONINTERACTIVE=1"
    run_pinned_installer "$HOMEBREW_INSTALL_URL" "$HOMEBREW_INSTALL_SHA256" "$brew_env" \
      || { error "Homebrew installation failed."; exit 1; }
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

  brew_updated=false
  for p in $PROFILES; do
    brewfile="$SCRIPT_DIR/profiles/$p.Brewfile"
    [[ -f "$brewfile" ]] || continue
    label="brew profile $p ($(grep -cE '^(brew|cask) "' "$brewfile" || true) entries)"
    # --no-upgrade on check too, or merely outdated packages count as missing.
    if [[ "$DRY_RUN" == false ]] && brew bundle check --file="$brewfile" --no-upgrade >/dev/null 2>&1; then
      result ok "$label"
      continue
    fi
    # Refresh Homebrew's package metadata once before installing anything.
    # With auto-update off (HOMEBREW_NO_AUTO_UPDATE, as on CI runners) the
    # metadata can be weeks old and name a download that no longer exists.
    # This updates the package list only; installed packages stay as they are.
    if [[ "$brew_updated" == false ]]; then
      run_retry brew update --quiet || warn "brew update failed; installing from the current metadata."
      brew_updated=true
    fi
    # --no-upgrade: install what is missing, leave existing versions alone.
    run_retry brew bundle install --file="$brewfile" --no-upgrade || true
    if [[ "$DRY_RUN" == true ]]; then
      result changed "$label" "dry run"
    elif brew bundle check --file="$brewfile" --no-upgrade >/dev/null 2>&1; then
      result changed "$label"
    else
      missing="$(brew bundle check --file="$brewfile" --verbose --no-upgrade 2>&1 | grep -i 'needs to be installed' | tr '\n' ' ' || true)"
      result failed "$label" "still missing: $missing"
    fi
  done
}

# --- Layer: zsh --------------------------------------------------------------

layer_zsh() {
  step "zsh and oh-my-zsh"

  omz="$HOME/.oh-my-zsh"
  if [[ -d "$omz" ]]; then
    result ok "oh-my-zsh"
  else
    # KEEP_ZSHRC stops the installer replacing the .zshrc this repo owns;
    # RUNZSH and CHSH stop it taking over the terminal mid-script.
    info "Installing oh-my-zsh (pinned installer, checksum verified; keeping any existing .zshrc)."
    run_pinned_installer "$OHMYZSH_INSTALL_URL" "$OHMYZSH_INSTALL_SHA256" KEEP_ZSHRC=yes RUNZSH=no CHSH=no || true
    if [[ "$DRY_RUN" == true ]]; then result changed "oh-my-zsh" "dry run"
    elif [[ -d "$omz" ]]; then result changed "oh-my-zsh"
    else result failed "oh-my-zsh" "installer did not create $omz"; fi
  fi

  if [[ "${SHELL:-}" == */zsh ]]; then
    result ok "login shell zsh"
  elif [[ -t 0 ]]; then
    warn "Login shell is ${SHELL:-unknown}; switching to /bin/zsh (asks for your password)."
    if run chsh -s /bin/zsh; then result changed "login shell zsh"
    else result failed "login shell zsh" "chsh -s /bin/zsh failed"; fi
  else
    # chsh asks for a password; without a terminal it would hang.
    result manual "login shell zsh" "no terminal to ask for the password; run: chsh -s /bin/zsh"
  fi
}

# --- Layer: dotfiles ---------------------------------------------------------

backup_then_link() {
  src="$1"
  dst="$2"

  if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
    result ok "link $dst"
    return 0
  fi

  if [[ -e "$dst" || -L "$dst" ]]; then
    run mkdir -p "$BACKUP_DIR"
    info "Backing up $dst -> $BACKUP_DIR/"
    run mv "$dst" "$BACKUP_DIR/"
  fi

  parent="$(dirname "$dst")"
  [[ -d "$parent" ]] || run mkdir -p "$parent"
  run ln -s "$src" "$dst" || true
  if [[ "$DRY_RUN" == true ]]; then result changed "link $dst" "dry run"
  elif [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then result changed "link $dst"
  else result failed "link $dst" "ln -s failed; the original is in $BACKUP_DIR"; fi
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

# Installed npm globals and uv tools, space-padded for in_set.
npm_globals() {
  printf ' %s ' "$(npm ls -g --depth=0 --parseable 2>/dev/null | tr '\\' '/' | sed -n 's|.*/node_modules/||p' | tr '\n' ' ')"
}
uv_tools_installed() {
  printf ' %s ' "$(uv tool list 2>/dev/null | awk '$2 ~ /^v/ { print tolower($1) }' | tr '\n' ' ')"
}

layer_tooling() {
  step "Go tools, npm globals, uv Pythons and tools, Rust toolchain"

  go_modules="$(common_entries go)"
  if [[ -n "$go_modules" ]]; then
    if command -v go >/dev/null 2>&1; then
      gobin="$(go env GOPATH)/bin"
      for module in $go_modules; do
        name="$(go_binary_name "$module")"
        if [[ -x "$gobin/$name" ]]; then
          result ok "go install $name"
        else
          info "go install $module"
          run_retry go install "$module" || true
          if [[ "$DRY_RUN" == true ]]; then result changed "go install $name" "dry run"
          elif [[ -x "$gobin/$name" ]]; then result changed "go install $name"
          else result failed "go install $name" "$gobin/$name was not created"; fi
        fi
      done
    else
      result flagged "go tools" "go not on PATH; open a new shell after the packages layer and re-run --only tooling"
    fi
  fi

  npm_packages="$(common_entries npm)"
  if [[ -n "$npm_packages" ]]; then
    if command -v npm >/dev/null 2>&1; then
      for pkg in $npm_packages; do
        if in_set "$pkg" "$(npm_globals)"; then
          result ok "npm global $pkg"
        else
          info "npm install -g $pkg"
          run_retry npm install -g "$pkg" || true
          if [[ "$DRY_RUN" == true ]]; then result changed "npm global $pkg" "dry run"
          elif in_set "$pkg" "$(npm_globals)"; then result changed "npm global $pkg"
          else result failed "npm global $pkg" "npm install -g did not install it"; fi
        fi
      done
    else
      result flagged "npm globals" "npm not on PATH; open a new shell after the packages layer and re-run --only tooling"
    fi
  fi

  pythons="$(common_entries uv-python)"
  if [[ -n "$pythons" ]]; then
    if command -v uv >/dev/null 2>&1; then
      for v in $pythons; do
        if uv python list --only-installed 2>/dev/null | grep -q "^cpython-$v\."; then
          result ok "Python $v"
        else
          info "uv python install $v"
          run_retry uv python install "$v" || true
          if [[ "$DRY_RUN" == true ]]; then result changed "Python $v" "dry run"
          elif uv python list --only-installed 2>/dev/null | grep -q "^cpython-$v\."; then result changed "Python $v"
          else result failed "Python $v" "uv python install did not install it"; fi
        fi
      done
    else
      result flagged "uv Pythons" "uv not on PATH; open a new shell after the packages layer and re-run --only tooling"
    fi
  fi

  # Command-line tools uv installs into their own isolated environments.
  uv_tools="$(common_entries uv-tool)"
  if [[ -n "$uv_tools" ]]; then
    if command -v uv >/dev/null 2>&1; then
      # `uv tool list` prints "<name> v<version>" for each tool, then its executables.
      for tool in $uv_tools; do
        lower=$(printf '%s' "$tool" | tr '[:upper:]' '[:lower:]')
        if in_set "$lower" "$(uv_tools_installed)"; then
          result ok "uv tool $tool"
        else
          info "uv tool install $tool"
          run_retry uv tool install "$tool" || true
          if [[ "$DRY_RUN" == true ]]; then result changed "uv tool $tool" "dry run"
          elif in_set "$lower" "$(uv_tools_installed)"; then result changed "uv tool $tool"
          else result failed "uv tool $tool" "uv tool install did not install it"; fi
        fi
      done
    else
      result flagged "uv tools" "uv not on PATH; open a new shell after the packages layer and re-run --only tooling"
    fi
  fi

  # Homebrew's rustup installs the manager only; it has no toolchain until
  # one is chosen.
  if in_set rust "$PROFILES"; then
    if command -v rustup >/dev/null 2>&1; then
      if rustup default >/dev/null 2>&1; then
        result ok "Rust toolchain"
      else
        info "rustup default stable"
        run_retry rustup default stable || true
        if [[ "$DRY_RUN" == true ]]; then result changed "Rust toolchain" "dry run"
        elif rustup default >/dev/null 2>&1; then result changed "Rust toolchain"
        else result failed "Rust toolchain" "rustup default stable failed"; fi
      fi
    else
      result flagged "Rust toolchain" "rustup not on PATH; open a new shell after the packages layer and re-run --only tooling"
    fi
  fi

  step "Manual steps this script deliberately leaves to you"
  printf '  gh auth login       # then move what it writes into ~/.gitconfig (a link into\n'
  printf '                      # this repo) over to ~/.gitconfig-local\n'
  printf '  ~/.gitconfig-local  # your git identity; see the dotfiles layer message\n'
  printf '  ssh keys            # not in this repo; generate or restore your own\n'
  printf '  Docker Desktop      # containers profile: launch once to finish setup\n'
  printf '  Warp settings       # Appearance > Prompt: honour the custom prompt (PS1), so starship\n'
  printf '                      # shows; Appearance > Text: font JetBrainsMono Nerd Font\n'
  printf '  iTerm2 font         # Settings > Profiles > Text: JetBrainsMono Nerd Font\n'
}

# --- Layer: extensions -------------------------------------------------------

layer_extensions() {
  step "VS Code extensions"

  ids="$(common_entries vscode)"
  [[ -n "$ids" ]] || { info "No extensions in the selected profiles."; return 0; }
  if ! command -v code >/dev/null 2>&1; then
    result flagged "VS Code extensions" "code not on PATH; open a new shell after the packages layer and re-run --only extensions"
    return 0
  fi

  # One listing up front, so a re-run costs one call instead of one per extension.
  present=" $(code --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr '\n' ' ') "

  total=0; already=0; added=0; failed=0
  for id in $ids; do
    total=$((total + 1))
    lower=$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')
    if in_set "$lower" "$present"; then
      result ok "VS Code extension $id"
      already=$((already + 1)); continue
    fi
    run_retry code --install-extension "$id" </dev/null >/dev/null 2>&1 || true
    if [[ "$DRY_RUN" == true ]]; then
      printf "  + code --install-extension %s\n" "$id"
      result changed "VS Code extension $id" "dry run"
      added=$((added + 1))
    elif code --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -qx "$lower"; then
      printf "  installed %s\n" "$id"
      result changed "VS Code extension $id"
      added=$((added + 1))
    else
      result failed "VS Code extension $id" "usually an extension that was unpublished or renamed"
      failed=$((failed + 1))
    fi
  done

  info "VS Code: $total listed, $already already present, $added installed, $failed failed."
  return 0
}

# --- Main --------------------------------------------------------------------

main() {
  # One run at a time: two runs would race over the same brew installs. mkdir
  # is atomic, so it doubles as the lock.
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    error "Another install.sh is already running (lock: $LOCK_DIR). If none is, remove that directory."
    exit 3
  fi
  trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

  # A log of every run, dry runs included, for when the terminal has scrolled away.
  mkdir -p "$LOG_DIR"
  log_file="$LOG_DIR/install-$RUN_STAMP.log"
  exec > >(tee -a "$log_file") 2>&1

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

  summary
  printf '\n'
  if [[ -d "$BACKUP_DIR" ]]; then
    info "Replaced dotfiles were backed up to $BACKUP_DIR"
  fi
  info "Log: $log_file"
  info "Open a new terminal, or run: exec zsh -l"
  if [[ $N_FAILED -gt 0 ]]; then exit 1; fi
}

main "$@"
