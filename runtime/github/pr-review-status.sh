#!/usr/bin/env bash
# runtime/github/pr-review-status.sh (lifted from gzapp's tools/gh/, 2026-09-19 — general to every managed project; gzapp's copy is a shim)
#
# >>> help
# Has anyone OTHER THAN THE AUTHOR actually reviewed the code that is at
# the head of this PR right now? A raw `gh pr view` cannot answer that.
#
# Two GitHub behaviours make the obvious reading wrong, and both bit
# this repo:
#
#   1. Replying to a review thread (addPullRequestReviewThreadReply)
#      creates a REVIEW object with an empty body, authored by you.
#      Three self-replies look like three new reviews. On PR #363 that
#      made a self-authored thread look like independent coverage.
#
#   2. A review comment's `commit_id` is re-anchored to the CURRENT
#      head whenever the file it points at has not changed. A finding
#      written against an old commit therefore DISPLAYS as though it
#      were evaluated against code that did not exist when it was
#      written. `original_commit_id` is the honest field.
#
# So: filter by AUTHOR, and compare the newest independent review's
# commit against headRefOid. Everything else is noise.
#
# WAITING (--wait). Automated review fires on PR **open** and on
# explicit request — never on a push. So there are two very different
# "no review yet" states, and only one of them is worth waiting through:
#
#   * never reviewed          — a review is coming; wait for it.
#   * reviewed, then pushed   — nothing is coming, ever, until someone
#                               asks. Waiting cannot help, and a timeout
#                               here would report "no review" as though
#                               the bot were merely slow.
#
# The second exits 5 IMMEDIATELY with the cause named, rather than
# burning the timeout. That distinction is the reason to wait with this
# instead of sleeping. Same shape as wait-merged.sh: run it detached and
# the exit is the callback.
#
# ...on an OPEN pr. A MERGED one is not a third state, it is the first
# one again: review lands on merged prs here routinely — that is what the
# post-merge sweep exists for, and `@codex review` on a merged pr is
# answered — so a merged pr keeps waiting rather than being told nothing
# is coming. A pr CLOSED without merging will receive nothing further and
# ends the wait at 1.
#
# Usage:
#   tools/gh/pr-review-status.sh <pr-number> [owner/repo] [options]
#
# Options:
#   --wait <duration>      poll until the head is reviewed (default 0 =
#                          answer once and exit, the original behaviour)
#   --interval <duration>  between polls (default 30, as wait-merged.sh;
#                          the API is rate limited and humans are slow)
#
# Durations take an optional unit — 90, 90s, 10m, 2h. A bare number is
# SECONDS, so anything written before units existed still means what it
# meant. wait-merged.sh accepts exactly the same forms.
#   -q, --quiet            no progress lines on stderr
#   --automated-only       only the RECOGNISED automated reviewer counts
#                          as coverage; a human review object is reported
#                          but does not satisfy the answer. Use this when
#                          the question is "has the bot reported", not
#                          "did anyone look" — the security-boundary gate
#                          in CLAUDE.md is exactly that question, and the
#                          default mode would let one human review arm a
#                          merge the gate meant to hold for the bot.
#   -h, --help             this text
#
# A CLEAN REVIEW IS NOT A REVIEW OBJECT. When the automated reviewer
# finds nothing it posts an ordinary issue COMMENT and creates no
# review. Counting only review objects therefore reported
# `head reviewed? no` on exactly the prs that PASSED, and then exit 5,
# "no review is coming", about a review that had already happened and
# succeeded.
#
# Those comments name what they looked at — `**Reviewed commit:** <sha>`
# — so this reads the sha rather than inferring coverage from a
# timestamp. Inferring would be the confident wrong answer this script
# exists to avoid: a verdict comment can arrive after a push and still
# describe the commit before it. Only a RECOGNISED reviewer account
# counts; see VERDICT_AUTHORS below for why that is a list and not a
# negation.
#
# Exit codes:
#   0  the current head has at least one independent review — ANY of
#      them, not merely the most recent, which can be older by commit
#      than one submitted before it — or a verdict comment naming it
#   1  it does not — nothing yet, --wait expired still waiting, or the
#      pr was closed without merging
#   2  invocation problem (no gh, not authenticated, unknown PR), or the
#      pr could not be read — including a reviews or comments lookup that
#      FAILED, which is never reported as "no reviews"
#   5  no review is COMING, for either of two causes on an OPEN pr:
#      the head advanced past every independent review and verdict
#      comment with none requested, or the REVIEWER DECLINED — a spent
#      Codex allowance (#470, #472) or a missing repo environment
#      (#461), which it says in the comment stream and which no amount
#      of waiting resolves. Both name the cause, and a `decline reason`
#      line says WHICH — a spent allowance is not a refusal of this
#      diff, and re-asking does not help (seq 915). Distinguished from 1
#      the way wait-merged.sh distinguishes 6 from 4: 1 means "not yet",
#      5 names the cause. Never returned for a merged pr, which can
#      still be reviewed.
# <<< help

set -uo pipefail

PR=""
REPO=""
WAIT=0
INTERVAL=30
QUIET=0
# Restrict coverage to the RECOGNISED automated reviewer.
#
# Off by default: the ordinary question is "did anyone other than me
# look at this", and a human review is a perfectly good answer to it.
AUTOMATED_ONLY=0

die() { echo "pr-review-status: $*" >&2; exit 2; }

