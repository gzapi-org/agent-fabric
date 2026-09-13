#!/usr/bin/env bash
#
# policies/check_agent_fabric_dir_authority.sh
#
# `.agent-fabric/` in a repository is fabric-coordinator's to write. It
# holds the project's distilled knowledge (`memory/<role>/`, written by the
# drain) and the file naming who may write it (`authority.json`). Every
# other role READS it: a `backend-dev` session that edits a slice by hand
# is asserting something about the system with no evidence behind it and
# outside the role that owns the corpus. This fails when anything under
# `.agent-fabric/` changes on a branch that is not a fabric-coordinator
# branch.
#
# RUNS IN ANY REPOSITORY. In agent-fabric it guards the control plane's own
# `.agent-fabric/`; a managed project runs it from the sibling checkout
# (`$CLAUDE_PROJECT_DIR/../agent-fabric/policies/…`) or a copy in its CI.
# Holders come from, in order, read from the BASE side of the diff so a
# branch cannot appoint itself:
#   1. `.agent-fabric/authority.json` in this repository
#   2. `policies/authority.json` in this repository (agent-fabric itself)
#   3. the sibling agent-fabric checkout's policies/authority.json
#      ($AGENT_FABRIC_ROOT, or ../agent-fabric beside the repo) — a
#      provisioned host, where no copy inside the project is needed
# and, always, an account NAMED for the role (fabric-coordinator,
# fabric-coordinator-02, …) is recognised without an entry.
#
# AUTHORITY BELONGS TO THE ROLE, NOT TO THE ACCOUNT, and this is a
# TRIPWIRE, not a fence — see check_charter_authority.sh, whose reasoning
# and limits this shares: the branch name is self-declared, every session
# pushes as one GitHub account, and a session that means to route around
# it can. It stops the accident and makes a deliberate change visible.
#
# guards: .agent-fabric/**
#
# Exit codes:
#   0  nothing under .agent-fabric/ changed, or the branch is
#      fabric-coordinator's, or the head branch is not knowable here
#   1  .agent-fabric/ changed on another role's branch
#   0  also when no base ref is resolvable (not a violation)
#   2  invocation problem (cannot reach the repo root)
set -uo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "check_agent_fabric_dir_authority: not inside a git repository" >&2; exit 2; }

resolve_base() {
    local candidate
    for candidate in "${AGENT_FABRIC_CHARTER_BASE:-}" \
                     "origin/${GITHUB_BASE_REF:-}" "${GITHUB_BASE_REF:-}" \
                     origin/main main; do
        [[ -n "$candidate" && "$candidate" != "origin/" ]] || continue
        if git rev-parse --verify -q "$candidate" >/dev/null 2>&1; then
            printf '%s' "$candidate"; return 0
        fi
    done
    if [[ -n "${GITHUB_BASE_REF:-}" ]] \
       && git fetch -q --depth=1 origin "$GITHUB_BASE_REF" 2>/dev/null; then
        printf 'FETCH_HEAD'; return 0
    fi
    return 1
}

BASE="$(resolve_base)" || {
    echo "check_agent_fabric_dir_authority: NOT ENFORCED — no base ref to diff"
    echo "against (shallow checkout with no GITHUB_BASE_REF). A change under"
    echo ".agent-fabric/ would pass unexamined here."
    exit 0
}

BRANCH="${AGENT_FABRIC_CHARTER_BRANCH:-${GITHUB_HEAD_REF:-}}"
[[ -n "$BRANCH" ]] || BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"

mapfile -t changed < <(git diff --name-only "$BASE"...HEAD -- '.agent-fabric/**' 2>/dev/null)

if (( ${#changed[@]} == 0 )); then
    echo "check_agent_fabric_dir_authority: OK — nothing under .agent-fabric/ changed."
    exit 0
fi

case "$BRANCH" in
    gh-readonly-queue/*|HEAD|"")
        echo "check_agent_fabric_dir_authority: .agent-fabric/ changed; not"
        echo "enforced on '${BRANCH:-detached HEAD}' — the pull_request run"
        echo "is where this is enforced, and it gates entry to the queue."
        printf '  %s\n' "${changed[@]}"
        exit 0 ;;
esac

agent="$(cut -d/ -f2 <<<"$BRANCH")"
if [[ "$BRANCH" != */*/* || -z "$agent" ]]; then
    echo "check_agent_fabric_dir_authority: .agent-fabric/ changed, but the head"
    echo "branch is not knowable here (${BRANCH:-none}) — the pull_request"
    echo "run is where this is enforced."
    printf '  %s\n' "${changed[@]}"
    exit 0
fi

# The holders file, first found wins; the committed base side for anything
# in this repository, the working tree for the sibling checkout.
read_holders() {  # stdin: authority.json -> "role holder holder…"
    python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
r=(d.get("role_definitions") or {})
print(r.get("role") or "fabric-coordinator", *(r.get("holders") or []))' 2>/dev/null
}
holders_line=""
source_label=""
for rel in .agent-fabric/authority.json policies/authority.json; do
    if git cat-file -e "$BASE:$rel" 2>/dev/null; then
        holders_line="$(git show "$BASE:$rel" | read_holders)"; source_label="$rel at $BASE"; break
    fi
done
if [[ -z "$holders_line" ]]; then
    sibling="${AGENT_FABRIC_ROOT:-$(pwd)/../agent-fabric}/policies/authority.json"
    if [[ -f "$sibling" ]]; then
        holders_line="$(read_holders < "$sibling")"; source_label="$sibling"
    fi
fi
[[ -n "$holders_line" ]] || { holders_line="fabric-coordinator"; source_label="no holders file; name convention only"; }
owner_role="${holders_line%% *}"
holders="${holders_line#"$owner_role"}"

is_holder=0
for h in $holders; do [[ "$agent" == "$h" ]] && is_holder=1; done
[[ "$agent" == "$owner_role"* ]] && is_holder=1
if (( is_holder )); then
    echo "check_agent_fabric_dir_authority: OK — ${#changed[@]} path(s) under .agent-fabric/" \
         "changed on a $owner_role branch ($agent; holders from $source_label)."
    exit 0
fi

echo "FAIL: .agent-fabric/ changed on a branch owned by agent '$agent'." >&2
printf '       %s\n' "${changed[@]}" >&2
cat >&2 <<MSG

.agent-fabric/ is the project's distilled knowledge and the file naming
who may write it. It is $owner_role's: the drain writes it
(agent-fabric memory/README.md), every other role reads it. Holders were
read from $source_label.

If this is a drain, run it as a $owner_role holder. If a slice is
wrong, say so to $owner_role — a correction enters the corpus through a
drain with provenance, never as a hand edit on another role's branch.
See agent-fabric policies/AUTHORITY.md.
MSG
exit 1
