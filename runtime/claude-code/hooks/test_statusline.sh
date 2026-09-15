#!/usr/bin/env bash
# runtime/claude-code/hooks/test_statusline.sh — the status line's branch
# segment: a branch name inside a repository, the short SHA on a detached
# HEAD, and NO segment outside a repository (the parent projects/
# workspace), which used to read "detached" and sent the owner looking for
# a branch nobody had made (2026-09-15). Each case runs the real script
# against a throwaway git repo.
set -uo pipefail
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" && pwd )"
UNDER_TEST="$SCRIPT_DIR/statusline.sh"
failures=0
SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1: $2" >&2; failures=$((failures + 1)); }
line_of() { printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"M"}}' "$1" | bash "$UNDER_TEST" 2>/dev/null; }
g() { git -C "$repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@" >/dev/null 2>&1; }

repo="$SANDBOX/clone"; mkdir -p "$repo"; g init -q; g commit -q --allow-empty -m one; g branch -M main
out="$(line_of "$repo")"
[[ "$out" == *"📁 clone 🌿 main" ]] && pass "inside a repository: the branch" || fail "branch" "$out"
git -C "$repo" checkout -q --detach main
sha="$(git -C "$repo" rev-parse --short HEAD)"
out="$(line_of "$repo")"
[[ "$out" == *"📁 clone 🌿 $sha" ]] && pass "a detached HEAD: its short SHA, never the word" || fail "detached" "$out"
plain="$SANDBOX/projects"; mkdir -p "$plain"
out="$(line_of "$plain")"
[[ "$out" == *"📁 projects" && "$out" != *"🌿"* ]] && pass "outside a repository: no branch segment at all" || fail "no repo" "$out"
[[ "$out" != *detached* ]] && pass "…and the word 'detached' appears nowhere" || fail "detached word" "$out"

if (( failures )); then echo "test_statusline: FAILED — $failures"; exit 1; fi
echo "test_statusline: OK — all assertions passed."