need_operand() {
    [[ $# -ge 2 ]] || die "$1 needs a value (try --help)."
}

# Durations take an optional unit: 90, 90s, 10m, 2h. A BARE NUMBER IS
# SECONDS — which is what every existing invocation already meant, so
# nothing changes for a caller that passed one.
#
# wait-merged.sh carries an identical copy. That is deliberate: these are
# standalone scripts with no shared library, and a divergence in what
# they accept is exactly the confusion the units were added to remove.
# Both suites assert the same table, so a drift fails a test.
as_seconds() {
    local flag="$1" raw="$2" n
    case "$raw" in
        ''|*[!0-9smh]*) die "$flag needs a duration like 90, 90s, 10m or 2h, got '$raw'." ;;
    esac
    n="${raw%[smh]}"
    [[ "$n" =~ ^[0-9]+$ ]] \
        || die "$flag needs a duration like 90, 90s, 10m or 2h, got '$raw'."
    case "$raw" in
        *h) echo $(( n * 3600 )) ;;
        *m) echo $(( n * 60 )) ;;
        *)  echo "$n" ;;
    esac
}

want_positive() {
    [[ "$2" =~ ^[1-9][0-9]*$ ]] \
        || die "$1 must be greater than zero, got '$3'."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        # `as_seconds` dies inside a command substitution, which only
        # kills the SUBSHELL — without propagating the status here the
        # script would sail on with an empty value.
        --wait)
            need_operand "$@"; WAIT="$(as_seconds "$1" "$2")" || exit 2; shift 2 ;;
        --interval)
            need_operand "$@"; INTERVAL="$(as_seconds "$1" "$2")" || exit 2
            want_positive "$1" "$INTERVAL" "$2"; shift 2 ;;
        -q|--quiet) QUIET=1; shift ;;
        --automated-only) AUTOMATED_ONLY=1; shift ;;
        -h|--help)
            sed -n '/^# >>> help$/,/^# <<< help$/p' "$0" \
                | sed 's/^# \{0,1\}//; 1d; $d'
            exit 0 ;;
        -*) die "unknown option '$1' (try --help)" ;;
        *)
            if   [[ -z "$PR"   ]]; then PR="$1"
            elif [[ -z "$REPO" ]]; then REPO="$1"
            else die "unexpected argument '$1' (try --help)"
            fi
            shift ;;
    esac
done

[[ -n "$PR" ]] || die "a PR number is required (try --help)"

command -v gh >/dev/null 2>&1 || die "gh is required but not installed."

if [[ -z "$REPO" ]]; then
    REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || \
        die "could not determine the repository; pass owner/repo."
fi

note() { (( QUIET )) || echo "pr-review-status: $*" >&2; }

# ── One probe ────────────────────────────────────────────────────────
#
# Sets the globals the loop branches on. Kept separate from rendering so
# a poll costs three API calls, not the whole report: the thread and
# check queries below are for the human reading the final answer, and
# running them every 30 seconds would be rude to the rate limiter for
# output nobody sees.

# The marker tools/gh/post-substitute-review.sh writes as the first line
# of every substitute review. Must stay byte-identical to the constant in
# that script; both self-tests pin it, so a one-sided change is caught.
SUBSTITUTE_REVIEW_MARKER='<!-- gzapp-substitute-review v1 -->'

# Accounts whose verdict COMMENT counts as a review.
#
# A LIST, because the alternative is a negation and a negation is what
# lets anybody in. "Not the PR author" is the right filter for a review
# OBJECT — GitHub only lets a reviewer create one — and the wrong filter
# for a comment, which anyone with access may leave: accepting any
# non-author comment carrying the phrase would let a third party mark a
# head reviewed by typing it.
#
# Both spellings of the bot login are listed rather than normalised: the
# `[bot]` suffix varies by API surface, and a normalisation that quietly
# stopped matching would fail OPEN.
#
# Override with GZAPP_VERDICT_AUTHORS (a JSON array) if the reviewer
# account ever changes.
VERDICT_AUTHORS="${GZAPP_VERDICT_AUTHORS:-[\"chatgpt-codex-connector\",\"chatgpt-codex-connector[bot]\"]}"

