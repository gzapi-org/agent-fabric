#!/usr/bin/env bash
# tools/gh/test_pr-reply.sh
#
# Behavioural tests for pr-reply.sh.
#
# Three things this script promises, each of which is unrecoverable if
# it is wrong — a posted reply cannot be unsent:
#
#   1. the body reaches GitHub byte-for-byte, with no shell expansion
#      (the defect the script exists to remove: a reply lost the name of
#      the guard it described because a backtick was command-substituted
#      on its way through a double-quoted argument)
#   2. another session's PR is refused
#   3. a thread is never resolved unless the reply actually landed
#
# The mock `gh` records the exact argv it was handed, so assertion 1 is
# about what would have been transmitted rather than about what the
# script believed it sent.
#
# Exit codes:
#   0  all assertions passed
#   1  one or more assertions failed

set -uo pipefail

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" && pwd )"
UNDER_TEST="$SCRIPT_DIR/pr-reply.sh"

[[ -f "$UNDER_TEST" ]] || { echo "test: $UNDER_TEST not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "test: jq required" >&2; exit 1; }

failures=0
SANDBOX=""
NOGIT=""
STRIP=""
cleanup() {
    [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
    [[ -n "$NOGIT"   && -d "$NOGIT"   ]] && rm -rf "$NOGIT"
    [[ -n "$STRIP"   && -d "$STRIP"   ]] && rm -rf "$STRIP"
    [[ -n "${GUARD_MARKER:-}" ]] && rm -f "$GUARD_MARKER"
    return 0
}
trap cleanup EXIT

CLONE_NAME="gzapp-testclone"
ME="$(hostname -s)/$CLONE_NAME"
OTHER="$(hostname -s)/gzapp-otherclone"

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1" >&2; printf '%s\n' "${2:-}" | sed 's/^/      /' >&2
         failures=$((failures + 1)); }

assert_rc() {
    local label="$1" want="$2"
    if [[ "$RUN_RC" -eq "$want" ]]; then pass "$label"
    else fail "$label — expected exit $want, got $RUN_RC" "$RUN_OUT"; fi
}
assert_contains() {
    if [[ "$RUN_OUT" == *"$2"* ]]; then pass "$1"
    else fail "$1 — output lacked '$2'" "$RUN_OUT"; fi
}
assert_not_contains() {
    if [[ "$RUN_OUT" != *"$2"* ]]; then pass "$1"
    else fail "$1 — output unexpectedly had '$2'" "$RUN_OUT"; fi
}

# A MISTYPED HELPER MUST FAIL THE SUITE, not vanish into stderr.
#
# An assertion calling a function nobody defined prints "command not
# found", never touches the failure counter, and leaves the suite
# reporting success with that case vacuous — a guard claiming coverage
# it does not have, in a file whose whole job is stopping exactly that.
# It has happened twice here: test_pr-review-status.sh's merged-pr case
# called `ok`/`bad` and ran for weeks doing nothing, and its verdict
# cases were written with `assert_not_contains` where this file's
# helpers are named otherwise.
#
# Every suite needs this, not just the one that was bitten: the helpers
# are NOT named alike across these files — two spell it `assert_lacks`,
# two `assert_not_contains` — so anyone moving between them types the
# wrong name eventually.
#
# THE MARKER FILE IS THE MECHANISM, and a counter is not. Bash runs
# `command_not_found_handle` in a SUBSHELL, so `failures=$((failures+1))`
# inside it is discarded when that subshell exits: the handler prints its
# complaint and the suite still reports "all assertions passed" and exits
# 0. The first version of this guard did exactly that — a vacuous guard
# against vacuous guards. A file written in the subshell survives it.
#
# The script under test runs as a separate `bash` process, so none of
# this reaches it or masks a genuine missing-command path there.
GUARD_MARKER="$(mktemp)"
command_not_found_handle() {
    printf '%s\n' "$1" >> "$GUARD_MARKER"
    echo "  ✗ self-test bug: called '$1', which is not defined here" >&2
    echo "      the assertion helpers here are assert_rc / assert_contains / assert_not_contains" >&2
    return 127
}

setup_sandbox() {
    SANDBOX="$(mktemp -d)"
    mkdir -p "$SANDBOX/$CLONE_NAME" "$SANDBOX/bin" "$SANDBOX/state"
    git -C "$SANDBOX/$CLONE_NAME" init -q 2>/dev/null

    cat > "$SANDBOX/bin/gh" <<'MOCK'
#!/usr/bin/env bash
# Mock gh: records each graphql call's operation and body, and answers
# from the fixtures the case set up.
set -uo pipefail

# `gh repo view` — what the script asks to learn which repo it is in.
# Answered before the graphql parsing below, because it takes no -f flags.
if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
  echo "REPOVIEW" >> "$GH_MOCK_STATE/calls"
  [[ -n "${GH_MOCK_REPO_FAIL:-}" ]] && exit 1
  echo "${GH_MOCK_HERE_REPO:-gzapi-org/gzapp}"
  exit 0
fi

query=""; id=""; body=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f) case "$2" in
          query=*) query="${2#query=}" ;;
          id=*)    id="${2#id=}" ;;
          body=*)  body="${2#body=}" ;;
        esac
        shift 2 ;;
    *) shift ;;
  esac
