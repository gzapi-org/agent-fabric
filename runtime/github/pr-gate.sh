#!/usr/bin/env bash
# runtime/github/pr-gate.sh (lifted from the first managed project's tools/gh/ on 2026-09-19 — the commit names it; general to every managed project, whose own tools/gh/ copy is a forwarder through projects/<id>/integration/gh/)
#
# >>> help
# My open pull requests: how many commits, and what stands between each
# and main.
#
# THE QUESTION IT ANSWERS. "Show my open PRs, how many commits, is it
# mergeable?" needed four tools and a head count by hand: pr-sessions.sh
# for the list, git rev-list for the commits, gh pr checks for the
# checks, pr-review-status.sh for the review, and the owner's arming rule
# (2026-09-18) applied on top — 8-16 WORK commits arm at the gate, fewer
# ask the owner, more than 16 advised to split. One line per PR now carries all of
# it, and a verdict.
#
# WHAT A ROW SAYS
#   #N  <owner> [(me)]  commits=T (W work, F fix, M merge)  checks=<green|red:<names>|pending:<k>>
#       review=<head reviewed|NOT on head|none>  threads=<u>  armed=<yes|no>
#       queue=<pos>  verdict
#
#   owner  the session that opened it — <host>/<login> from the branch
#          prefix, never the PR author (every session pushes as one
#          GitHub user); "(me)" marks this session's. With --all, the
#          repository's open PRs by owner: whose gate each one is at.
#   commits all commits over the base, then the split: WORK ones are neither merges nor review fixes
#          (a fix is a commit carrying an "Answers: <labels>" trailer —
#          the primary signal — or, without one, whose subject opens
#          with "review" or names a review AND says it answers one —
#          "review F4: …", "…: address the blind review", "re-review
#          nits: …"; a fix(scope): bug fix is WORK — the count rule
#          excludes fixes; the subjects counted as fix are printed so
#          the split can be checked; commit-class.sh is the classifier)
#   checks green when every reported check passed; red names the failed
#          ones; pending counts the ones still running; none-yet when no
#          check has reported (seconds after a push)
#   review whether a review — an independent one, or the review class's blind review — covers the CURRENT head
#          (pr-review-status.sh's reading)
#   verdict one of:
#     MERGEABLE — arm (8-16 work commits, gate met: post the basis, arm)
#     MERGEABLE — ask the owner (under 8 work commits, gate met)
#     MERGEABLE — N work commits, over 16: smaller batches next time (advice, never a block)
#     MERGEABLE — commits unknown (the base is not fetched; count by hand)
#     ARMED and clear / ARMED but held: <what> / QUEUED — nothing to do
#     BLOCKED: <what> — a draft, red checks, pending checks, no check yet,
#     no review of the head, unresolved threads, a conflict
#   A pull request given by number that is not OPEN is said and skipped.
#
# Usage:
#   tools/gh/pr-gate.sh              # every open PR of this session (branch prefix <host>/<login>/)
#   tools/gh/pr-gate.sh 861 877      # these PRs, whoever opened them
#   tools/gh/pr-gate.sh --all        # every open PR in the repository
#   tools/gh/pr-gate.sh --json       # rows as data
#
# Exit codes:
#   0  listed
#   2  gh, git or the repository could not be read
#
# Environment (the self-test):
#   AGENT_FABRIC_PR_REVIEW_STATUS   path of pr-review-status.sh (default beside this script)
#   AGENT_FABRIC_PR_SESSION         the <host>/<login> prefix (default: fabric-whoami)
# <<< help

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=commit-class.sh
. "$here/commit-class.sh"
REVIEW_STATUS="${AGENT_FABRIC_PR_REVIEW_STATUS:-$here/pr-review-status.sh}"
JSON=0; ALL=0; NUMS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) JSON=1; shift ;;
        --all) ALL=1; shift ;;
        -h|--help) sed -n '/^# >>> help/,/^# <<< help/p' "$0" | sed '1d;$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) if [[ "$1" =~ ^[0-9]+$ ]]; then NUMS+=("$1"); shift; else echo "pr-gate: unknown option '$1' (try --help)" >&2; exit 2; fi ;;
    esac
done
for t in gh jq git; do command -v "$t" >/dev/null 2>&1 || { echo "pr-gate: $t is required" >&2; exit 2; }; done

REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || REPO=""
[[ -n "$REPO" ]] || { echo "pr-gate: cannot read the repository (gh repo view failed)" >&2; exit 2; }
OWNER="${REPO%%/*}"; NAME="${REPO##*/}"

session="${AGENT_FABRIC_PR_SESSION:-}"
if [[ -z "$session" ]]; then
    fabric="${AGENT_FABRIC_ROOT:-$here/../..}"   # this script lives in the fabric now
    if [[ -x "$fabric/bin/fabric-whoami" ]]; then
        session="$("$fabric/bin/fabric-whoami" --json 2>/dev/null | jq -r '"\(.host)/\(.agent)"' 2>/dev/null)"
    fi
    [[ -n "$session" && "$session" != "null/null" ]] || session="$(hostname -s 2>/dev/null)/$(id -un)"
fi

# The PRs to read.
if (( ${#NUMS[@]} > 0 )); then
    list="[]"
    for n in "${NUMS[@]}"; do
        one="$(gh pr view "$n" --repo "$REPO" --json number,title,headRefName,headRefOid,baseRefName,state,isDraft,body 2>/dev/null)" || { echo "pr-gate: #$n is not a pull request of $REPO (or gh could not read it)" >&2; continue; }
        st="$(jq -r '.state' <<<"$one")"
        if [[ "$st" != "OPEN" ]]; then echo "pr-gate: #$n is $st — not at any gate; skipped." >&2; continue; fi
        list="$(jq --argjson o "$one" '. + [$o]' <<<"$list")"
    done
else
    list="$(gh pr list --repo "$REPO" --state open --limit 500 --json number,title,headRefName,headRefOid,baseRefName,state,isDraft,body 2>/dev/null)" || { echo "pr-gate: could not list pull requests" >&2; exit 2; }
    [[ "$(jq 'length' <<<"$list")" -ge 500 ]] && echo "pr-gate: 500 open pull requests read — the list is capped there." >&2
    if (( ALL == 0 )); then
        list="$(jq --arg p "$session/" '[.[] | select(.headRefName | startswith($p))]' <<<"$list")"
    fi
fi
count="$(jq 'length' <<<"$list")"
if [[ "$count" -eq 0 ]]; then
    if [[ $JSON -eq 1 ]]; then echo "[]"; else
        if (( ${#NUMS[@]} > 0 )); then echo "pr-gate: none of the numbers given is a pull request of $REPO."; elif (( ALL == 1 )); then echo "pr-gate: no open pull request on $REPO."; else echo "pr-gate: no open pull request from $session on $REPO (branch prefix $session/)."; fi
    fi
    exit 0
fi

# A failed fetch is said, not swallowed: the counts below are read from
# the local clone, and a stale or missing origin makes them wrong in
# both directions (review F2 on #886).
fetched=1
git fetch -q origin 2>/dev/null || { fetched=0; echo "pr-gate: git fetch origin failed — the base is stale, so no commit count is trusted (commits unknown)" >&2; }
rows="[]"
while IFS=$'\t' read -r num title head base hbranch draft; do
    [[ -n "$num" ]] || continue
    # ── commits over the base: work / review-fix / merge ──
    # The classifier is commit-class.sh (shared with pr-compliance.sh,
    # so the band measured after the fact is the band applied before).
    # The subjects counted as fix are printed, so the split can be
    # checked; the count rule is applied on it and a misread moves the
    # band.
    work=0; fix=0; merges=0; commits_known=1; fix_subjects="[]"
    if (( fetched )) && git cat-file -e "$head^{commit}" 2>/dev/null && git rev-parse --verify -q "origin/$base^{commit}" >/dev/null 2>&1; then
        while IFS=$'\t' read -r sha parents subject answers; do
            [[ -n "$sha" ]] || continue
            case "$(commit_class "$parents" "$subject" "$answers")" in
                merge) merges=$((merges + 1)) ;;
                fix)   fix=$((fix + 1)); fix_subjects="$(jq --arg s "$subject" '. + [$s]' <<<"$fix_subjects")" ;;
                *)     work=$((work + 1)) ;;
            esac
        done < <(git log --format='%H%x09%P%x09%s%x09%(trailers:key=Answers,valueonly,unfold,separator=%x20)' "origin/$base..$head" 2>/dev/null)
    else
        commits_known=0
    fi
    # ── checks, threads, arming, queue, merge state ──
    g="$(gh api graphql -f query="{repository(owner:\"$OWNER\",name:\"$NAME\"){pullRequest(number:$num){mergeStateStatus mergeable reviewThreads(first:100){nodes{isResolved}} mergeQueueEntry{position state} autoMergeRequest{enabledAt} statusCheckRollup{contexts(first:100){nodes{... on CheckRun{name status conclusion} ... on StatusContext{context state}}}}}}}" 2>/dev/null)" || g=""
    if [[ -z "$g" ]] || ! jq -e '.data.repository.pullRequest' <<<"$g" >/dev/null 2>&1; then
        echo "pr-gate: could not read pull request #$num from GitHub (the graphql read failed); nothing is invented — run again." >&2
        exit 2
    fi
    unresolved="$(jq -r '[.data.repository.pullRequest.reviewThreads.nodes[]? | select(.isResolved|not)] | length' <<<"$g" 2>/dev/null || echo "?")"
    armed="$(jq -r 'if .data.repository.pullRequest.autoMergeRequest != null then "yes" else "no" end' <<<"$g" 2>/dev/null || echo "?")"
    queue="$(jq -r '.data.repository.pullRequest.mergeQueueEntry.position // empty' <<<"$g" 2>/dev/null)"
    mstate="$(jq -r '.data.repository.pullRequest.mergeStateStatus // "?"' <<<"$g" 2>/dev/null)"
    mergeable="$(jq -r '.data.repository.pullRequest.mergeable // "?"' <<<"$g" 2>/dev/null)"
    red="$(jq -r '[.data.repository.pullRequest.statusCheckRollup.contexts.nodes[]? | select((.conclusion // .state // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED|STARTUP_FAILURE")) | (.name // .context)] | join(",")' <<<"$g" 2>/dev/null)"
    pending="$(jq -r '[.data.repository.pullRequest.statusCheckRollup.contexts.nodes[]? | select(((.status // "") | test("IN_PROGRESS|QUEUED|PENDING|WAITING|REQUESTED")) or ((.state // "") | test("PENDING|EXPECTED"))) | select((.conclusion // "") == "")] | length' <<<"$g" 2>/dev/null || echo 0)"
    ncontexts="$(jq -r '[.data.repository.pullRequest.statusCheckRollup.contexts.nodes[]?] | length' <<<"$g" 2>/dev/null || echo 0)"
    if [[ -n "$red" ]]; then checks="red:$red"; elif [[ "$pending" != "0" ]]; then checks="pending:$pending"; elif [[ "$ncontexts" == "0" ]]; then checks="none-yet"; else checks="green"; fi
    # ── review of the current head ──
    rs="$("$REVIEW_STATUS" "$num" 2>/dev/null)"; rsrc=$?
    if [[ $rsrc -eq 2 ]]; then review="?"; else
        head_reviewed="$(sed -n 's/^  head reviewed? *: *\([a-z]*\).*/\1/p' <<<"$rs" | head -1)"
        any="$(sed -n 's/^  \(independent reviews\|blind reviews\|verdict comments\) *: *\([0-9]*\).*/\2/p' <<<"$rs" | awk '{s+=$1} END{print s+0}')"
        if [[ "$head_reviewed" == "yes" ]]; then review="head reviewed"; elif [[ "$any" -gt 0 ]]; then review="NOT on head"; else review="none"; fi
    fi
    # ── the verdict ──
    blocks=()
    [[ "$draft" == "true" ]] && blocks+=("a draft — mark it ready first")
    [[ "$mergeable" == "CONFLICTING" ]] && blocks+=("conflicts with $base")
    [[ "$checks" == red:* ]] && blocks+=("red checks: ${checks#red:}")
    [[ "$checks" == pending:* ]] && blocks+=("${checks#pending:} check(s) pending")
    [[ "$checks" == none-yet ]] && blocks+=("no check has reported yet (seconds after a push, or nothing runs on this PR)")
    [[ "$review" != "head reviewed" ]] && blocks+=("no review of the head ($review)")
    [[ "$unresolved" != "0" ]] && blocks+=("$unresolved unresolved thread(s)")
    # An AWAITING-SUPPLY line in the body with no range line for that
    # login: supply asked for and not folded (the reading owed-supply.sh
    # and arm.sh share; #886 review F3 — the skill said this was read
    # here and it was not).
    awaiting="$(jq -r --argjson n "$num" '
        (.[] | select(.number == $n) | .body // "") as $b
        | [ $b | split("\n")[] | capture("^[[:space:]]*-?[[:space:]]*AWAITING-SUPPLY:[[:space:]]*(?<who>[^[:space:]]+)") | .who | split("/") | last ]
        | map(select(. as $l | ($b | test("[0-9a-f]{7,40}\\.\\.[0-9a-f]{7,40}:[[:space:]]*" + $l + "([^A-Za-z0-9_-]|$)")) | not))
        | join(", ")' <<<"$list")"
    [[ -z "$awaiting" ]] || blocks+=("awaiting supply from $awaiting (AWAITING-SUPPLY in the body, no range line yet)")
    if [[ -n "$queue" ]]; then verdict="QUEUED (position $queue) — nothing to do"
    elif [[ "$armed" == "yes" && ${#blocks[@]} -eq 0 ]]; then verdict="ARMED and clear — merges on the queue's run"
    elif [[ "$armed" == "yes" ]]; then verdict="ARMED but held: $(printf '%s; ' "${blocks[@]}" | sed 's/; $//')"
    elif (( ${#blocks[@]} > 0 )); then verdict="BLOCKED: $(printf '%s; ' "${blocks[@]}" | sed 's/; $//')"
    elif (( commits_known == 0 )); then verdict="MERGEABLE — commits unknown (fetch the base); apply the count rule by hand"
    elif (( work > 16 )); then verdict="MERGEABLE — $work work commits, over 16: smaller batches next time; arm on the basis (the owner, 2026-09-19: advice for the next batch, never a reorganisation of this PR)"
    elif (( work >= 8 )); then verdict="MERGEABLE — arm: post the basis ($work work commits, review on head) and gh pr merge $num --auto"
    else verdict="MERGEABLE — ask the owner ($work work commits < 8), then arm"
    fi
    # The OWNER is the session that opened it, read from the branch's
    # <host>/<login>/ prefix — never from the PR author, since every
    # session pushes as one GitHub user. A branch of another shape has no
    # session to name and is shown as its first segment.
    owner="$(awk -F/ 'NF >= 3 {print $1"/"$2; next} {print $1}' <<<"$hbranch")"
    [[ "$owner" == "$session" ]] && mine="yes" || mine="no"
    rows="$(jq --argjson n "$num" --arg aw "$awaiting" --arg t "$title" --arg b "$hbranch" --arg o "$owner" --arg mine "$mine" --arg h "${head:0:8}" --argjson w "$( (( commits_known )) && echo "$work" || echo null)" --argjson f "$( (( commits_known )) && echo "$fix" || echo null)" --argjson fs "$fix_subjects" --argjson m "$( (( commits_known )) && echo "$merges" || echo null)" --argjson known "$( (( commits_known )) && echo true || echo false)" --arg c "$checks" --arg r "$review" --arg u "$unresolved" --arg a "$armed" --arg q "${queue:-}" --arg ms "$mstate" --arg d "$draft" --arg v "$verdict" \
        '. + [{number:$n, title:$t, branch:$b, owner:$o, mine:($mine == "yes"), head:$h, work_commits:$w, fix_commits:$f, fix_subjects:$fs, merge_commits:$m, commits_known:$known, awaiting_supply:($aw | if . == "" then [] else split(", ") end), checks:$c, review:$r, unresolved_threads:$u, armed:$a, queue_position:$q, merge_state:$ms, draft:($d == "true"), verdict:$v}]' <<<"$rows")"
done < <(jq -r '.[] | [.number, .title, .headRefOid, .baseRefName, .headRefName, (.isDraft // false)] | @tsv' <<<"$list")

if [[ $JSON -eq 1 ]]; then jq . <<<"$rows"; exit 0; fi
jq -r '.[] | "#\(.number)  \(.owner)\(if .mine then " (me)" else "" end)  commits=\(if .commits_known then "\(.work_commits + .fix_commits + .merge_commits) (\(.work_commits) work, \(.fix_commits) fix, \(.merge_commits) merge)" else "unknown (fetch)" end)  checks=\(.checks)  review=\(.review)  threads=\(.unresolved_threads)  armed=\(.armed)\(if .queue_position != "" then "  queue=\(.queue_position)" else "" end)\n      \(.title[0:88])\(if (.fix_subjects | length) > 0 then "\n      counted as fix: " + (.fix_subjects | map("\"" + .[0:60] + "\"") | join("; ")) else "" end)\n      \(.verdict)"' <<<"$rows"
exit 0
