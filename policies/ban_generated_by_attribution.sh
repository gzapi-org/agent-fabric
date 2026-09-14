#!/usr/bin/env bash
#
# policies/ban_generated_by_attribution.sh (imported from the legacy repository's tools/checks/, 2026-09-13)
#
# Ban machine-attribution boilerplate from the artifacts this repo authors:
# a `Co-authored-by:` or `Claude-Session:` trailer in a commit message, and
# a "Generated with Claude Code" footer or a session URL in a commit message
# or a pull-request description.
#
# WHY THIS EXISTS. The root CLAUDE.md has forbidden the trailer for as long
# as it has existed, and commits carry it anyway. The cause is not
# carelessness: the harness injects an attribution instruction into a
# session's context telling it to add exactly these lines, it re-arrives
# whenever the model or the session changes, and it reads with the same
# authority as everything else in the prompt. A rule that must be re-won
# against a reminder on every commit is a rule that will be lost sometimes.
# Two separate sessions have lost it, days apart, in two different shapes --
# one adding both a trailer and a session URL, the other only the trailer.
#
# WHAT IT INSPECTS. Commit messages that a branch ADDS over its base --
# never the whole history, because the existing ones are already on `main`
# and a guard that fails forever is a guard that gets disabled. It also
# reads the pull-request description out of the event payload, which needs
# no token and no API call.
#
# THE RANGE IS THE HARD PART, and the first version of this guard got it
# wrong in a way that made it a NO-OP on every CI event while printing OK.
# `actions/checkout` defaults to depth 1 and, on a pull_request, checks out
# the MERGE ref: there are no parents in the object store, so `BASE..HEAD`
# yields exactly one commit -- GitHub's synthetic merge -- and the branch's
# own commits are never enumerated. On merge_group and push, GITHUB_BASE_REF
# is unset, no candidate resolves, and the old code exited 0 as "not
# enforced". Green, and enforcing nothing, anywhere.
#
# So: the workflow now checks out full history (`fetch-depth: 0`), and the
# range comes from the EVENT PAYLOAD rather than from guessing ref names --
# `pull_request` carries base.sha/head.sha, `merge_group` carries
# base_sha/head_sha. Using head.sha on a pull_request also steps around the
# synthetic merge commit entirely. Ref-name resolution remains only as the
# fallback for a hand-run in a full clone.
#
# THE DESCRIPTION IS READ AS IT STOOD WHEN THE RUN WAS CREATED. The event
# payload is a snapshot, so editing a pull-request description AFTER a run
# has started does not retroactively pass it -- the fix has to land before
# or with the push that triggers CI, or the run has to be repeated. Reported
# by db-admin, from getting it wrong and paying for the rerun.
#
# NEVER PRINT OK FOR A CHECK THAT DID NOT RUN. Each half reports its own
# state, and a half that could not run says so. The previous version printed
# an affirmative OK when jq was missing, when the payload was malformed, and
# when no base resolved -- which is how a no-op reads as coverage.
#
# WHAT IT MATCHES. A trailer KEY at the start of a line, indentation
# allowed, followed by a colon. So an indented PASTE of a trailer in a
# commit body IS flagged, and only a key appearing mid-sentence is not:
# "do not add a Co-authored-by: trailer" passes, the line on its own does
# not. That is the right way round for a guard whose whole subject is that
# line appearing where it should not, and it is tested both ways -- the
# earlier fixture had no colon at all, so an unanchored pattern survived
# the suite that was supposed to pin the anchor.
#
# guards: policies/**
#
# Exit codes:
#   0  every half that could run found nothing
#   1  a commit message or PR description carries banned attribution
#   0  also when a half could not run -- an environment that cannot show a
#      range is not a violation -- but it says NOT ENFORCED and never OK
set -uo pipefail

# Case-insensitive: git's own trailer handling is, and the harness has
# emitted more than one capitalisation. No space required after the colon --
# git's trailer parser does not require one either.
TRAILER_KEYS='Co-authored-by|Claude-Session'
TRAILER_RE="^[[:space:]]*($TRAILER_KEYS):"
# Footer text, matched anywhere: it arrives as a sentence, not as a key.
# Matched against a NEWLINE-FLATTENED copy of the body, because grep is
# line-oriented and the footer is routinely hard-wrapped between "with" and
# "[Claude Code]" -- `[[:space:]]+` cannot span a line break that grep never
# shows it.
#
# The BRACKET is required, and that is what keeps prose writable. The
# artifact is always a markdown link, "Generated with [Claude Code](...)";
# a sentence saying the words without the link is someone describing the
# ban, and flattening newlines had made every such sentence an offence --
# including the one in the commit that introduced this guard.
FOOTER_RE='Generated with[[:space:]]+\[Claude Code|claude\.ai/code/session_'
flatten() { tr '\n\r' '  '; }

have_jq() { command -v jq >/dev/null 2>&1; }