done

if [[ "$query" == *"PullRequestReviewThread"* && "$query" != *mutation* ]]; then
  echo "READ $id" >> "$GH_MOCK_STATE/calls"
  [[ -n "${GH_MOCK_READ_FAIL:-}" ]] && exit 1
  cat "$GH_MOCK_STATE/thread.json"
  exit 0
fi

if [[ "$query" == *addPullRequestReviewThreadReply* ]]; then
  echo "REPLY $id" >> "$GH_MOCK_STATE/calls"
  printf '%s' "$body" > "$GH_MOCK_STATE/body.txt"
  [[ -n "${GH_MOCK_REPLY_FAIL:-}" ]] && exit 1
  [[ -n "${GH_MOCK_REPLY_EMPTY:-}" ]] && { echo ""; exit 0; }
  echo "https://github.com/o/r/pull/1#discussion_r1"
  exit 0
fi

if [[ "$query" == *resolveReviewThread* ]]; then
  echo "RESOLVE $id" >> "$GH_MOCK_STATE/calls"
  [[ -n "${GH_MOCK_RESOLVE_FAIL:-}" ]] && exit 1
  echo "true"
  exit 0
fi

echo "mock gh: unhandled query" >&2; exit 1
MOCK
    chmod +x "$SANDBOX/bin/gh"
}

# Writes the thread fixture. $1 = branch, $2 = isResolved.
# Writes the thread fixture. $1 = branch, $2 = isResolved, $3 = the repo
# the thread belongs to (defaults to the one the mock says we are in).
thread_fixture() {
    jq -n --arg branch "$1" --argjson resolved "$2" \
          --arg repo "${3:-gzapi-org/gzapp}" '{
      isResolved: $resolved, path: "lib/x.dart", line: 12,
      pullRequest: {number: 77, state: "MERGED", headRefName: $branch,
                    repository: {nameWithOwner: $repo}},
      comments: {nodes: [{author: {login: "some-reviewer"}}]}
    }' > "$SANDBOX/state/thread.json"
    : > "$SANDBOX/state/calls"
    rm -f "$SANDBOX/state/body.txt"
}

# Runs the script with the given stdin body and arguments.
invoke() {
    local body="$1"; shift
    RUN_OUT="$(cd "$SANDBOX/$CLONE_NAME" && printf '%s' "$body" | \
        env PATH="$SANDBOX/bin:$PATH" GH_MOCK_STATE="$SANDBOX/state" \
        "${MOCK_ENV[@]}" bash "$UNDER_TEST" "$@" 2>&1)"
    RUN_RC=$?
}

MOCK_ENV=(env)

calls() { cat "$SANDBOX/state/calls" 2>/dev/null; }

setup_sandbox
THREAD_ID="PRRT_kwDOtest123"

