#!/usr/bin/env bash
# policies/githooks/guarded-change.sh — does the commit being made carry a
# change of ITS OWN to what the fabric-coordinator role guards? Sourced by
# pre-commit and commit-msg; sets `guarded_what` (a label) and `guarded`
# (the staged paths under guard, empty when nothing is).
#
# In agent-fabric itself every path is guarded; in a managed project only
# .agent-fabric/. A MERGE is the exception that is not one: a merge commit
# whose guarded subtree equals one of its parents' brings that parent's
# already-landed commits into the branch and changes nothing itself —
# CI's tripwire (policies/check_agent_fabric_dir_authority.sh) skips
# merge commits for exactly that reason, and the fence at the keyboard
# must agree, or every fold of main after a drain needs --no-verify,
# which teaches sessions the wrong reflex (devex-tooling, 2026-09-14).
# A merge that ALSO edits a slice by hand differs from both parents and
# is refused like any other change.
guarded_change() {
    local fabric_root="$1" toplevel prefix staged_tree
    toplevel="$(git rev-parse --show-toplevel 2>/dev/null)"
    if [[ "$(readlink -f "$toplevel")" == "$(readlink -f "$fabric_root")" ]]; then
        guarded_what="agent-fabric itself"; prefix=""
    else
        guarded_what=".agent-fabric/"; prefix=".agent-fabric/"
    fi
    if [[ -n "$prefix" ]]; then
        mapfile -t guarded < <(git diff --cached --name-only --diff-filter=ACDMRT -- "$prefix" 2>/dev/null)
    else
        mapfile -t guarded < <(git diff --cached --name-only --diff-filter=ACDMRT 2>/dev/null)
    fi
    local merge_head; merge_head="$(git rev-parse -q --verify MERGE_HEAD 2>/dev/null)" || merge_head=""
    if (( ${#guarded[@]} == 0 )); then
        # Nothing staged against HEAD: an --amend (the index equals the
        # commit being rewritten) or an empty commit. In agent-fabric
        # itself every commit is the coordinator's, an amend included —
        # it rewrites a guarded commit and must carry the trailer.
        [[ -z "$prefix" && -z "$merge_head" ]] && guarded=("(amend or empty commit: the whole repository)")
        return 0
    fi
    # A merge in progress: compare the staged guarded subtree with each parent's.
    [[ -n "$merge_head" ]] || return 0
    staged_tree="$(git write-tree 2>/dev/null)" || return 0
    local staged_sub head_sub merge_sub
    staged_sub="$(git rev-parse -q --verify "$staged_tree:${prefix%/}" 2>/dev/null || echo none)"
    head_sub="$(git rev-parse -q --verify "HEAD:${prefix%/}" 2>/dev/null || echo none)"
    merge_sub="$(git rev-parse -q --verify "$merge_head:${prefix%/}" 2>/dev/null || echo none)"
    if [[ "$staged_sub" == "$head_sub" || "$staged_sub" == "$merge_sub" ]]; then
        guarded=()   # the merge carries a parent's guarded tree unchanged: no change of its own
    fi
}