probe_ok=0
qualifying='[]'
qual_count=0
verdicts='[]'
verdict_count=0
refusal_at=""
refusal_current=no
pending_others=0
request_at=""
request_pending=no
probe() {
    # RESET, not just set on success. A probe that overwrites `head` from
    # the metadata call and then fails on reviews would otherwise leave
    # the flag standing from an EARLIER successful probe, and the report
    # would pair the new head with the old review data — a mismatch that
    # reads as authoritative.
    probe_ok=0
    local meta reviews
    meta="$(gh pr view "$PR" --repo "$REPO" \
        --json state,mergeStateStatus,headRefOid,headRefName,author,isDraft,reviewRequests \
        2>/dev/null)" || return 1

    head="$(jq -r '.headRefOid'          <<<"$meta")"
    head_ref="$(jq -r '.headRefName // ""' <<<"$meta")"
    state="$(jq -r '.state'              <<<"$meta")"
    mergest="$(jq -r '.mergeStateStatus'  <<<"$meta")"
    author="$(jq -r '.author.login'      <<<"$meta")"
    # NARROWED BY THE MODE, exactly as `qualifying` is.
    #
    # `requested` suppresses the exit-5 verdict, so under
    # --automated-only a pending HUMAN reviewer would keep the command
    # waiting and then reporting 1 about a bot review that is not coming
    # — the mode narrowed coverage and left the freshness terms reading
    # a different population. Whatever answers the question has to be
    # the same set the question is about.
    if (( AUTOMATED_ONLY )); then
        requested="$(jq --argjson allowed "$VERDICT_AUTHORS" \
            '[.reviewRequests[]? | select((.login // .slug // "") as $l | $allowed | index($l))] | length' \
            <<<"$meta")"
    else
        requested="$(jq '.reviewRequests | length' <<<"$meta")"
    fi
    # Everyone still on the request list who is NOT the reviewer that
    # can decline. A decline answers the reviewer who made it and
    # nobody else, and in default mode any of these would satisfy the
    # question — so their pending requests have to survive it.
    pending_others="$(jq --argjson allowed "$VERDICT_AUTHORS" \
        '[.reviewRequests[]?
          | select((((.login // .slug // "") as $l | $allowed | index($l)) | not))]
         | length' <<<"$meta")"

    # PAGINATED, and a failure here reads UNREADABLE — never empty. This
    # script's whole job is answering "was this really reviewed", so
    # turning a rate limit, a permission gap or a transient 5xx into `[]`
    # produces the confident wrong answer "no reviews" and lets a caller
    # conclude a reviewed pr was never looked at. Returning 1 feeds the
    # consecutive-failure counter instead, which is what the exit-2
    # contract already promises for an unreadable pr.
    #
    # Unpaginated, a pr with more review objects than one REST page
    # silently lost the rest — plausible here precisely because this
    # script documents that thread replies create review objects, so the
    # count climbs with correspondence rather than with coverage.
    #
    # `local` is on its own line deliberately: `local x="$(cmd)"` takes
    # local's exit status, not the command's, which would make the
    # failure branch below unreachable.
    local reviews_raw
    reviews_raw="$(gh api --paginate "repos/$REPO/pulls/$PR/reviews" 2>/dev/null)" || return 1
    reviews="$(jq -s 'add // []' <<<"$reviews_raw" 2>/dev/null)" || return 1

    # Independent = not authored by the PR author. The empty-body test is
    # NOT used to classify: a genuine reviewer may leave an empty-bodied
    # review carrying only inline comments. Authorship is the honest axis.
    # MARKED FIRST, then authorship. A substitute review is authored by
    # the same account as everything else, so classifying by author first
    # loses it; and a marked review from ANY account is a substitute, not
    # an independent reviewer — gating the marker test on authorship made
    # a marked review from another login count as a genuine independent
    # review, silently, in the dangerous direction.
    #
    # startswith, NOT contains. The emitter guarantees the marker is the
    # FIRST LINE; a substring test counted any review whose body merely
    # QUOTED the marker — reviewing this mechanism is enough to do it —
    # and subtracted that review from `self` at the same time. A false
    # "this was reviewed" is worse than the under-counting this whole
    # change exists to fix.
    marked="$(jq --arg m "$SUBSTITUTE_REVIEW_MARKER" \
        '[.[] | select((.body // "") | startswith($m))]' <<<"$reviews")"
    unmarked="$(jq --arg m "$SUBSTITUTE_REVIEW_MARKER" \
        '[.[] | select(((.body // "") | startswith($m)) | not)]' <<<"$reviews")"

    independent="$(jq --arg a "$author" '[.[] | select(.user.login != $a)]' <<<"$unmarked")"

    # SUBSTITUTE BLIND REVIEWS ARE COVERAGE, and authorship cannot see
    # them. Every session pushes as the SAME account, so a substitute
    # review posted by another session is authored by the PR author and
    # fell into `self` — the bucket labelled "thread replies … not
    # coverage". Across a three-day reviewer blackout that reported 0
    # reviews on 29 PRs, five of which had a real blind review sitting on
    # them.
    #
    # A MARKER, not prose. The guidance used to say "attribute it in the
    # body", and three sessions wrote three different sentences. A
    # coverage claim inferred from prose is worse than no claim, so the
    # test is an exact string that tools/gh/post-substitute-review.sh
    # emits and nothing else produces by accident.
    substitute="$marked"
    self="$(jq --arg a "$author" '[.[] | select(.user.login == $a)]' <<<"$unmarked")"

    # WHICH REVIEWS COUNT AS COVERAGE, which is not the same question as
    # which are independent.
    #
    # "Not the PR author" is the right test for independence and the
    # wrong test for a gate that names a specific reviewer. Under
    # --automated-only a human review object no longer answers "has the
    # automated reviewer reported", so it is reported but does not
    # cover — the same allow-list the verdict comments already use, and
    # for the same reason: a negation lets everybody in.
    if (( AUTOMATED_ONLY )); then
        qualifying="$(jq --argjson allowed "$VERDICT_AUTHORS" \
            '[.[] | select(.user.login as $l | $allowed | index($l))]' <<<"$independent")"
    else
        qualifying="$independent"
    fi
    # A SUBSTITUTE COUNTS, in both modes. When the reviewer declines, the
    # blind agent IS the sanctioned review — CLAUDE.md's decline path says
    # to treat its findings as the bot's — so a gate that never accepted
    # one could not be satisfied at all during an outage, and the
    # security-boundary wait would either block forever or be ignored.
    # Counted under --automated-only too, for the same reason: that flag
    # asks "has a machine-grade review reported", not "was it that
    # specific account".
    #
    # Reported on its own line regardless, so provenance survives: this
    # makes a substitute SUFFICIENT, never indistinguishable.
    qualifying="$(jq -s 'add' <<<"$qualifying $substitute")"

    ind_count="$(jq 'length' <<<"$independent")"
    qual_count="$(jq 'length' <<<"$qualifying")"
    self_count="$(jq 'length' <<<"$self")"
    substitute_count="$(jq 'length' <<<"$substitute")"

    # VERDICT COMMENTS. Unreadable rather than empty, for the same reason
    # the reviews call is: a swallowed failure here would report a clean
    # review as no review, which is the whole defect this fetch fixes.
    local comments_raw comments
    comments_raw="$(gh api --paginate "repos/$REPO/issues/$PR/comments" 2>/dev/null)" || return 1
    comments="$(jq -s 'add // []' <<<"$comments_raw" 2>/dev/null)" || return 1

    # A comment from a RECOGNISED reviewer that names the commit it
    # reviewed. The sha in the body is abbreviated, so match on prefix in
    # BOTH directions — neither string is reliably the longer one.
    #
    # The sha is READ, never inferred from "a comment arrived after the
    # push": a verdict can arrive after a push and still describe the
    # commit before it, and a confident wrong answer there is exactly
    # what this script exists to avoid.
    verdicts="$(jq --arg a "$author" --argjson allowed "$VERDICT_AUTHORS" '
        [ .[]
          | select(.user.login as $l | $allowed | index($l))
          | select(.user.login != $a)
          | (.body // "") as $b
          | ($b | capture("Reviewed commit:[^`]*`(?<sha>[0-9a-f]{7,40})`"; "i") // empty) as $m
          | {login: .user.login, at: .created_at, sha: $m.sha}
        ]' <<<"$comments" 2>/dev/null)" || verdicts='[]'
    verdict_count="$(jq 'length' <<<"$verdicts")"

    # REFUSALS. The reviewer also declines, in the same comment stream
    # and from the same account: "You have reached your Codex usage
    # limits for code reviews" (#470, #472) and "To use Codex here,
    # create an environment for this repo" (#461).
    #
    # Those are not slowness, they are a review that will not happen —
    # exactly the state exit 5 exists to name — but nothing in the
    # review objects says so, so `--wait 30m` sat out the whole timeout
    # and then reported "not yet" about something permanent.
    #
    # Matched on the reviewer's own wording rather than a generic
    # "sounds negative" heuristic: a wrong positive here abandons a
    # review that was merely slow, which is the more expensive mistake.
    refusal_at="$(jq -r --argjson allowed "$VERDICT_AUTHORS" '
        [ .[]
          | select(.user.login as $l | $allowed | index($l))
          | select((.body // "")
                   | test("reached your .* usage limits for code reviews"; "i")
                     or test("create an environment for this repo"; "i"))
          | .created_at ]
        | sort | last // ""' <<<"$comments" 2>/dev/null)" || refusal_at=""
    # THE REASON, read off the same comment: a spent allowance and a
    # missing environment are both "no review is coming", but they ask
    # different things of the reader. The allowance case reads, in the
    # status line alone, like a refusal of THIS diff — three sessions on
    # 2026-09-17 each re-asked before opening the PR and finding the
    # bot's own sentence (web-dev-01, relay seq 915). Say which it is.
    refusal_reason=""
    if [[ -n "$refusal_at" ]]; then
        refusal_reason="$(jq -r --argjson allowed "$VERDICT_AUTHORS" --arg at "$refusal_at" '
            [ .[] | select(.user.login as $l | $allowed | index($l)) | select(.created_at == $at)
              | (.body // "") ] | first // ""
            | if test("usage limits for code reviews"; "i") then "usage limit — the allowance is spent; asking again does not help, every PR declines until it resets (substitute review per the standing rule)"
              elif test("create an environment for this repo"; "i") then "no environment — the reviewer cannot open this repo (an account setting, not this diff)"
              else "" end' <<<"$comments" 2>/dev/null)" || refusal_reason=""
    fi

    # A PENDING REQUEST, read from the same comment stream.
    #
    # `@codex review` is how a review is asked for here, and it is NOT a
    # GitHub review *request* — `reviewRequests` stays empty — so
    # `requested == 0` holds while one is genuinely in flight and the
    # stale-review branch fired "no review is coming" seconds after the
    # ask. That broke the exact sequence CLAUDE.md prescribes for a
    # security-boundary change: request, then wait. Observed on #501.
    #
    # NO allow-list here, deliberately, and the asymmetry is the point.
    # This signal can only ever turn 5 ("nothing is coming") into 1
    # ("not yet") — it never marks a head reviewed, so the worst a
    # forged request can do is make the tool wait longer. The verdict
    # and refusal filters are allow-listed because they can end a wait;
    # this one cannot.
    request_at="$(jq -r '
        [ .[] | select((.body // "") | test("@codex[[:space:]]+review"; "i"))
          | .created_at ]
        | sort | last // ""' <<<"$comments" 2>/dev/null)" || request_at=""

    head_reviewed=no
    newest_ind_commit=""

    # Either kind of evidence counts, and a verdict comment is checked
    # even when there are no review objects at all — a PR whose only
    # review came back CLEAN has none.
    if [[ "$(jq -r --arg h "$head" \
          'any(.[]; (.sha as $s | ($h | startswith($s)) or ($s | startswith($h))))' \
          <<<"$verdicts")" == "true" ]]; then
        head_reviewed=yes
    fi

    if (( qual_count > 0 )); then
        newest_ind_commit="$(jq -r 'sort_by(.submitted_at) | last | .commit_id' <<<"$qualifying")"
        # COVERAGE IS "ANY review targets head", NOT "the newest one
        # does". A review opened before the last push but SUBMITTED after
        # a fresh one is newer by timestamp and older by commit, so
        # selecting by recency lets a stale review mask a real one — and
        # this script would then call the head unreviewed while the
        # review it wanted was already sitting there. The newest is kept
        # for REPORTING only.
        if [[ "$(jq -r --arg h "$head" 'any(.[]; .commit_id == $h)' <<<"$qualifying")" == "true" ]]; then
            head_reviewed=yes
        fi
    fi

    # A refusal only speaks for the CURRENT state. The reviewer recovers
    # — the allowance resets, the environment gets created — and a
    # verdict or review arriving afterwards supersedes it. So the
    # refusal counts only when nothing newer has landed; otherwise a
    # spent allowance from last week would end every wait on this PR
    # forever.
    refusal_current=no
    if [[ -n "$refusal_at" ]]; then
        local newest_evidence
        newest_evidence="$(printf '%s\n%s\n' "$qualifying" "$verdicts" | jq -rs '
            (.[0] | map(.submitted_at)) + (.[1] | map(.at))
            | sort | last // ""' 2>/dev/null)" || newest_evidence=""
        # ...and to a request made AFTER it. The allowance resets and
        # the environment gets created, so asking again once the cause
        # is gone is the normal recovery — a decline that predates the
        # re-ask is spent, not standing.
        if [[ "$refusal_at" > "$newest_evidence" ]] \
           && [[ -z "$request_at" || ! "$request_at" > "$refusal_at" ]]; then
            refusal_current=yes
        fi
    fi

    # A FORMAL re-request also supersedes it — but only one made AFTER
    # the refusal.
    #
    # `requested` is a COUNT and carries no ordering. A request that was
    # already pending when the reviewer declined stays in reviewRequests
    # afterwards, so clearing the refusal on the count alone marks it
    # superseded by the very request it answered, and the command then
    # waits out its whole timeout instead of reporting the decline.
    #
    # That is the same mistake the comment path does NOT make — it
    # compares request_at against refusal_at — reintroduced one line
    # away while fixing the asymmetry between the two ask mechanisms.
    # The ordering has to come from the timeline, because the count
    # cannot supply it.
    #
    # Fetched only when there IS a refusal to supersede AND a request
    # that might do it, so the common path pays nothing.
    if [[ -n "$refusal_at" ]] && (( requested > 0 )); then
        # MATCHED TO A REVIEWER STILL BEING AWAITED, not merely the
        # latest event on the pr.
        #
        # Discarding requestedReviewer made any later request for anyone
        # clear the bot's refusal: under --automated-only the command
        # would go on waiting for a reviewer that had already declined,
        # because a human had since been asked. The identity has to be
        # read and filtered the same way `requested` is — the mode
        # narrows every input to the decision or none of them.
        #
        # And the event has to name someone STILL ON THE REQUEST LIST.
        # The timeline keeps a REVIEW_REQUESTED_EVENT after the request
        # is withdrawn, so a human asked after the decline and then
        # removed without reviewing leaves a later event and no pending
        # request. `pending_others` (below) correctly sees nobody
        # waiting; an unrestricted filter here still took that stale
        # event as a supersession, cleared the refusal, and the command
        # waited out its timeout instead of reporting the decline it had
        # in hand. Requiring the reviewer to be currently pending is
        # what ties the event to a request that can still be answered.
        local formal_at reviewer_filter pending_logins
        pending_logins="$(jq -c '[.reviewRequests[]? | (.login // .slug // "")]' <<<"$meta")"
        reviewer_filter="select(.login as \$l | \$pending | index(\$l))"
        if (( AUTOMATED_ONLY )); then
            reviewer_filter="$reviewer_filter | select(.login as \$l | \$allowed | index(\$l))"
        fi
        # jq RUNS HERE, not inside gh. `--argjson` is a jq option and
        # `gh api` does not accept it: the call failed with "unknown
        # flag" on every real invocation, stderr was suppressed, and
        # formal_at came back empty — so a genuine later request never
        # superseded a refusal. The self-test mock had invented the flag
        # and hidden it completely.
        local formal_raw
        formal_raw="$(gh api graphql -f query="
          { repository(owner: \"${REPO%%/*}\", name: \"${REPO##*/}\") {
              pullRequest(number: $PR) {
                timelineItems(last: 50, itemTypes: [REVIEW_REQUESTED_EVENT]) {
                  nodes { ... on ReviewRequestedEvent { createdAt
                    requestedReviewer {
                      ... on User { login }
                      ... on Bot  { login }
                      ... on Team { login: slug } } } } } } } }" \
          2>/dev/null)" || formal_raw=""
        formal_at="$(jq -r --argjson allowed "$VERDICT_AUTHORS" \
                        --argjson pending "$pending_logins" \
          "[.data.repository.pullRequest.timelineItems.nodes[]
            | {createdAt, login: (.requestedReviewer.login // \"\")}
            | $reviewer_filter | .createdAt] | sort | last // empty" \
          <<<"$formal_raw" 2>/dev/null)" || formal_at=""
        # Unreadable, or no event found: leave the refusal standing. The
        # decline is the thing we actually observed; discarding it on
        # evidence we could not read would trade a fact for a guess.
        [[ -n "$formal_at" && "$formal_at" > "$refusal_at" ]] && refusal_current=no
    fi

    # A DECLINE ANSWERS THE REVIEWER WHO MADE IT, AND NOBODY ELSE.
    #
    # Default mode asks "did anyone independent look", so a human review
    # is coverage. The bot saying its allowance is spent is not an
    # answer about a human who is still on the request list — and the
    # refusal exit fires ahead of `no_review_coming`, which would have
    # kept waiting on that pending request. Without this the command
    # reports "no review is coming" while one is: the confidently-wrong
    # direction again.
    #
    # It must NOT fire under --automated-only. There the mode has
    # already narrowed the question to the recognised reviewer, and a
    # pending human is not an answer to it — suppressing the decline
    # would make the command wait out its timeout for a review that has
    # been declined, which is the case the flag exists to end.
    #
    # The result is a longer wait, not a verdict: with a request still
    # pending, `no_review_coming` cannot fire either, so the command
    # keeps polling until the review lands or the window closes.
    if (( ! AUTOMATED_ONLY )) && (( pending_others > 0 )); then
        refusal_current=no
    fi

    # A request newer than every review, verdict and refusal means one
    # is in flight.
    # AN ASK IS FOR A PARTICULAR HEAD, and the test is whether it
    # postdates that head — NOT whether some review happens to be newer
    # than it.
    #
    # Timestamps alone got this wrong in both directions. A review of an
    # EARLIER commit can land after a newer head was pushed and asked
    # about; counting it as the answer returned "no review is coming"
    # while the real one was still in flight. That is recency mistaken
    # for coverage, the same confusion 8c678d79 fixed for the
    # head-reviewed test itself.
    #
    # Requiring a HEAD-MATCHING review to answer the ask — the obvious
    # repair — breaks the other direction: asked, reviewed, then pushed
    # again without asking. No review will ever match the new head, so
    # the ask would stay pending forever and exit 5 could never fire,
    # which is the one thing it exists to say. The head's own commit
    # date separates the two cleanly, so that is what is compared.
    #
    # Fetched only when there IS an ask, so the common path keeps its
    # three calls.
    request_pending=no
    if [[ -n "$request_at" ]]; then
        # WHEN THE HEAD BECAME THE HEAD, which is not when its commit was
        # written.
        #
        # `.commit.committer.date` is metadata carried inside the commit,
        # so it says nothing about the ref. A cherry-picked, rebased or
        # amended commit keeps a date that can long predate the ask, and
        # even an ordinary one drifts: ba20a29e on #501 was committed at
        # 11:48:37 and pushed at 12:06 — eighteen minutes in which an ask
        # would have been misattributed to a head that did not yet exist
        # on the remote.
        #
        # The check suite is created BY the push, so its timestamp tracks
        # the ref update rather than the commit. `pushedDate` would be
        # the direct answer and GitHub returns null for it (verified on
        # this repo), so this is the closest signal that actually exists.
        #
        # It lands a beat AFTER the true push — CI takes a moment to
        # register — so an ask made in those seconds reads as predating
        # the head and can produce a premature exit 5. That is
        # self-correcting: the answer says to ask again, and the next ask
        # is past the window. The alternative bound, the committer date,
        # fails in the direction that matters more — it makes exit 5
        # unreachable on any rebased head.
        # SCOPED TO THIS PR'S REF, because a check suite belongs to a
        # commit and a commit can appear in more than one place. Both
        # terms are load-bearing.
        #
        # The unfiltered lookup returns every suite the SHA ever had —
        # another branch, an earlier PR, an earlier appearance on this
        # same ref — and taking the oldest then reaches back before this
        # PR's ref update. An ask made in between reads as newer than
        # the head, stays falsely in flight, and the exit-5 callback
        # never fires.
        #
        # `pull_requests` alone is not enough to fix that, because how
        # GitHub populates it is UNDOCUMENTED: the REST reference
        # describes the field's shape and never states the match rule,
        # so "same sha, same repo" cannot be ruled out. Under that rule
        # a suite raised by any branch sharing this sha would carry this
        # PR number, and since a sha really can hold several suites
        # minutes apart — 2d4e1844 here has one at 12:19:33 from the
        # merge-queue ref and one at 12:31:52 from main — the latest of
        # them would date the head from a push this PR never had. That
        # overshoots, and an ask in between then reads as stale: a
        # premature exit 5, the confidently-wrong direction.
        #
        # `head_branch` is the term that does not depend on the unknown
        # rule. A suite raised by a push to this PR's ref carries this
        # PR's branch by construction, and one raised anywhere else
        # cannot, whatever `pull_requests` says. The PR number then
        # still earns its place: a branch can outlive the PR opened from
        # it, so the same ref can carry suites belonging to an earlier
        # one.
        #
        # EARLIEST of this PR's suites, and the direction is the whole
        # point. A sha can acquire a later suite on this same ref, under
        # this same PR number, from something that never moved the ref:
        # a manual `workflow_dispatch` against the branch (this repo has
        # dispatch-only workflows), a schedule, a re-run, or a
        # close/reopen — `reopened` is a default `pull_request` activity
        # type and the bare trigger in ci.yml fires on it. Taking the
        # LATEST dates the head from whichever of those happened last,
        # an ask made before it reads as stale, and a review sitting on
        # an earlier commit turns that into "no review is coming" while
        # the one asked for is in flight. That is the confidently-wrong
        # direction and it is NOT self-correcting: nothing prompts a
        # re-ask.
        #
        # Filtering by what RAISED the suite cannot fix this. The
        # workflow-run listing exposes `.event`, which is
        # `pull_request` for `opened`, `synchronize` AND `reopened`
        # alike — the activity type is not in the API (checked: no
        # `action` field on a run) — so a reopen is indistinguishable
        # from a push by event name. Ordering is the term that does not
        # depend on telling them apart: whatever a later suite was
        # raised by, it is not the push that created the head.
        #
        # Taking the earliest fails only in the safe direction. It can
        # date the head EARLIER than the true ref update (a branch
        # pushed before its PR existed carries no PR number until the PR
        # opens), which makes an ask read as newer than the head and
        # stay in flight — a longer wait, the trade this whole block is
        # written around. It can never date the head later than a
        # candidate suite, which is the failure that produces a false
        # exit 5.
        #
        # This REPLACES the earlier preference for the latest suite,
        # which existed for one case: a sha pushed, replaced, then
        # restored by force-push, where the oldest suite dates the head
        # from the first appearance and an ask made while the
        # intervening head was current stays falsely in flight. That
        # case is rarer than the ones above (no PR in this repo has ever
        # been force-pushed OR reopened; §Always forbids force-pushing
        # without an explicit request), and its failure is the SAFE
        # direction — "stays in flight" is a longer wait, not a verdict.
        # The old choice traded the safe failure for the unsafe one.
        #
        # Suites from `merge_group` or a push to main carry another ref
        # and drop out, which is right. So do ALL of them once the PR
        # is merged and its branch deleted: GitHub empties
        # `pull_requests` then, so
        # a merged PR — which this command deliberately keeps polling —
        # falls through to the commit date below. That is a degradation,
        # not a failure, and it is why the fallback is not optional.
        #
        # The ref is spliced in as a jq-ESCAPED literal, not between
        # bare quotes. `gh api --jq` takes no `--arg`, so the value has
        # to travel inside the filter text, and a branch name is
        # attacker-adjacent input: git permits a `"` in a ref, which
        # would close the string early and leave the rest of the name
        # parsed as jq.
        local head_born head_ref_lit
        head_ref_lit="$(jq -n --arg b "$head_ref" '$b')"
        # PAGINATED, and reduced ACROSS pages. `per_page` defaults to 30
        # on this endpoint and the response is a page, not the set — so
        # `first` over a single request is the earliest of page ONE.
        # Suites are returned oldest-first today, which would make page
        # one the right page by luck; that ordering is not documented,
        # and this block already refuses to depend on an undocumented
        # property of this same endpoint (see the PR-number term above).
        #
        # `gh api --paginate` applies `--jq` to EACH page and prints one
        # result per page, so the filter yields one candidate per page
        # and the reduction has to happen here rather than inside jq.
        #
        # NOT `filter=all`: this endpoint takes no `filter` parameter —
        # its documented query parameters are app_id, check_name,
        # per_page and page, and passing filter=latest, filter=all or a
        # bogus value returns byte-identical results. The per-app
        # collapse `latest` performs belongs to the check-RUNS endpoint;
        # here the bare request returns several suites from the same app.
        head_born="$(gh api --paginate "repos/$REPO/commits/$head/check-suites" \
            --jq "[.check_suites[]
                   | select(.head_branch == $head_ref_lit)
                   | select([.pull_requests[]?.number] | index($PR))
                   | .created_at] | sort | first // empty" \
            2>/dev/null | sort | head -1)" || head_born=""
        # No suite ran, or the lookup failed: fall back to the commit's
        # own date, then to "pending". Both cost a longer wait rather
        # than a false "nothing is coming".
        if [[ -z "$head_born" ]]; then
            head_born="$(gh api "repos/$REPO/commits/$head" \
                --jq '.commit.committer.date' 2>/dev/null)" || head_born=""
        fi
        if [[ -z "$head_born" || "$request_at" > "$head_born" ]]; then
            request_pending=yes
        fi
        # A refusal that arrived after the ask still answers it.
        [[ -n "$refusal_at" && "$refusal_at" > "$request_at" ]] && request_pending=no
        # ...and so does the review it asked for. The exit paths never
        # reach here with a covered head — head_reviewed wins first — so
        # this changes no decision. It changes what the REPORT says, and
        # a line reading "nothing has answered it yet" beside
        # "head reviewed? yes" is simply false. Observed on #501.
        [[ "$head_reviewed" == "yes" ]] && request_pending=no
    fi

    # Only a COMPLETE probe counts. `head` is set before the reviews
    # lookup that may be the thing that fails, so it cannot stand in for
    # "we have readable data" — the fall-out path would otherwise render
    # a zero-coverage report from review globals that were never set, and
    # crash on an unset variable under `set -u`.
    probe_ok=1
    return 0
}

# Nothing is coming. Requires ALL of: a previous independent review (so
# this is not a fresh PR, where review fires on open), a head that has
# moved past it, and no pending request. Any one of those missing and
# waiting is still the right move.
no_review_coming() {
    # A prior VERDICT comment is equally evidence that this PR is one the
    # reviewer answers, so it satisfies the "not a fresh PR" term just as
    # a review object does.
    [[ "$head_reviewed" == "no" ]] \
        && (( qual_count + verdict_count > 0 )) \
        && (( requested == 0 )) \
        && [[ "$request_pending" != "yes" ]]
}

# ── The full report, rendered once ───────────────────────────────────
render() {
    local threads unresolved checks_pass checks_other

    # Unresolved threads no longer gate the merge (the ruleset dropped
    # required_review_thread_resolution on 2026-08-06), so they belong in
    # this glance more than ever — nothing else will raise them.
    threads="$(gh api graphql -f query='
      query($owner:String!,$name:String!,$pr:Int!){
        repository(owner:$owner,name:$name){
          pullRequest(number:$pr){
            reviewThreads(first:100){nodes{isResolved isOutdated path}}}}}' \
      -F owner="${REPO%%/*}" -F name="${REPO##*/}" -F pr="$PR" \
      --jq '[.data.repository.pullRequest.reviewThreads.nodes[]|select(.isResolved==false)]' 2>/dev/null)" \
      || threads='[]'
    unresolved="$(jq 'length' <<<"$threads")"

    checks_pass="$(gh pr checks "$PR" --repo "$REPO" 2>/dev/null | grep -cE '\spass\s' || true)"
    checks_other="$(gh pr checks "$PR" --repo "$REPO" 2>/dev/null | grep -vcE '\spass\s' || true)"

    printf 'PR #%s  state=%s  mergeState=%s  head=%s\n' \
        "$PR" "$state" "$mergest" "${head:0:8}"
    printf '  independent reviews : %s' "$ind_count"
    if (( qual_count > 0 )); then
        printf '   (newest against %s)' "${newest_ind_commit:0:8}"
    fi
    if (( AUTOMATED_ONLY )) && (( ind_count > qual_count )); then
        printf '   [%s of them not the automated reviewer — NOT counted]' \
            "$(( ind_count - qual_count ))"
    fi
    printf '\n'
    if (( ind_count > 0 )); then
        jq -r '.[] | "      - \(.user.login)  \(.state)  commit=\(.commit_id[0:8])  \(.submitted_at)"' \
            <<<"$independent"
    fi
    printf '  verdict comments    : %s' "$verdict_count"
    if (( verdict_count > 0 )); then
        printf '   (a clean review leaves no review object)'
    fi
    printf '\n'
    if (( verdict_count > 0 )); then
        jq -r '.[] | "      - \(.login)  commit=\(.sha[0:8])  \(.at)"' <<<"$verdicts"
    fi
    printf '  substitute reviews  : %s%s\n' "$substitute_count" \
        "$( (( substitute_count > 0 )) \
              && echo '   (blind agent standing in — counts as coverage, not a real review)' \
              || echo '' )"
    if (( substitute_count > 0 )); then
        jq -r '.[] | "      - commit=\(.commit_id[0:8])  \(.submitted_at)"' <<<"$substitute"
    fi
    printf '  self reviews        : %s   (thread replies etc. — not coverage)\n' "$self_count"
    printf '  review requested?   : %s\n' "$( (( requested > 0 )) && echo yes || echo no )"
    if [[ -n "$request_at" ]]; then
        printf '  @codex review asked : %s%s\n' "$request_at" \
            "$( [[ "$request_pending" == "yes" ]] \
                  && echo '   (in flight — nothing has answered it yet)' \
                  || echo '   (already answered)' )"
    fi
    if [[ -n "$refusal_at" ]]; then
        printf '  reviewer declined   : %s%s\n' "$refusal_at" \
            "$( [[ "$refusal_current" == "yes" ]] \
                  && echo "   (nothing has superseded it)" \
                  || echo "   (superseded by later coverage)" )"
        [[ -z "$refusal_reason" ]] || printf '  decline reason      : %s\n' "$refusal_reason"
    fi
    printf '  head reviewed?      : %s%s\n' "$head_reviewed" \
        "$( (( AUTOMATED_ONLY )) && echo '   (--automated-only: the recognised reviewer, not just anyone)' )"
    if [[ "$head_reviewed" == "no" && "$qual_count" -gt 0 ]]; then
        printf '                        ^ reviewed, but an EARLIER commit. Pushes do not\n'
        printf '                          re-trigger automated review — request it explicitly.\n'
    fi
    printf '  unresolved threads  : %s\n' "$unresolved"
    if (( unresolved > 0 )); then
        jq -r '.[] | "      - \(.path)  outdated=\(.isOutdated)"' <<<"$threads"
    fi
    printf '  checks              : %s pass, %s other\n' "$checks_pass" "$checks_other"
}

# ── Poll ─────────────────────────────────────────────────────────────
#
# A single failed lookup is a blip, not a verdict; only a run of them
# means the PR is genuinely unreadable. Same tolerance as wait-merged.sh.
consecutive_failures=0
deadline=$(( SECONDS + WAIT ))

while :; do
    if probe; then
        consecutive_failures=0

        if [[ "$head_reviewed" == "yes" ]]; then
            render; exit 0
        fi

        # TERMINAL STATE FIRST. A PR closed without merging will receive
        # nothing further. A MERGED one still can, and routinely does
        # here — that is the whole reason the post-merge sweep exists —
        # so it keeps waiting.
        if [[ "$state" == "CLOSED" ]]; then
            render; exit 1
        fi

        # ...which is why exit 5 is restricted to an OPEN pr. Run before
        # the state check, no_review_coming fires on a MERGED pr whose
        # only review predates the last push, and tells the caller to go
        # request one — contradicting the merged-pr exception written
        # directly above it, and sending them away from the sweep that
        # was about to deliver a review.
        #
        # Not hypothetical: an `@codex review` comment on merged #460 was
        # acknowledged in 40 seconds (2026-08-13), so a merged pr here is
        # a perfectly ordinary thing to be waiting on.
        # A REFUSAL is the same verdict from a different cause, so it
        # takes the same exit — which is exactly why it must be tested
        # FIRST. Both conditions are true together whenever an older
        # review sits on a previous head and the reviewer has since
        # declined: no_review_coming fires on the stale review, and the
        # caller is told to request another one. That advice cannot work
        # while the reviewer is refusing, and naming the real cause is
        # the whole point of this branch.
        #
        # Still after the coverage and terminal tests above: a covered
        # head reports 0, and a refusal a later review superseded is
        # already excluded by refusal_current.
        #
        # Gated on OPEN for the same reason the test below is: a merged
        # pr keeps waiting, and the sweep that reviews it runs long
        # after any allowance has reset.
        if [[ "$state" == "OPEN" && "$refusal_current" == "yes" ]]; then
            note "the reviewer declined this PR — no review will arrive without a change"
            render
            printf 'PR #%s NO REVIEW COMING — the reviewer declined%s (exit 5)\n' "$PR" \
                "$( [[ -z "$refusal_reason" ]] || printf ': %s' "${refusal_reason%% —*}" )"
            exit 5
        fi

        if [[ "$state" == "OPEN" ]] && no_review_coming; then
            note "head has advanced past the newest review and none is requested"
            render
            printf 'PR #%s NO REVIEW COMING — request one; waiting cannot help (exit 5)\n' "$PR"
            exit 5
        fi
    else
        consecutive_failures=$(( consecutive_failures + 1 ))
        (( consecutive_failures >= 3 )) && die "could not read PR #$PR in $REPO."
        note "could not read PR #$PR (attempt $consecutive_failures); retrying"
    fi

    (( WAIT > 0 )) || break
    # Clamp the nap to what is left, exactly as wait-merged.sh does.
    # Breaking whenever a WHOLE interval no longer fits made `--wait`
    # mean "the last deadline a full interval lands on": `--wait 10s`
    # against the default 30s interval polled once and exited on the
    # spot, and any wait that is not a multiple of the interval ended up
    # to one interval early. The deadline is the deadline.
    remaining=$(( deadline - SECONDS ))
    (( remaining > 0 )) || break
    nap=$(( INTERVAL < remaining ? INTERVAL : remaining ))
    note "no independent review of ${head:0:8} yet; next check in ${nap}s"
    sleep "$nap"
done

# Fell out: either one-shot, or the wait expired with nothing. Requires a
# probe that COMPLETED — `head` alone is not enough, because it is set
# before the reviews lookup that may be the thing that failed.
if (( probe_ok == 0 )) || [[ -z "${head:-}" ]]; then
    die "could not read PR #$PR in $REPO."
fi
render
exit 1
