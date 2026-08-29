#!/usr/bin/env bash
#
# Regenerate this directory's inventory from the machine it runs on, so the
# checked-in snapshot does not rot as packages come and go.
#
#   ./snapshot.sh            # rewrite Brewfile and both extension lists
#   ./snapshot.sh --diff     # show what would change, write nothing
#
# dotfiles/ is not touched: install.sh symlinks those into $HOME, so edits to
# ~/.zshrc land in this repo already.
#
# `brew bundle dump` emits a flat, undescribed Brewfile. The curated version in
# this repo has section headers and a "deliberately NOT installed" block at the
# bottom that dump cannot know about, so this script writes the generated file
# to Brewfile.generated and leaves reconciling the two to you.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIFF_ONLY=false

info()  { printf "[INFO] %s\n" "$*"; }
warn()  { printf "[WARN] %s\n" "$*"; }
error() { printf "[ERROR] %s\n" "$*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --diff) DIFF_ONLY=true; shift ;;
    -h|--help) sed -n '3,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) error "Unknown option: $1"; exit 2 ;;
  esac
done

command -v brew >/dev/null 2>&1 || { error "Homebrew not on PATH."; exit 1; }

# --- Homebrew ----------------------------------------------------------------

generated="$SCRIPT_DIR/Brewfile.generated"
info "Dumping current Homebrew state to $(basename "$generated")"
brew bundle dump --file="$generated" --force

# Compare package tokens only; the curated Brewfile's comments and ordering are
# intentional and would otherwise dominate the diff.
tokens() { grep -E '^(brew|cask|tap|mas) "' "$1" | sed 's/,.*//' | sort; }

if diff -u <(tokens "$SCRIPT_DIR/Brewfile") <(tokens "$generated") > /dev/null; then
  info "Brewfile is up to date."
  rm -f "$generated"
else
  warn "Brewfile differs from the live machine:"
  diff -u <(tokens "$SCRIPT_DIR/Brewfile") <(tokens "$generated") \
    | sed -n '3,$p' | sed 's/^/    /' || true
  if [[ "$DIFF_ONLY" == true ]]; then
    rm -f "$generated"
  else
    warn "Merge the changes into Brewfile by hand, keeping its section headers"
    warn "and the 'deliberately NOT installed' block, then delete $(basename "$generated")."
  fi
fi

# --- Editor extensions -------------------------------------------------------

dump_extensions() {
  local cmd="$1" out="$2" label="$3" header="$4"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    warn "$label CLI ('$cmd') not on PATH; leaving $(basename "$out") alone."
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  {
    printf '# %s\n' "$header"
    printf '# Regenerate with ./snapshot.sh\n'
    "$cmd" --list-extensions
  } > "$tmp"

  if diff -q "$out" "$tmp" >/dev/null 2>&1; then
    info "$label extensions unchanged ($(grep -cv '^#' "$out") listed)."
    rm -f "$tmp"
    return 0
  fi

  warn "$label extensions changed:"
  diff <(grep -v '^#' "$out" 2>/dev/null || true) <(grep -v '^#' "$tmp") \
    | grep -E '^[<>]' | sed 's/^/    /' || true

  if [[ "$DIFF_ONLY" == true ]]; then
    rm -f "$tmp"
  else
    mv "$tmp" "$out"
    info "Wrote $(basename "$out")."
  fi
}

dump_extensions code   "$SCRIPT_DIR/vscode-extensions.txt" "VS Code" \
  "VS Code extensions — restored by install.sh via: code --install-extension"
dump_extensions cursor "$SCRIPT_DIR/cursor-extensions.txt" "Cursor" \
  "Cursor extensions — restored by install.sh via: cursor --install-extension"

info "Done. dotfiles/ needs no refresh — install.sh symlinks them into \$HOME."