echo "pr-reply: the happy path"
thread_fixture "$ME/feat/thing" false
invoke "Fixed in #123." "$THREAD_ID"
assert_rc       "exits 0" 0
assert_contains "reports the reply URL" "discussion_r1"
assert_contains "reports the resolve"   "resolved: #77"
# REPOVIEW sits between the read and the reply: the repository check runs
# on the thread it just read, and must happen BEFORE anything is written.
if [[ "$(calls)" == "READ $THREAD_ID
REPOVIEW
REPLY $THREAD_ID
RESOLVE $THREAD_ID" ]]; then
    pass "read, check the repo, then reply, then resolve — in that order"
else
    fail "call order wrong" "$(calls)"
fi

echo "pr-reply: a trailing blank line survives to GitHub"
# `BODY="$(cat)"` strips ALL trailing newlines, so the blank line a
# documented heredoc ends with was silently dropped — while this script
# exists precisely to deliver the body byte-for-byte, which is why it reads
# stdin instead of taking an argument.
#
# Compared with cmp, never `$( )`: reading the capture back through command
# substitution would strip the exact bytes under test, which is how the
# suite stayed green over this. The existing helper pipes with
# `printf '%s'`, so it never had a trailing newline to lose either.
printf 'line one\n\n' > "$SANDBOX/state/expected.txt"
thread_fixture "$ME/feat/thing" false
RUN_OUT="$(cd "$SANDBOX/$CLONE_NAME" && \
    env PATH="$SANDBOX/bin:$PATH" GH_MOCK_STATE="$SANDBOX/state" \
    "${MOCK_ENV[@]}" bash "$UNDER_TEST" "$THREAD_ID" \
    < "$SANDBOX/state/expected.txt" 2>&1)"
RUN_RC=$?
assert_rc "exits 0" 0
if cmp -s "$SANDBOX/state/body.txt" "$SANDBOX/state/expected.txt"; then
    pass "the trailing blank line reached GitHub intact"
else
    fail "trailing bytes were lost in transit" \
        "sent:$(od -c "$SANDBOX/state/body.txt" 2>/dev/null | tail -2)
want:$(od -c "$SANDBOX/state/expected.txt" | tail -2)"
fi

echo "pr-reply: the body is transmitted verbatim"
# The defect this script exists to remove. Every one of these is
# something the shell would have eaten from a double-quoted argument.
BODY='Fixed: the `need_operand` guard and $LIMIT — see $(date) and "quotes" \back.'
thread_fixture "$ME/feat/thing" false
invoke "$BODY" "$THREAD_ID"
assert_rc "exits 0" 0
sent="$(cat "$SANDBOX/state/body.txt" 2>/dev/null || echo MISSING)"
if [[ "$sent" == "$BODY" ]]; then
    pass "backticks, \$vars, \$( ), quotes and backslashes survive intact"
else
    fail "the body was mangled in transit" "sent: $sent
want: $BODY"
fi

echo "pr-reply: --no-resolve replies without claiming the finding is handled"
thread_fixture "$ME/feat/thing" false
invoke "Real, but the contract has to change first." "$THREAD_ID" --no-resolve
assert_rc           "exits 0" 0
assert_contains     "says it left the thread open" "left open"
assert_not_contains "did not resolve"              "resolved: #77"
if [[ "$(calls)" != *RESOLVE* ]]; then
    pass "no resolve mutation was sent"
else
    fail "resolved despite --no-resolve" "$(calls)"
fi

echo "pr-reply: another session's PR is refused"
thread_fixture "$OTHER/fix/theirs" false
invoke "I would like to answer this." "$THREAD_ID"
assert_rc       "exits 2" 2
assert_contains "names the owning session" "$OTHER"
assert_contains "explains why not"         "cannot be unsent"
if [[ "$(calls)" != *REPLY* ]]; then
    pass "nothing was posted"
else
    fail "posted to another session's PR" "$(calls)"
fi

echo "pr-reply: a branch naming no session is answered, not refused as a rival's"
# The guard took the first two segments of ANY branch and compared, so
# `dependabot/pub`, `agent/global-event-identity` and a slashless
# `add-claude-github-actions-178...` each read as another session — and
# the refusal claimed that session was "mid-flight on a fix you cannot
# see" about something that does not exist. Nobody owned those PRs and
# nobody could answer them: four held seven unresolved findings for a
# month.
for branch in "dependabot/pub/apps/driver_flutter/flutter-minor-patch-7a91" \
              "agent/global-event-identity" \
              "add-claude-github-actions-1785994932117" \
              "feat/brand-logos"; do
    thread_fixture "$branch" false
    invoke "Obsolete — the file was deleted before this landed." "$THREAD_ID"
    if [[ "$RUN_RC" -eq 0 && "$(calls)" == *REPLY* ]]; then
        pass "answers '$branch'"
    else
        fail "refused an unowned branch: '$branch'" "rc=$RUN_RC $(calls)"
    fi
done

echo "pr-reply: a retired clone's PR goes to its successor, or to nobody"
# A retired clone's prefix still PARSES as a session, so it read as a live
# rival and was refused -- and it appeared in no sweep either. The registry
# decides: a clone whose every window is closed is retired, and the clone
# holding an OPEN window for the same role inherits it.
HOST="$(hostname -s)"
OTHER_CLONE="${OTHER#*/}"
BINDINGS="$SANDBOX/state/bindings.jsonl"
mk_bindings() {
    : > "$BINDINGS"
    # retired, same role as this clone -> inherited by ME
    jq -nc --arg h "$HOST" '{clone_id:"c1", dir_basename:"gzapp-old", host:$h,
        role:"architect-cto", valid_to:"2026-09-05T00:00:00Z"}' >> "$BINDINGS"
    jq -nc --arg h "$HOST" --arg d "$CLONE_NAME" '{clone_id:"c2", dir_basename:$d,
        host:$h, role:"architect-cto", valid_to:null}' >> "$BINDINGS"
    # retired, no live holder of its role -> nobody's
    jq -nc --arg h "$HOST" '{clone_id:"c3", dir_basename:"gzapp-orphan", host:$h,
        role:"domain-transit", valid_to:"2026-09-01T00:00:00Z"}' >> "$BINDINGS"
    # retired, role held by ANOTHER live clone -> theirs
    jq -nc --arg h "$HOST" '{clone_id:"c4", dir_basename:"gzapp-theirs", host:$h,
        role:"web-dev", valid_to:"2026-09-01T00:00:00Z"}' >> "$BINDINGS"
    jq -nc --arg h "$HOST" --arg d "$OTHER_CLONE" '{clone_id:"c5", dir_basename:$d,
        host:$h, role:"web-dev", valid_to:null}' >> "$BINDINGS"
    # a clone with an OPEN window is NOT retired, whatever else is true
    jq -nc --arg h "$HOST" '{clone_id:"c6", dir_basename:"gzapp-stillhere", host:$h,
        role:"backend-dev", valid_to:null}' >> "$BINDINGS"
    # PRE-ROLES RENAME: closed, carries NO role at all, and shares c2 with
    # this clone's live row -- one working copy under two names. Role
    # matching cannot reach it; clone_id continuity can. Real instance:
    # gzapp-claude3, seeded 2026-06-19 with reason "initial" and no role.
    jq -nc --arg h "$HOST" '{clone_id:"c2", dir_basename:"gzapp-preroles",
        host:$h, valid_to:"2026-09-06T00:00:00Z"}' >> "$BINDINGS"
    # AMBIGUOUS: retired backend-dev with TWO live holders (c6 above and c9
    # here), which must resolve to nobody rather than to whichever sorts
    # first. backend-dev-01 and backend-dev-02 are the real pair.
    jq -nc --arg h "$HOST" '{clone_id:"c8", dir_basename:"gzapp-ambig", host:$h,
        role:"backend-dev", valid_to:"2026-09-01T00:00:00Z"}' >> "$BINDINGS"
    jq -nc --arg h "$HOST" '{clone_id:"c9", dir_basename:"gzapp-second-backend",
        host:$h, role:"backend-dev", valid_to:null}' >> "$BINDINGS"
    # HOST-MOVE that keeps the directory name. The clone key is the PAIR
    # (host, dir_basename), so excluding only the NAME from the chain made
    # a clone unable to claim its own PRs after moving host -- it saw
    # itself as already excluded and reported nobody. `host-move` is a
    # first-class `reason` in bindings.schema.json.
    jq -nc '{clone_id:"cm", dir_basename:"gzapp-moved", host:"otherhost-far",
        role:"edge-hosting", valid_to:"2026-09-01T00:00:00Z",
        reason:"host-move"}' >> "$BINDINGS"
    jq -nc --arg h "$HOST" '{clone_id:"cm", dir_basename:"gzapp-moved", host:$h,
        role:"edge-hosting", valid_to:null, reason:"host-move"}' >> "$BINDINGS"
    # BOTH routes available at once: a clone_id chain to one clone, and a
    # single role heir to THIS one. Pins the ORDERING -- clone_id is exact,
    # role is an inference, so the exact one must win. Without this,
    # swapping the two rules left both suites green.
    jq -nc --arg h "$HOST" '{clone_id:"co", dir_basename:"gzapp-both", host:$h,
        role:"product-i18n", valid_to:"2026-09-01T00:00:00Z"}' >> "$BINDINGS"
    jq -nc --arg h "$HOST" '{clone_id:"co", dir_basename:"gzapp-chain-heir",
        host:$h, valid_to:null}' >> "$BINDINGS"
    jq -nc --arg h "$HOST" --arg d "$CLONE_NAME" '{clone_id:"cz", dir_basename:$d,
        host:$h, role:"product-i18n", valid_to:null}' >> "$BINDINGS"
}
mk_bindings
MOCK_ENV=(env "GZAPP_CLONE_BINDINGS=$BINDINGS")

