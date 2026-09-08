#!/usr/bin/env bash
#
# tools/checks/test_check_charter_authority.sh
#
# Self-test for check_charter_authority.sh.
#
# Built on a throwaway git repository, because the guard's whole input is
# a COMMITTED diff against a base ref. The first version of this test
# modified the working tree and asserted the guard fired; it did not, and
# could not — `git diff BASE...HEAD` never sees an uncommitted change. A
# positive control is the only reason that was caught.
#
# Exit codes:
#   0  all assertions passed
#   1  one or more assertions failed

set -uo pipefail

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" && pwd )"
UNDER_TEST="$SCRIPT_DIR/check_charter_authority.sh"
[[ -f "$UNDER_TEST" ]] || { echo "test: not found: $UNDER_TEST" >&2; exit 1; }

failures=0
SANDBOX=""
cleanup() { [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1" >&2; printf '%s\n' "${2:-}" | sed 's/^/      /' >&2; failures=$((failures+1)); }

GUARD_MARKER="$(mktemp)"
command_not_found_handle() {
  echo "UNDEFINED COMMAND: $1" >> "$GUARD_MARKER"; return 127
}

# A repo with a base commit, the guard in place, and a charter to touch.
new_repo() {
  [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/tools/checks" "$SANDBOX/.roles/flutter-dev" "$SANDBOX/.roles/architect-cto"
  cp "$UNDER_TEST" "$SANDBOX/tools/checks/"
  printf 'scope\n' > "$SANDBOX/.roles/flutter-dev/charter.md"
  printf '{"roles":{}}\n' > "$SANDBOX/.roles/taxonomy.json"
  printf 'other\n' > "$SANDBOX/.roles/flutter-dev/workflow.md"
  git -C "$SANDBOX" init -q
  git -C "$SANDBOX" config user.email t@e; git -C "$SANDBOX" config user.name t
  git -C "$SANDBOX" add -A; git -C "$SANDBOX" commit -qm base
  git -C "$SANDBOX" branch -q base-ref
}

commit_change() {  # $1 = path, relative
  echo "changed" >> "$SANDBOX/$1"
  git -C "$SANDBOX" add -A
  git -C "$SANDBOX" commit -qm "change $1"
}

check() {  # $1 = branch label; echoes output, returns the guard's code
  ( cd "$SANDBOX" && GZAPP_CHARTER_BASE=base-ref GZAPP_CHARTER_BRANCH="$1" \
      bash tools/checks/check_charter_authority.sh 2>&1 )
}
rc_of() { ( cd "$SANDBOX" && GZAPP_CHARTER_BASE=base-ref GZAPP_CHARTER_BRANCH="$1" \
      bash tools/checks/check_charter_authority.sh >/dev/null 2>&1 ); echo $?; }

echo "a charter change by another role"
new_repo; commit_change ".roles/flutter-dev/charter.md"
rc="$(rc_of develop-qzapp/flutter-dev-01/feat/thing)"
[[ "$rc" == 1 ]] && pass "refused (exit 1)" || fail "refused (exit 1)" "exit $rc"
out="$(check develop-qzapp/flutter-dev-01/feat/thing)"
[[ "$out" == *"flutter-dev-01"* ]] && pass "names the branch owner" || fail "names the branch owner" "$out"
[[ "$out" == *"charter.md"* ]] && pass "names the file" || fail "names the file" "$out"
[[ "$out" == *"Propose it instead"* ]] && pass "says what to do instead" || fail "says what to do instead" "$out"

echo "the same change by architect-cto"
rc="$(rc_of develop-qzapp/architect-cto-01/feat/x)"
[[ "$rc" == 0 ]] && pass "allowed (exit 0)" || fail "allowed (exit 0)" "exit $rc"

echo "taxonomy.json is protected too"
new_repo; commit_change ".roles/taxonomy.json"
rc="$(rc_of develop-qzapp/web-dev-01/feat/x)"
[[ "$rc" == 1 ]] && pass "refused" || fail "refused" "exit $rc"

echo "an ordinary slice is NOT protected"
# The control that keeps this from being a blanket ban on touching .roles/:
# every other file there is generated, and the drain rewrites them.
new_repo; commit_change ".roles/flutter-dev/workflow.md"
rc="$(rc_of develop-qzapp/flutter-dev-01/feat/x)"
[[ "$rc" == 0 ]] && pass "a distilled slice may change on any branch" \
    || fail "a distilled slice may change on any branch" "exit $rc"

echo "nothing changed at all"
new_repo
rc="$(rc_of develop-qzapp/flutter-dev-01/feat/x)"
[[ "$rc" == 0 ]] && pass "passes" || fail "passes" "exit $rc"

echo "the merge queue's synthetic ref"
# It HAS three segments, so segment-counting reads its second as the base
# branch and fails every charter change at the gate. Matched by name.
new_repo; commit_change ".roles/flutter-dev/charter.md"
rc="$(rc_of gh-readonly-queue/main/pr-999-abc)"
[[ "$rc" == 0 ]] && pass "not enforced in the queue" || fail "not enforced in the queue" "exit $rc"
out="$(check gh-readonly-queue/main/pr-999-abc)"
[[ "$out" == *"the pull_request run"* ]] \
    && pass "says where it IS enforced" || fail "says where it IS enforced" "$out"

echo "a detached HEAD"
rc="$(rc_of HEAD)"
[[ "$rc" == 0 ]] && pass "reports rather than guessing" || fail "reports rather than guessing" "exit $rc"

if [[ -s "$GUARD_MARKER" ]]; then
  echo >&2; echo "UNDEFINED COMMANDS were called:" >&2
  sort -u "$GUARD_MARKER" | sed 's/^/  /' >&2; failures=$((failures+1))
fi
rm -f "$GUARD_MARKER"

echo
if [[ "$failures" -eq 0 ]]; then echo "all assertions passed"; exit 0; fi
echo "$failures assertion(s) failed" >&2; exit 1