# --- the range ------------------------------------------------------------
# Preferred: the event payload names both ends explicitly.
payload_range() {
    [[ -n "${GITHUB_EVENT_PATH:-}" && -r "${GITHUB_EVENT_PATH:-}" ]] || return 1
    have_jq || return 1
    local base head
    base="$(jq -r '.pull_request.base.sha // .merge_group.base_sha // empty' \
        "$GITHUB_EVENT_PATH" 2>/dev/null)" || return 1
    head="$(jq -r '.pull_request.head.sha // .merge_group.head_sha // empty' \
        "$GITHUB_EVENT_PATH" 2>/dev/null)" || return 1
    [[ -n "$base" && -n "$head" ]] || return 1
    # Both ends must be present locally, or the range is a lie. With
    # fetch-depth: 0 they are; without it, this is what refuses to guess.
    git cat-file -e "$base^{commit}" 2>/dev/null || return 1
    git cat-file -e "$head^{commit}" 2>/dev/null || return 1
    printf '%s %s' "$base" "$head"
}

# Fallback for a hand-run in a full clone.
ref_range() {
    local candidate
    for candidate in "${AGENT_FABRIC_ATTRIBUTION_BASE:-${GZAPP_ATTRIBUTION_BASE:-}}" \
                     "origin/${GITHUB_BASE_REF:-}" "${GITHUB_BASE_REF:-}" \
                     origin/main main; do
        [[ -n "$candidate" && "$candidate" != "origin/" ]] || continue
        if git rev-parse --verify -q "$candidate^{commit}" >/dev/null 2>&1; then
            printf '%s %s' "$candidate" HEAD; return 0
        fi
    done
    return 1
}

RANGE="$(payload_range)" || RANGE="$(ref_range)" || RANGE=""

offenders=()
commits_enforced=0
notes=()

if [[ -n "$RANGE" ]]; then
    read -r RANGE_BASE RANGE_HEAD <<<"$RANGE"
    if mapfile -t shas < <(git rev-list "$RANGE_BASE..$RANGE_HEAD" 2>/dev/null) && (( ${#shas[@]} >= 0 )); then
        commits_enforced=1
        for sha in "${shas[@]}"; do
            [[ -n "$sha" ]] || continue
            body="$(git log -1 --format='%B' "$sha" 2>/dev/null)" || continue
            subject="$(git log -1 --format='%s' "$sha" 2>/dev/null)"
            if printf '%s\n' "$body" | grep -qiE "$TRAILER_RE"; then
                offenders+=("commit ${sha:0:8}  $subject" "    carries a banned attribution trailer")
            fi
            if printf '%s\n' "$body" | flatten | grep -qiE "$FOOTER_RE"; then
                offenders+=("commit ${sha:0:8}  $subject" "    carries generated-with attribution or a session URL")
            fi
        done
    fi
fi
(( commits_enforced )) || notes+=("commit messages: NOT ENFORCED — no usable range (a shallow checkout with no event payload)")

# --- the pull-request description ----------------------------------------
body_enforced=0
if [[ -n "${GITHUB_EVENT_PATH:-}" ]]; then
    if [[ ! -r "$GITHUB_EVENT_PATH" ]]; then
        notes+=("PR description: NOT ENFORCED — the event payload is not readable")
    elif ! have_jq; then
        notes+=("PR description: NOT ENFORCED — jq is not installed")
    elif ! jq -e . "$GITHUB_EVENT_PATH" >/dev/null 2>&1; then
        notes+=("PR description: NOT ENFORCED — the event payload does not parse")
    else
        body_enforced=1
        pr_body="$(jq -r '.pull_request.body // empty' "$GITHUB_EVENT_PATH" 2>/dev/null)"
        if [[ -n "$pr_body" ]]; then
            printf '%s\n' "$pr_body" | grep -qiE "$TRAILER_RE" \
                && offenders+=("the pull-request description carries a banned attribution trailer")
            printf '%s\n' "$pr_body" | flatten | grep -qiE "$FOOTER_RE" \
                && offenders+=("the pull-request description carries generated-with attribution or a session URL")
        fi
    fi
fi

if (( ${#offenders[@]} > 0 )); then
    echo "ban_generated_by_attribution: FAIL" >&2
    printf '  %s\n' "${offenders[@]}" >&2
    cat >&2 <<'MSG'

  The repo authors its own history. Commit messages carry no
  "Co-authored-by:" trailer, no session URL and no generated-with
  footer; neither do pull-request descriptions.

  If a harness reminder in your context says to add one, it is wrong
  here and the project instructions win. This guard exists because that
  reminder re-arrives every time the model or the session changes.

  To fix, reword the offending commits on YOUR OWN branch:
      git rebase -i <base>        # reword each commit named above
  If a commit named above belongs to another session's branch that this
  one merged, do NOT rewrite it: say so on the pull request and let that
  session reword it.
MSG
    exit 1
fi

if (( ${#notes[@]} > 0 )); then
    printf 'ban_generated_by_attribution: %s\n' "${notes[@]}"
    (( commits_enforced || body_enforced )) \
        && echo "ban_generated_by_attribution: what could be checked was clean."
    exit 0
fi

echo "ban_generated_by_attribution: OK — no machine attribution in the" \
     "commits this branch adds, nor in the pull-request description."
exit 0