thread_fixture "$HOST/gzapp-old/fix/inherited" false
invoke "Verified against main; obsolete." "$THREAD_ID"
assert_rc       "inherited: exits 0" 0
assert_contains "inherited: names the succession, not a role" "which this clone succeeds"
assert_contains "inherited: the override is announced" "clone registry overridden"
if [[ "$(calls)" == *REPLY* && "$(calls)" == *RESOLVE* ]]; then
    pass "inherited: replied AND resolved, as its own"
else
    fail "inherited: expected reply and resolve" "$(calls)"
fi

thread_fixture "$HOST/gzapp-orphan/fix/nobody" false
invoke "Verified against main; obsolete." "$THREAD_ID"
assert_rc       "orphan: exits 0" 0
assert_contains "orphan: names the gap" "no live clone succeeds it"
if [[ "$(calls)" == *REPLY* && "$(calls)" != *RESOLVE* ]]; then
    pass "orphan: replied but left OPEN by default"
else
    fail "orphan: expected reply without resolve" "$(calls)"
fi

thread_fixture "$HOST/gzapp-theirs/fix/inherited-by-other" false
invoke "I would like to answer this." "$THREAD_ID"
assert_rc       "inherited by another: exits 2" 2
assert_contains "inherited by another: names the heir" "$OTHER"
if [[ "$(calls)" != *REPLY* ]]; then
    pass "inherited by another: nothing was posted"
