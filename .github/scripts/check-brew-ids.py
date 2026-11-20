#!/usr/bin/env python3
"""Check every brew and cask name in macos/profiles/*.Brewfile against Homebrew.

Reads Homebrew's published catalogs from formulae.brew.sh, the same data
`brew` installs from, so it runs on any OS without Homebrew and installs
nothing. CI installs only a few profiles; this catches a renamed or removed
package in the rest.

Fails on a name Homebrew does not know, or has disabled. Warns on a deprecated
package, and on a name that resolves only as an alias or a pre-rename name:
`brew bundle` still accepts those, but the Brewfile should say the real name.

Usage: check-brew-ids.py [--catalog-dir DIR]
  --catalog-dir  read formula.json and cask.json from DIR instead of
                 downloading them (they are ~50 MB together)
Exit status: 0 when every name resolves, 1 otherwise.
"""

import argparse
import json
import os
import re
import sys
import time
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
API = "https://formulae.brew.sh/api/{}.json"
LINE = re.compile(r'^\s*(brew|cask)\s+"([^"]+)"')
IN_CI = os.environ.get("GITHUB_ACTIONS") == "true"


def load_catalog(kind, catalog_dir):
    if catalog_dir:
        with open(Path(catalog_dir) / f"{kind}.json", encoding="utf-8") as f:
            return json.load(f)
    for attempt in range(3):
        try:
            with urllib.request.urlopen(API.format(kind), timeout=120) as resp:
                return json.load(resp)
        except OSError as e:
            if attempt == 2:
                raise
            print(f"fetching the {kind} catalog failed ({e}); retrying", file=sys.stderr)
            time.sleep(10)


def index(entries, primary, alt_names, old_names):
    """Map every name a package answers to onto (entry, how it matched)."""
    by_name = {}
    for e in entries:
        for n in old_names(e):
            by_name.setdefault(n, (e, "old name"))
        for n in alt_names(e):
            by_name[n] = (e, "alias")
    for e in entries:
        by_name[e[primary]] = (e, "name")
    return by_name


def report(level, path, lineno, message):
    rel = path.relative_to(REPO).as_posix()
    if IN_CI:
        print(f"::{level} file={rel},line={lineno}::{message}")
    else:
        print(f"{level.upper():8} {rel}:{lineno}: {message}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--catalog-dir")
    args = parser.parse_args()

    formulae = index(
        load_catalog("formula", args.catalog_dir), "name",
        lambda e: e.get("aliases") or [],
        lambda e: e.get("oldnames") or [],
    )
    casks = index(
        load_catalog("cask", args.catalog_dir), "token",
        lambda e: [],
        lambda e: e.get("old_tokens") or [],
    )

    errors = warnings = checked = 0
    for path in sorted((REPO / "macos" / "profiles").glob("*.Brewfile")):
        for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            m = LINE.match(line)
            if not m:
                continue
            kind, name = m.groups()
            checked += 1
            if "/" in name:
                report("warning", path, lineno, f"{kind} {name}: from a third-party tap, not checked")
                warnings += 1
                continue
            table, primary = (formulae, "name") if kind == "brew" else (casks, "token")
            hit = table.get(name)
            if hit is None:
                report("error", path, lineno, f'{kind} "{name}" is not in Homebrew')
                errors += 1
                continue
            entry, how = hit
            real = entry[primary]
            if entry.get("disabled"):
                reason = entry.get("disable_reason") or "no reason given"
                report("error", path, lineno, f'{kind} "{name}" is disabled in Homebrew ({reason})')
                errors += 1
                continue
            if how != "name":
                report("warning", path, lineno, f'{kind} "{name}" is an {how} of "{real}"; use "{real}"')
                warnings += 1
            if entry.get("deprecated"):
                reason = entry.get("deprecation_reason") or "no reason given"
                when = entry.get("disable_date")
                note = f"; disabled from {when}" if when else ""
                report("warning", path, lineno, f'{kind} "{real}" is deprecated ({reason}{note})')
                warnings += 1
            if how == "name" and not entry.get("deprecated"):
                print(f"ok       {kind} {name}")

    print(f"\n{checked} names checked: {errors} errors, {warnings} warnings.")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
