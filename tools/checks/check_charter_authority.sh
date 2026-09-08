#!/usr/bin/env bash
#
# tools/checks/check_charter_authority.sh
#
# A role's DEFINITION is architect-cto's to change: `.roles/*/charter.md`
# and the `roles` block of `.roles/taxonomy.json`. This fails when one of
# those changes on a branch that is not an architect-cto branch.
#
# WHY THIS EXISTS. Every other file under `.roles/` is generated -- the
# assembler writes it and lint.py rejects a hand-edit -- so a role's scope
# cannot drift by accident. `charter` and `recall` are the two classes
# lint.py exempts from `derived_from`, precisely because they are authored
# rather than distilled. That exemption is what makes charter.md the one
# place a session can quietly widen its own remit, and it lints clean:
# lint checks PROVENANCE, and this is a question of AUTHORITY.
#
# WHAT THIS CANNOT DO, stated plainly so nobody mistakes it for a fence.
# Every session pushes as the same GitHub account, so there is no identity
# to check -- CODEOWNERS cannot tell one session from another here. All
# that is available is the branch name, which is self-declared. This is a
# TRIPWIRE: it stops the accident and the absent-minded edit, and it makes
# a deliberate change visible in review. A session that means to route
# around it can, by naming its branch differently, and nothing available
# in this repository would catch that.
#
# It also only enforces where a head branch is knowable. On a `merge_group`
# run the ref is the queue's synthetic branch, so the check reports and
# passes -- the `pull_request` run is where it bites, and that run is
# required before anything is queued.
#
# guards: .roles/**
# guards: tools/checks/**
#
# Exit codes:
#   0  no protected file changed, or the branch is architect-cto's, or the
#      head branch is not knowable in this context
#   1  a protected file changed on another role's branch
#   2  invocation problem

set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || { echo "cannot cd to repo root" >&2; exit 2; }

BASE="${GZAPP_CHARTER_BASE:-origin/main}"
git rev-parse --verify -q "$BASE" >/dev/null || BASE="main"
git rev-parse --verify -q "$BASE" >/dev/null || {
    echo "check_charter_authority: cannot resolve a base ref to diff against" >&2
    exit 2
}

# GITHUB_HEAD_REF is set on pull_request and empty elsewhere; fall back to
# the local branch so this is runnable by hand before pushing.
BRANCH="${GZAPP_CHARTER_BRANCH:-${GITHUB_HEAD_REF:-}}"
[[ -n "$BRANCH" ]] || BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"

mapfile -t changed < <(git diff --name-only "$BASE"...HEAD -- \
    '.roles/*/charter.md' '.roles/taxonomy.json' 2>/dev/null)

if (( ${#changed[@]} == 0 )); then
    echo "check_charter_authority: OK — no role definition changed."
    exit 0
fi

# The merge queue's synthetic ref is `gh-readonly-queue/<base>/pr-N-<sha>`,
# which HAS three segments -- so segment-counting alone reads its second
# one as the base branch and fails every charter change at the gate.
# Matched by name, explicitly, before anything is parsed out of it.
case "$BRANCH" in
    gh-readonly-queue/*|HEAD|"")
        echo "check_charter_authority: role definition(s) changed; not"
        echo "enforced on '${BRANCH:-detached HEAD}' — the pull_request run"
        echo "is where this is enforced, and it gates entry to the queue."
        printf '  %s\n' "${changed[@]}"
        exit 0 ;;
esac

# `<host>/<clone>/<type>/<desc>`: the clone segment carries the account,
# which is the only signal available.
clone="$(cut -d/ -f2 <<<"$BRANCH")"
if [[ "$BRANCH" != */*/* || -z "$clone" ]]; then
    echo "check_charter_authority: role definition(s) changed, but the head"
    echo "branch is not knowable here (${BRANCH:-none}) — the pull_request"
    echo "run is where this is enforced."
    printf '  %s\n' "${changed[@]}"
    exit 0
fi

if [[ "$clone" == architect-cto* ]]; then
    echo "check_charter_authority: OK — ${#changed[@]} role definition(s)" \
         "changed on an architect-cto branch."
    exit 0
fi

echo "FAIL: a role's DEFINITION changed on a branch owned by '$clone'." >&2
printf '       %s\n' "${changed[@]}" >&2
cat >&2 <<'MSG'

`.roles/*/charter.md` and taxonomy.json's roles block say what a role is
and is not. They are architect-cto's to change -- a role does not redefine
itself, for the same reason gzcoord-coordinator owns the protocol spec it
constrains others with.

Propose it instead: open a PR touching only the charter, say what the role
is being asked to take on or give up, and leave it for architect-cto. Do
not self-approve on the grounds that you are the only session that
understands the surface; that is the argument this exists to refuse.
MSG
exit 1