else
    fail "inherited by another: posted to a live session's PR" "$(calls)"
fi

# An OPEN window means live, so the old refusal stands.
thread_fixture "$HOST/gzapp-stillhere/fix/theirs" false
invoke "I would like to answer this." "$THREAD_ID"
assert_rc "a clone with an open window is still refused" 2

# A roleless retired row resolves through clone_id, which is the only rule
# that can reach the clones seeded before roles existed.
thread_fixture "$HOST/gzapp-preroles/fix/renamed" false
invoke "Answering my predecessor's thread." "$THREAD_ID"
assert_rc       "pre-roles rename: exits 0" 0
assert_contains "pre-roles rename: claimed via the succession path" "which this clone succeeds"
if [[ "$(calls)" == *REPLY* && "$(calls)" == *RESOLVE* ]]; then
    pass "pre-roles rename: replied AND resolved, as its own"
else
    fail "pre-roles rename: expected reply and resolve" "$(calls)"
fi

# Two live holders of one role must NOT silently elect a winner: doing so
# lets the wrong session reply and refuses the right one.
thread_fixture "$HOST/gzapp-ambig/fix/two-heirs" false
invoke "Verified against main; obsolete." "$THREAD_ID"
assert_rc       "ambiguous heir: exits 0 on the unowned path" 0
assert_contains "ambiguous heir: says TWO could be, not none" "MORE THAN ONE live"
if [[ "$(calls)" == *REPLY* && "$(calls)" != *RESOLVE* ]]; then
    pass "ambiguous heir: replied but left OPEN, like any unowned PR"
else
    fail "ambiguous heir: expected reply without resolve" "$(calls)"
fi

# A host-move that keeps the directory name is still the same clone.
thread_fixture "otherhost-far/gzapp-moved/fix/moved" false
invoke "I would like to answer this." "$THREAD_ID"
assert_rc       "host-move: exits 2, the heir is another clone" 2
assert_contains "host-move: names the moved clone as the heir" "$HOST/gzapp-moved"

# clone_id is exact and role is an inference, so clone_id must win when
# both are available. If the order flips, this clone claims the PR instead.
thread_fixture "$HOST/gzapp-both/fix/ordering" false
invoke "I would like to answer this." "$THREAD_ID"
assert_rc       "ordering: exits 2 because the CHAIN heir is not me" 2
assert_contains "ordering: the clone_id heir wins over the role heir" "gzapp-chain-heir"
if [[ "$(calls)" != *REPLY* ]]; then
    pass "ordering: nothing posted to the chain heir's PR"
else
    fail "ordering: role fallback beat the clone_id chain" "$(calls)"
fi

# CONTROLS. The registry is what changes the verdict, and everything the
# registry does not positively call retired must FAIL CLOSED.
MOCK_ENV=(env "GZAPP_CLONE_BINDINGS=$SANDBOX/state/no-such-registry.jsonl")
thread_fixture "$HOST/gzapp-old/fix/inherited" false
invoke "Verified against main; obsolete." "$THREAD_ID"
assert_rc "control: with no registry, the retired prefix is refused" 2

printf 'not json at all\n' > "$SANDBOX/state/broken.jsonl"
MOCK_ENV=(env "GZAPP_CLONE_BINDINGS=$SANDBOX/state/broken.jsonl")
thread_fixture "$HOST/gzapp-old/fix/inherited" false
invoke "Verified against main; obsolete." "$THREAD_ID"
assert_rc "control: an unparseable registry fails CLOSED, not open" 2

MOCK_ENV=(env)

echo "pr-reply: an unowned PR still warns before it replies"
# Allowed is not the same as unremarkable — the finding may belong to a
# surface whose role has verified nothing.
thread_fixture "agent/global-event-identity" false
invoke "Verified fixed." "$THREAD_ID"
assert_rc       "exits 0" 0
assert_contains "says the branch names no session" "names no session"
assert_contains "warns about the owning surface"   "another SURFACE's"
assert_contains "  and bounds what may be resolved" "left OPEN"
assert_not_contains "does not invent a rival session" "mid-flight"

