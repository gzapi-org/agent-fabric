#!/usr/bin/env bash
#
# policies/check_charter_authority.sh
#
# A role's DEFINITION is architect-cto's to change: `identities/roles/*/
# charter.md`, the catalogue `identities/roles/catalog.json`, and the
# per-project binding rules `projects/*/taxonomy.json`. This fails when one
# of those changes on a branch that is not an architect-cto branch.
#
# AUTHORITY BELONGS TO THE ROLE, NOT TO THE ACCOUNT. The branch's second
# segment names the agent (Linux login) that opened it; the check asks
# whether that agent is an architect-cto INSTANCE by the provisioning
# convention that accounts are named for the role they were stood up as.
# An account currently HOLDING a role does not thereby own the role's
# definition — that is exactly the widening this tripwire exists to catch.
#
# WHY THIS EXISTS. Every distilled slice is generated -- the
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
# guards: identities/**
# guards: projects/*/taxonomy.json
# guards: policies/**
#
# Exit codes:
#   0  no protected file changed, or the branch is architect-cto's, or the
#      head branch is not knowable in this context
#   1  a protected file changed on another role's branch
#   0  also when no base ref is resolvable -- an environment that cannot
#      show a diff is not a violation, and failing there would block every
#      PR rather than the one changing a charter
#   2  invocation problem (cannot reach the repo root)

set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "cannot cd to repo root" >&2; exit 2; }

# RESOLVING THE BASE IS THE HARD PART IN CI, not locally. `actions/checkout`
# defaults to depth 1 and, on a pull_request, checks out the MERGE ref -- so
# there is no `origin/main` and no `HEAD^1` to diff against. The first
# version assumed `origin/main` existed and exited 2 when it did not, which
# failed the build for an environment limitation rather than a violation.
resolve_base() {
    local candidate
    for candidate in "${AGENT_FABRIC_CHARTER_BASE:-${GZAPP_CHARTER_BASE:-}}" \
                     "origin/${GITHUB_BASE_REF:-}" "${GITHUB_BASE_REF:-}" \
                     origin/main main; do
        [[ -n "$candidate" && "$candidate" != "origin/" ]] || continue
        if git rev-parse --verify -q "$candidate" >/dev/null 2>&1; then
            printf '%s' "$candidate"; return 0
        fi
    done
    # Nothing local matched: fetch just the base tip. One shallow fetch, and
    # only on a pull_request where GITHUB_BASE_REF names the branch.
    if [[ -n "${GITHUB_BASE_REF:-}" ]] \
       && git fetch -q --depth=1 origin "$GITHUB_BASE_REF" 2>/dev/null; then
        printf 'FETCH_HEAD'; return 0
    fi
    return 1
}

BASE="$(resolve_base)" || {
    # NOT a build failure. This guard is a tripwire; an environment that
    # cannot show it a diff is not a violation, and failing here would
    # block every PR rather than the one changing a charter.
    echo "check_charter_authority: NOT ENFORCED — no base ref to diff"
    echo "against (shallow checkout with no GITHUB_BASE_REF). A charter"
    echo "change would pass unexamined here."
    exit 0
}

# GITHUB_HEAD_REF is set on pull_request and empty elsewhere; fall back to
# the local branch so this is runnable by hand before pushing.
BRANCH="${AGENT_FABRIC_CHARTER_BRANCH:-${GZAPP_CHARTER_BRANCH:-${GITHUB_HEAD_REF:-}}}"
[[ -n "$BRANCH" ]] || BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"

mapfile -t changed < <(git diff --name-only "$BASE"...HEAD -- \
    'identities/roles/*/charter.md' 'identities/roles/catalog.json' \
    'projects/*/taxonomy.json' 2>/dev/null)

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

# `<host>/<agent>/<type>/<desc>`: the second segment names the agent (the
# Linux login) that opened the branch, which is the only signal available.
agent="$(cut -d/ -f2 <<<"$BRANCH")"
if [[ "$BRANCH" != */*/* || -z "$agent" ]]; then
    echo "check_charter_authority: role definition(s) changed, but the head"
    echo "branch is not knowable here (${BRANCH:-none}) — the pull_request"
    echo "run is where this is enforced."
    printf '  %s\n' "${changed[@]}"
    exit 0
fi

if [[ "$agent" == architect-cto* ]]; then
    echo "check_charter_authority: OK — ${#changed[@]} role definition(s)" \
         "changed on an architect-cto branch."
    exit 0
fi

echo "FAIL: a role's DEFINITION changed on a branch owned by agent '$agent'." >&2
printf '       %s\n' "${changed[@]}" >&2
cat >&2 <<'MSG'

`identities/roles/*/charter.md`, the role catalogue and a project's
taxonomy say what a role is and is not, and where it applies. They are
architect-cto's to change -- a role does not redefine
itself, for the same reason gzcoord-coordinator owns the protocol spec it
constrains others with.

Propose it instead: open a PR touching only the charter, say what the role
is being asked to take on or give up, and leave it for architect-cto. Do
not self-approve on the grounds that you are the only session that
understands the surface; that is the argument this exists to refuse.
MSG
exit 1
