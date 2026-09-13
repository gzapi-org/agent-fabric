#!/usr/bin/env bash
# Claude Code PreToolUse hook for the Agent tool: the dispatch guard.
#
# Reads the tool call on stdin, prints a hookSpecificOutput JSON object
# to deny or ask, or prints nothing to allow. The rules it enforces are
# CLAUDE.md "Subagent dispatch"; the incidents behind each one are in
# the subagent-dispatch skill. This file exists so the program can be
# READ and TESTED (.claude/test_agent-dispatch-guard.sh) -- it used to
# be a one-line jq string inside settings.json, which nothing exercised.
#
# TWO CLASSES OF DISPATCH, decided in this order:
#
#   fork            -> allowed; a fork continues the session.
#   REVIEW class    -> subagent_type "blind-reviewer" AND description
#                      beginning "review" / "re-review" (any word
#                      form: Reviewing, Re-review of ...) AND a model
#                      naming opus (the alias or a full id) AND NO
#                      isolation. All four, or denied -- never
#                      asked. Standing authorisation for the class:
#                      a review's failure mode is not a retry, it is a
#                      green PR that merges, so no per-dispatch prompt
#                      and no dropping to a cheaper tier because a
#                      review looks small. No worktree, because a
#                      review writes nothing and worktree.baseRef=head
#                      would hide uncommitted work from the one agent
#                      that must see it; the tree is read-only for it.
#   everything else -> model required; isolation "worktree" required;
#                      opus/fable ask (per-dispatch authorisation).
#
# WHY the description prefix is a condition and not a substitute for
# the type: a hook that granted the exemption on review-ish WORDS would
# be satisfiable by phrasing. Here the words can only NARROW -- the type
# is a file in the repo, and the prefix stops a writing dispatch
# ("Address review feedback") from wearing the review type and running
# unisolated in the clone. Another project learned exactly that the
# hard way: a guard that matched "review" anywhere let it through.
#
# WHY the model condition sits inside the review branch: keyed on the
# type alone, a sonnet or haiku dispatch would take the exemption and
# evade the rule beside it. Both halves, or neither.
set -uo pipefail

# A permission gate that cannot run must not vanish into an allow. jq
# missing is the one dependency; without it, ASK -- the person at the
# keyboard sees why -- rather than let every dispatch through unchecked.
if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"The dispatch guard could not run (jq is not installed). Approve only if you have checked model and isolation yourself. See CLAUDE.md - Subagent dispatch."}}'
  exit 0
fi

jq -c '
  def deny(reason): {hookSpecificOutput:{hookEventName:"PreToolUse",
                     permissionDecision:"deny",
                     permissionDecisionReason:reason}};
  def ask(reason):  {hookSpecificOutput:{hookEventName:"PreToolUse",
                     permissionDecision:"ask",
                     permissionDecisionReason:reason}};
  (.tool_input // {}) as $t
  | ($t.subagent_type // "") as $type
  | (($t.model // "") | ascii_downcase) as $model
  | ($t.isolation // "") as $iso
  | (($t.description // "") | ascii_downcase
     | test("^\\s*(re-)?review")) as $review_desc
  | if $type == "fork" then empty
    elif $type == "blind-reviewer" then
      if ($review_desc | not) then
        deny("blind-reviewer dispatch whose description does not BEGIN with review or re-review. The review class is read-only and unisolated; a writing task under this type would run in the session clone. Describe a review as one, or dispatch a normal agent with isolation worktree. See CLAUDE.md - Subagent dispatch.")
      elif ($model | test("opus") | not) then
        deny("Review dispatch with model \"" + ($t.model // "unset") + "\". The review class runs Opus, always: a review is not a retryable step, its failure mode is a green PR that merges, so no dropping to a cheaper tier because the review looks small. Set model: claude-opus-5[1m] (the id the blind-reviewer agent file declares) or opus. The review capability is gated by agent-fabric routing/policies/review-grade.json, and the broker launcher (runtime/openrouter/launch) refuses a profile that resolves it to anything else, so policy stays here and vendor plumbing stays in routing/. See CLAUDE.md - Subagent dispatch.")
      elif $iso != "" then
        deny("Review dispatch sets isolation. A review writes nothing, so isolation protects nothing, and it hurts: worktree.baseRef is head, so a reviewer in a worktree cannot see uncommitted work. Omit isolation, pass the repository path, and tell the agent the tree is read-only and it runs no git writes. See CLAUDE.md - Subagent dispatch.")
      else empty end
    elif $review_desc then
      deny("Description begins with review but subagent_type is \"" + $type + "\". A code review is the blind-reviewer class (opus, no isolation, no session context) -- not a general agent on a cheaper tier. If this is not a code review, re-word the description (Audit ..., Check ..., Inspect ...). See CLAUDE.md - Subagent dispatch.")
    elif ($model | length) == 0 then
      deny("Agent dispatch has no model set. Omitting it is not a neutral default - the subagent INHERITS the session model, so a premium session silently spawns premium agents. Set model explicitly: haiku for mechanical work (extraction, pattern-following edits, structured search), sonnet for judgement work (multi-file reasoning, convention-holding prose). See CLAUDE.md - Subagent dispatch.")
    elif $iso != "worktree" then
      deny("Agent dispatch does not set isolation to worktree. Every writing subagent works in its own worktree, never the session clone: the dispatcher opens and closes it, the agent stays in the path it is given, runs no git, and never commits. A premium-model authorisation grants a model tier, not an isolation exemption. Forks and the review class are the only carve-outs. See CLAUDE.md - Subagent dispatch.")
    elif ($model | test("opus|fable")) then
      ask("Agent dispatch requests the premium model \"" + ($t.model // "") + "\". Per CLAUDE.md, opus/fable are forbidden for subagents unless you explicitly asked for that tier. Approve only if you did.")
    else empty end
'