echo "pr-reply: a bot branch is unowned, not a session called after the bot"
# `dependabot/pub` has the right SHAPE for a session prefix, so only the
# vendor deny-list separates it from a real one. Without that this case
# would refuse, naming "dependabot/pub" as the session to defer to.
thread_fixture "dependabot/nuget/apps/backend_dotnet/dotnet-minor-patch-04e2" false
invoke "Answered." "$THREAD_ID"
assert_rc           "exits 0" 0
assert_not_contains "never names the bot as a session" "belongs to 'dependabot"

echo "pr-reply: a real session's PR is STILL refused"
# The whole point of relaxing the guard is that it must not relax for
# the case it exists for. A four-segment, non-bot, well-typed branch
# belonging to someone else stays refused.
thread_fixture "$OTHER/fix/theirs" false
invoke "I would like to answer this." "$THREAD_ID"
assert_rc       "exits 2" 2
assert_contains "still names the owning session" "$OTHER"
if [[ "$(calls)" != *REPLY* ]]; then
    pass "still posts nothing"
else
    fail "relaxation leaked into the owned case" "$(calls)"
fi

echo "pr-reply: an odd <type> segment is a session, not an unowned branch"
# pr-sessions.sh imposes no vocabulary on <type> — `spike-3`, `hotfix`
# and `stage-4` are sessions. If this script disagreed, another
# session's PR on such a branch would read as unowned and be ANSWERED,
# which is the failure the guard exists to prevent, reached from the
# other side.
for t in spike-3 hotfix stage-4; do
    thread_fixture "$OTHER/$t/theirs" false
    invoke "no" "$THREAD_ID"
    if [[ "$RUN_RC" -eq 2 && "$(calls)" != *REPLY* ]]; then
        pass "refuses another session's '$t/' branch"
    else
        fail "answered another session's '$t/' branch" "rc=$RUN_RC $(calls)"
    fi
done

echo "pr-reply: an unowned branch is answered but NOT resolved by default"
# The warning used to say "resolve only what you actually verified" and
# then resolve in the same run — the operator read the precondition after
# it had already been violated. Resolving is a claim, and this is the
# path with the least standing to make it.
thread_fixture "agent/global-event-identity" false
invoke "Looks addressed, but I have not verified it." "$THREAD_ID"
assert_rc       "still replies" 0
if [[ "$(calls)" == *REPLY* ]]; then pass "the reply was posted"
else fail "no reply posted" "$(calls)"; fi
if [[ "$(calls)" != *RESOLVE* ]]; then pass "the thread was left OPEN"
else fail "resolved an unowned thread by default" "$(calls)"; fi
assert_contains "says it is leaving it open" "left OPEN"
assert_contains "names the opt-in flag"      "--resolve"

echo "pr-reply: --resolve is the opt-in on an unowned branch"
thread_fixture "agent/global-event-identity" false
invoke "Verified fixed in abc1234." "$THREAD_ID" --resolve
assert_rc "exits 0" 0
if [[ "$(calls)" == *RESOLVE* ]]; then pass "resolves when explicitly asked"
else fail "--resolve was ignored" "$(calls)"; fi

echo "pr-reply: an OWNED branch still resolves by default"
# The inversion above must be scoped to the unowned path only.
thread_fixture "$ME/feat/mine" false
invoke "Fixed." "$THREAD_ID"
assert_rc "exits 0" 0
if [[ "$(calls)" == *RESOLVE* ]]; then pass "own PR still resolves by default"
else fail "the unowned default leaked into an owned PR" "$(calls)"; fi

echo "pr-reply: an UNUSUAL <type> is still another session's branch"
# This case previously asserted the opposite, and the opposite was a
# hole. CLAUDE.md imposes no vocabulary on <type>, so a lowercase shape
# test is a permission decision resting on an open-ended set: every
# branch below belongs to a real parallel session, and a shape test
# calls each of them unowned — i.e. POST AND RESOLVE on somebody else's
# PR, which cannot be undone. The guard must refuse on the SPECIFIED
# shape (four segments, non-empty host/clone, non-vendor) and nothing
# more.
for t in "Fix" "chore(gh)" "WIP" "2fix" "-lead" "FEAT" "spike-3" "hotfix"; do
    thread_fixture "$OTHER/$t/x" false
    invoke "I must not be able to post this." "$THREAD_ID"
    if [[ "$RUN_RC" -eq 2 && "$(calls)" != *REPLY* ]]; then
        pass "refuses another session's '$t/' branch"
    else
        fail "WROTE to another session's '$t/' branch" "rc=$RUN_RC $(calls)"
    fi
done

