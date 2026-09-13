#!/usr/bin/env bash
# Behavioural tests for .claude/agent-dispatch-guard.sh.
#
# What this holds still: the DECISION TABLE of the Agent dispatch hook.
# The program used to live as a jq string inside settings.json and its
# two properties were "pipe-tested at the time it was written" -- in a
# terminal, once, by hand. Both halves of the review carve-out were
# later found to be load-bearing TOGETHER (a type-only key let fable
# through), which is the kind of regression a table of cases catches
# and a comment does not.
#
# Every case pipes a tool-call payload through the REAL script and
# checks the decision: "allow" (no output), "deny", or "ask".
#
# Exit codes:
#   0  all assertions passed
#   1  one or more assertions failed
set -uo pipefail

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" && pwd )"
UNDER_TEST="$SCRIPT_DIR/agent-dispatch-guard.sh"
[[ -f "$UNDER_TEST" ]] || { echo "test: not found: $UNDER_TEST" >&2; exit 1; }

failures=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1" >&2; [[ $# -gt 1 ]] && printf '       %s\n' "$2" >&2; failures=$((failures + 1)); }

# decision <json-tool_input>  -> prints allow | deny | ask
decision() {
  local out
  out="$(printf '{"tool_name":"Agent","tool_input":%s}' "$1" | bash "$UNDER_TEST" 2>/dev/null)"
  if [[ -z "$out" ]]; then echo allow
  else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "malformed"'; fi
}
reason() {
  printf '{"tool_name":"Agent","tool_input":%s}' "$1" | bash "$UNDER_TEST" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecisionReason // ""'
}
expect() {
  local label="$1" want="$2" input="$3" got
  got="$(decision "$input")"
  if [[ "$got" == "$want" ]]; then pass "$label"; else fail "$label" "want $want, got $got"; fi
}

echo "forks"
expect "a fork is allowed with nothing set" allow '{"subagent_type":"fork","description":"continue"}'

echo "the review class: all four conditions, or denied -- never asked"
R='{"subagent_type":"blind-reviewer","model":"fable","description":"Review PR 626 diff","prompt":"..."}'
expect "blind-reviewer + review + fable + no isolation is allowed without a prompt" allow "$R"
expect "re-review is a review" allow '{"subagent_type":"blind-reviewer","model":"fable","description":"Re-review PR 626 after fixes"}'
expect "case-insensitive prefix" allow '{"subagent_type":"blind-reviewer","model":"fable","description":"REVIEW of the delta"}'
expect "any word form beginning review (Reviewing) is a review" allow '{"subagent_type":"blind-reviewer","model":"fable","description":"Reviewing PR 626"}'
expect "review type with a full model id is denied (the Agent tool only accepts aliases; fable is the review alias)" deny '{"subagent_type":"blind-reviewer","model":"claude-opus-5[1m]","description":"Review PR 626"}'
expect "review type with a writing description is denied" deny '{"subagent_type":"blind-reviewer","model":"fable","description":"Address review feedback on PR 626"}'
expect "review anywhere but not at the start is denied" deny '{"subagent_type":"blind-reviewer","model":"fable","description":"Fix and review the mapper"}'
expect "review type on sonnet is denied, not asked" deny '{"subagent_type":"blind-reviewer","model":"sonnet","description":"Review PR 626"}'
expect "review type on haiku is denied" deny '{"subagent_type":"blind-reviewer","model":"haiku","description":"Review PR 626"}'
expect "review type with model unset is denied" deny '{"subagent_type":"blind-reviewer","description":"Review PR 626"}'
expect "review type with opus is denied (opus is code-high's alias on the broker path)" deny '{"subagent_type":"blind-reviewer","model":"opus","description":"Review PR 626"}'
expect "review type WITH isolation is denied" deny '{"subagent_type":"blind-reviewer","model":"fable","isolation":"worktree","description":"Review PR 626"}'
expect "the review prefix on a general agent is denied" deny '{"subagent_type":"general-purpose","model":"sonnet","isolation":"worktree","description":"Review the diff"}'

echo "everything else: model and worktree required, premium asks"
expect "sonnet + worktree is allowed" allow '{"subagent_type":"general-purpose","model":"sonnet","isolation":"worktree","description":"Extract the table"}'
expect "haiku + worktree is allowed" allow '{"model":"haiku","isolation":"worktree","description":"Rename the field"}'
expect "missing model is denied" deny '{"subagent_type":"general-purpose","isolation":"worktree","description":"Extract the table"}'
expect "missing isolation is denied" deny '{"subagent_type":"general-purpose","model":"sonnet","description":"Extract the table"}'
expect "isolation other than worktree is denied" deny '{"model":"sonnet","isolation":"remote","description":"Extract"}'
expect "opus on a general agent asks" ask '{"subagent_type":"general-purpose","model":"opus","isolation":"worktree","description":"Extract the table"}'
expect "fable on a general agent asks" ask '{"model":"fable","isolation":"worktree","description":"Extract the table"}'
expect "Opus in caps still asks" ask '{"model":"Opus","isolation":"worktree","description":"Extract"}'

echo "the denial says why"
r="$(reason '{"subagent_type":"blind-reviewer","model":"sonnet","description":"Review PR 626"}')"
if grep -q "green PR that merges" <<<"$r"; then pass "the tier denial names the failure mode"; else fail "the tier denial names the failure mode" "$r"; fi
r="$(reason '{"subagent_type":"blind-reviewer","model":"fable","isolation":"worktree","description":"Review PR 626"}')"
if grep -q "baseRef" <<<"$r"; then pass "the isolation denial names baseRef"; else fail "the isolation denial names baseRef" "$r"; fi

echo "a guard that cannot run asks; it never silently allows"
out="$(printf '{"tool_input":{"model":"sonnet","isolation":"worktree","description":"x"}}' | env PATH=/nonexistent /bin/bash "$UNDER_TEST" 2>/dev/null)"
if printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null 2>&1; then
  pass "with jq unavailable the guard asks rather than allowing"
else
  fail "with jq unavailable the guard asks rather than allowing" "out=[$out]"
fi

echo "malformed input never breaks the tool call with a bad shape"
for payload in '{}' 'not json' ''; do
  out="$(printf '%s' "$payload" | bash "$UNDER_TEST" 2>/dev/null)"; rc=$?
  # Exit 2 is the ONE code Claude Code treats as a blocking hook error:
  # a guard that exits 2 on a parse failure hard-blocks every dispatch.
  if [[ "$rc" -ne 2 ]] && { [[ -z "$out" ]] || printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision' >/dev/null 2>&1; }; then
    pass "payload (${payload:-empty}) yields allow or a well-formed decision, never exit 2 (rc=$rc)"
  else
    fail "payload (${payload:-empty}) yields allow or a well-formed decision, never exit 2" "rc=$rc out=[$out]"
  fi
done

echo
if [[ "$failures" -eq 0 ]]; then echo "all assertions passed"; exit 0; fi
echo "$failures assertion(s) failed" >&2; exit 1
