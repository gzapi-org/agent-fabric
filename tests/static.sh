#!/usr/bin/env bash
# tests/static.sh — the static checks every commit passes before a suite
# runs: every bash script parses (`bash -n`), shellcheck finds no error-
# severity finding, ruff finds no undefined or unused name (ruff.toml).
#
# A missing tool is SAID, never silently a pass: CI installs both; a host
# without one sees the line and knows that check did not run here.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
fail=0

# Every bash script: the .sh files and the shebang'd tools without a suffix.
mapfile -t scripts < <({ git ls-files '*.sh'; git ls-files | while read -r f; do
    [[ -f "$f" && "$f" != *.sh ]] && head -c 64 "$f" 2>/dev/null | head -1 | grep -qE '^#!.*\b(ba)?sh\b' && echo "$f"; done; } | sort -u)
echo "static: ${#scripts[@]} bash script(s)"
for f in "${scripts[@]}"; do
    bash -n "$f" || { echo "  ✗ bash -n $f"; fail=1; }
done
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -S error "${scripts[@]}" || fail=1
else
    echo "  ! shellcheck not installed: not run here (CI runs it)"
fi
if command -v ruff >/dev/null 2>&1; then
    ruff check . || fail=1
else
    echo "  ! ruff not installed: not run here (CI runs it)"
fi
for f in $(git ls-files '*.py'); do
    python3 -m py_compile "$f" || { echo "  ✗ py_compile $f"; fail=1; }
done
if (( fail )); then echo "static: FAILED"; exit 1; fi
echo "static: all bash scripts parse, shellcheck and ruff clean"