echo "pr-reply: removing the type test did not make the orphans unreachable"
# The shape test bought nothing it was credited with: every branch this
# relaxation exists to answer is unowned by segment count or by the
# vendor deny-list, never by <type>. If that stops being true the four
# cases below start failing rather than silently narrowing.
for branch in "dependabot/pub/apps/driver_flutter/flutter-minor-patch-7a91" \
              "add-claude-github-actions-1785994932117" \
              "agent/global-event-identity" \
              "agent/common-api-idempotency"; do
    thread_fixture "$branch" false
    invoke "Obsolete." "$THREAD_ID"
    if [[ "$RUN_RC" -eq 0 && "$(calls)" == *REPLY* ]]; then
        pass "still answers '$branch'"
    else
        fail "orphan became unanswerable: '$branch'" "rc=$RUN_RC $(calls)"
    fi
done

echo "pr-reply: a failed reply never resolves the thread"
# The worst available outcome is a resolved thread with no reply: it
# reads as answered and shows nothing.
thread_fixture "$ME/feat/thing" false
MOCK_ENV=(env GH_MOCK_REPLY_FAIL=1)
invoke "…" "$THREAD_ID"
MOCK_ENV=(env)
assert_rc       "exits 2" 2
assert_contains "says the reply was rejected" "rejected"
if [[ "$(calls)" != *RESOLVE* ]]; then
    pass "the thread was left open"
else
    fail "resolved after a failed reply" "$(calls)"
fi

echo "pr-reply: a reply with no URL is treated as not posted"
thread_fixture "$ME/feat/thing" false
MOCK_ENV=(env GH_MOCK_REPLY_EMPTY=1)
invoke "…" "$THREAD_ID"
MOCK_ENV=(env)
assert_rc       "exits 2" 2
assert_contains "says so plainly" "did not post"

echo "pr-reply: a failed resolve is reported, not swallowed"
thread_fixture "$ME/feat/thing" false
MOCK_ENV=(env GH_MOCK_RESOLVE_FAIL=1)
invoke "Fixed." "$THREAD_ID"
MOCK_ENV=(env)
assert_rc       "exits 2" 2
assert_contains "says the reply landed"      "replied:"
assert_contains "and that the thread is open" "still open"

echo "pr-reply: an already-resolved thread is not re-resolved"
thread_fixture "$ME/feat/thing" true
invoke "One more note." "$THREAD_ID"
assert_rc       "exits 0" 0
assert_contains "says it is already resolved" "already resolved"
if [[ "$(calls)" != *RESOLVE* ]]; then
    pass "no resolve mutation was sent"
else
    fail "re-resolved" "$(calls)"
fi

echo "pr-reply: invocation errors"
thread_fixture "$ME/feat/thing" false
invoke "body" "PRRC_notathread"
assert_rc       "a comment id is refused" 2
assert_contains "explains the difference" "PRRC_ is a comment"

invoke "body" "not-an-id"
assert_rc       "a malformed id is refused" 2

invoke "" "$THREAD_ID"
assert_rc       "an empty body is refused" 2
assert_contains "says the body is empty" "empty"

invoke "   " "$THREAD_ID"
assert_rc       "a whitespace-only body is refused" 2

invoke "body"
assert_rc       "a missing thread id is refused" 2

invoke "body" "$THREAD_ID" "PRRT_second"
assert_rc       "two thread ids are refused" 2

invoke "body" "$THREAD_ID" --nope
assert_rc       "an unknown option is refused" 2

echo "pr-reply: outside a worktree it refuses rather than trusting itself"
# The ownership check is the only protection this script offers, and an
# unresolvable clone identity used to SKIP it: the guard read
# `[[ -n "$ME" && ... ]]`, so running the script by absolute path from
# outside any worktree posted AND resolved on whatever thread it was
# handed. Not knowing whose PR this is has to mean stop, not proceed.
thread_fixture "$ME/feat/thing" false
NOGIT="$(mktemp -d)"
RUN_OUT="$(cd "$NOGIT" && printf '%s' "would post anywhere" | \
    env PATH="$SANDBOX/bin:$PATH" GH_MOCK_STATE="$SANDBOX/state" \
    "${MOCK_ENV[@]}" bash "$UNDER_TEST" "$THREAD_ID" 2>&1)"
RUN_RC=$?
rm -rf "$NOGIT"; NOGIT=""
assert_rc       "exits 2" 2
assert_contains "says the identity is unknown" "identity is unknown"
if [[ "$(calls)" != *REPLY* ]]; then
    pass "nothing was posted"
else
    fail "posted without knowing whose PR it is" "$(calls)"
fi

echo "pr-reply: a missing hard dependency is named, not guessed at"
# git and hostname became hard dependencies when a failed rev-parse was
# made fatal. Without them in the preflight, a missing git surfaces as
# "not inside a git worktree ... run it from the clone that owns the PR"
# — at an operator standing in exactly that clone. Both directions exit
# 2, so this is diagnostic quality, not a bypass; it still needs a test,
# because reverting the preflight leaves every other assertion green.
thread_fixture "$ME/feat/thing" false
STRIP="$(mktemp -d)"
for b in bash env cat cut basename sed grep mktemp rm; do
    src="$(command -v "$b")" && ln -sf "$src" "$STRIP/$b"
