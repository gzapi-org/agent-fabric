#!/usr/bin/env bash
# Behavioural tests for .claude/tab-title.sh.
#
# What this exists to hold still: the hook's OUTPUT CONTRACT. Claude Code
# reads one field, "terminalSequence", and silently drops anything outside a
# narrow escape allowlist -- so a wrong shape does not error, it just stops
# setting the title, which is indistinguishable from the feature never having
# been wired. Nothing else in the repo would notice.
#
# The second thing it holds still is that the hook NEVER FAILS LOUDLY. It runs
# after every Bash tool call; a non-zero exit or stray stdout on a malformed
# payload would turn a cosmetic feature into a broken session.
#
# Each case runs the REAL script against a throwaway git repo, so the branch
# and detached-HEAD readings come from git rather than from a stub.
#
# Exit codes:
#   0  all assertions passed
#   1  one or more assertions failed
set -uo pipefail

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" && pwd )"
UNDER_TEST="$SCRIPT_DIR/tab-title.sh"
[[ -f "$UNDER_TEST" ]] || { echo "test: not found: $UNDER_TEST" >&2; exit 1; }

failures=0
SANDBOX="$(mktemp -d)"
cleanup() { [[ -n "${SANDBOX:-}" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1" >&2; [[ $# -gt 1 ]] && printf '       %s\n' "$2" >&2; failures=$((failures + 1)); }

assert_eq() {
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want: $2"; fail_detail "got:  $3"; fi
}
fail_detail() { printf '       %s\n' "$1" >&2; }

# The title is the payload between the OSC 0 introducer and the BEL.
title_of() {
  python3 -c '
import json,sys
raw = sys.stdin.read().strip()
if not raw:
    print("<no output>"); raise SystemExit
d = json.loads(raw)
if list(d) != ["terminalSequence"]:
    print("<unexpected keys: %s>" % list(d)); raise SystemExit
s = d["terminalSequence"]
if not (s.startswith("\x1b]0;") and s.endswith("\x07")):
    print("<unexpected framing: %r>" % s); raise SystemExit
print(s[4:-1])
'
}

run_hook() { printf '{"cwd":"%s"}' "$1" | bash "$UNDER_TEST" 2>/dev/null; }

# ── a repo on a plainly-named branch ────────────────────────────────
# HERMETIC, and loud when it cannot be built. The fixture used to inherit the
# contributor's global git config: this repo installs a git GPG shim, so an
# ordinary `commit.gpgsign = true` with an unavailable key made the empty
# commit fail, HEAD stay unborn, and the detached-HEAD case then report a
# FAILURE AGAINST CORRECT CODE. A fixture that half-builds and keeps going
# blames the thing under test for its own breakage.
setup() { "$@" || { echo "test: fixture setup failed: $*" >&2; exit 1; }; }

repo="$SANDBOX/my-clone"
mkdir -p "$repo"
setup git -C "$repo" -c init.defaultBranch=main init -q
setup git -C "$repo" config user.email t@example.invalid
setup git -C "$repo" config user.name test
setup git -C "$repo" config commit.gpgsign false
setup git -C "$repo" config gpg.format openpgp
setup git -C "$repo" commit -q --allow-empty -m "first"
setup git -C "$repo" branch -M main

assert_eq "the title is <clone>/<branch>" "my-clone/main" "$(run_hook "$repo" | title_of)"

# ── the repo's own branch naming, whose prefix must be stripped ─────
# Branches here are <host>/<clone>/<type>/<desc>; used whole, the clone
# appears twice and the task falls off the end of a narrow tab.
host="$(hostname -s 2>/dev/null || hostname 2>/dev/null)"
setup git -C "$repo" checkout -q -b "$host/my-clone/feat/some-task"
assert_eq "this clone's own branch prefix is stripped" \
  "my-clone/feat/some-task" "$(run_hook "$repo" | title_of)"

# A prefix belonging to a DIFFERENT clone is not this clone's, so it stays:
# stripping it would claim work that is not ours.
setup git -C "$repo" checkout -q -b "$host/other-clone/feat/theirs"
assert_eq "another clone's prefix is left alone" \
  "my-clone/$host/other-clone/feat/theirs" "$(run_hook "$repo" | title_of)"

# ── detached HEAD: every subagent worktree runs in one ──────────────
setup git -C "$repo" checkout -q --detach
sha="$(git -C "$repo" rev-parse --short HEAD)"
assert_eq "detached HEAD shows the short SHA, not an empty half-title" \
  "my-clone/$sha" "$(run_hook "$repo" | title_of)"

# ── a linked worktree reports the SESSION, not the worktree ─────────
#
# Every subagent dispatch runs in a linked worktree on its own generated
# branch. Resolving "here" titled the tab agent-<id>/worktree-agent-<id>,
# which names neither the clone nor the task, and it persisted after the
# agent finished until the session ran a Bash call of its own.
setup git -C "$repo" checkout -q main
linked="$SANDBOX/linked/agent-probe"
setup git -C "$repo" worktree add -q -b worktree-agent-probe "$linked" main
assert_eq "a linked worktree reports the main clone and ITS branch" \
  "my-clone/main" "$(run_hook "$linked" | title_of)"
git -C "$repo" worktree remove --force "$linked" >/dev/null 2>&1 || true

# ── the never-fail-loudly contract ──────────────────────────────────
# Outside a repo there is no title to set, and saying so with an empty body
# is how a hook declines: any stdout here would be parsed as a directive.
out="$(printf '{"cwd":"/"}' | bash "$UNDER_TEST" 2>/dev/null)"; rc=$?
if [[ -z "$out" && "$rc" -eq 0 ]]; then
  pass "outside a git repo it emits nothing and exits 0"
else
  fail "outside a git repo it emits nothing and exits 0" "rc=$rc out=[$out]"
fi

# A valid payload must ALSO exit 0. Without this the malformed cases below
# only pin the short-circuit at the top of the script, not the path that
# actually emits -- they reach the emit only because the suite happens to run
# from inside a repo, so `dir` falls back to $PWD.
out="$(run_hook "$repo")"; rc=$?
if [[ "$rc" -eq 0 && -n "$out" ]]; then
  pass "a valid payload emits a sequence and still exits 0"
else
  fail "a valid payload emits a sequence and still exits 0" "rc=$rc out=[$out]"
fi

for payload in '{}' 'not json at all' ''; do
  out="$(printf '%s' "$payload" | bash "$UNDER_TEST" 2>/dev/null)"; rc=$?
  if [[ "$rc" -eq 0 ]]; then
    pass "a malformed payload (${payload:-empty}) still exits 0"
  else
    fail "a malformed payload (${payload:-empty}) still exits 0" "rc=$rc"
  fi
done

# ── the source carries no raw control bytes ─────────────────────────
# The escapes are written as jq's backslash-u001b / backslash-u0007 text. A literal ESC in a
# tracked file survives git but not every editor, diff view or copy-paste,
# and it is invisible in review.
if python3 -c '
import sys
s = open(sys.argv[1], encoding="utf-8").read()
bad = [c for c in s if ord(c) < 32 and c not in "\n\t"]
sys.exit(1 if bad else 0)
' "$UNDER_TEST"; then
  pass "the script source is free of raw control bytes"
else
  fail "the script source is free of raw control bytes"
fi

echo
if [[ "$failures" -eq 0 ]]; then
  echo "all assertions passed"
  exit 0
fi
echo "$failures assertion(s) failed" >&2
exit 1