done
ln -sf "$SANDBOX/bin/gh" "$STRIP/gh"
ln -sf "$(command -v jq)" "$STRIP/jq"
# deliberately NOT git and NOT hostname
RUN_OUT="$(cd "$SANDBOX/$CLONE_NAME" && printf '%s' "body" | \
    env -i PATH="$STRIP" GH_MOCK_STATE="$SANDBOX/state" \
    "$STRIP/bash" "$UNDER_TEST" "$THREAD_ID" 2>&1)"
RUN_RC=$?
assert_rc       "exits 2" 2
assert_contains "names git rather than blaming the cwd" "git is required"
ln -sf "$(command -v git)" "$STRIP/git"
RUN_OUT="$(cd "$SANDBOX/$CLONE_NAME" && printf '%s' "body" | \
    env -i PATH="$STRIP" GH_MOCK_STATE="$SANDBOX/state" \
    "$STRIP/bash" "$UNDER_TEST" "$THREAD_ID" 2>&1)"
RUN_RC=$?
assert_rc       "exits 2 for hostname too" 2
assert_contains "names hostname" "hostname is required"
rm -rf "$STRIP"; STRIP=""

echo "pr-reply: a failed thread read stops before posting"
thread_fixture "$ME/feat/thing" false
MOCK_ENV=(env GH_MOCK_READ_FAIL=1)
invoke "body" "$THREAD_ID"
MOCK_ENV=(env)
assert_rc "exits 2" 2
if [[ "$(calls)" != *REPLY* ]]; then
    pass "nothing was posted"
else
    fail "posted without knowing the owner" "$(calls)"
fi

echo "pr-reply: a thread in ANOTHER repository is refused"
# `node(id:)` is a GLOBAL lookup, so a foreign thread resolves fine. The
# only thing that used to stand between it and a reply was the
# branch-prefix ownership check -- which passes for any branch named
# `<host>/<clone>/...` in any repo on GitHub. The branch here is
# deliberately one this session OWNS, so the case can only pass if the
# repository check is what stops it.
thread_fixture "$ME/feat/thing" false "someone-else/other-repo"
invoke "body" "$THREAD_ID"
assert_rc "exits 2" 2
assert_contains "names both repositories" "someone-else/other-repo"
if [[ "$(calls)" != *REPLY* && "$(calls)" != *RESOLVE* ]]; then
    pass "neither replied nor resolved"
else
    fail "wrote to a thread in another repository" "$(calls)"
fi

echo "pr-reply: an unknowable current repository is refused, not assumed"
# Failing open here would restore the whole hole: with no local repo to
# compare against, every foreign thread would match nothing and pass.
thread_fixture "$ME/feat/thing" false
MOCK_ENV=(env GH_MOCK_REPO_FAIL=1)
invoke "body" "$THREAD_ID"
MOCK_ENV=(env)
assert_rc "exits 2" 2
assert_contains "says it cannot tell" "cannot determine the current repository"
if [[ "$(calls)" != *REPLY* ]]; then
    pass "nothing was posted"
else
    fail "posted without knowing which repo it is in" "$(calls)"
fi

echo "pr-reply: --dry-run touches nothing"
thread_fixture "$ME/feat/thing" false
invoke "Would say this." "$THREAD_ID" --dry-run
assert_rc       "exits 0" 0
assert_contains "shows the target"  "#77"
assert_contains "shows the body"    "Would say this."
if [[ "$(calls)" != *REPLY* && "$(calls)" != *RESOLVE* ]]; then
    pass "no mutation was sent"
else
    fail "--dry-run mutated something" "$(calls)"
fi

echo "pr-reply: --help lists the flags"
invoke "" --help
assert_rc       "exits 0" 0
assert_contains "documents --no-resolve" "--no-resolve"
assert_contains "documents --dry-run"    "--dry-run"

echo
# A helper that does not exist fails the suite, whatever the counter
# says — see command_not_found_handle above for why this cannot be a
# counter.
if [[ -s "$GUARD_MARKER" ]]; then
    echo "SELF-TEST BUG — undefined helper(s) called: $(sort -u "$GUARD_MARKER" | tr '\n' ' ')" >&2
    echo "  assertions using them never ran. Fix the names before trusting this suite." >&2
    rm -f "$GUARD_MARKER"
    exit 1
fi
rm -f "$GUARD_MARKER"
if [[ "$failures" -eq 0 ]]; then
    echo "test_pr-reply: OK — all assertions passed."
    exit 0
fi
echo "test_pr-reply: FAILED — $failures assertion(s) failed." >&2
exit 1
