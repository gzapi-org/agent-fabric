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
#                      form: Reviewing, Re-review of ...) AND model
#                      "fable" AND NO isolation. All four, or denied --
#                      never asked. Standing authorisation for the
#                      class: a review's failure mode is not a retry,
#                      it is a green PR that merges, so no per-dispatch
#                      prompt and no dropping to a cheaper tier because
#                      a review looks small. No worktree, because a
#                      review writes nothing and worktree.baseRef=head
#                      would hide uncommitted work from the one agent
#                      that must see it; the tree is read-only for it.
#                      WHY fable and not opus: the Agent tool's model
#                      field accepts only the tier aliases, and on the
#                      broker path one alias carries one exported
#                      model. code-high rides opus, so a reviewer on
#                      opus IS code-high's model -- on 2026-09-13 that
#                      was GLM 5.3. fable is the alias nothing else
#                      rides; the launcher exports the review-grade
#                      model under it and gates exactly that export.
#   CODING class   -> subagent_type code-low / code-medium / code-high:
#                      the class DECIDES the tier. `model` must be the
#                      alias runtime/claude-code/aliases.json binds to
#                      that class (haiku / sonnet / opus); anything
#                      else is denied, unset included. A class whose
#                      alias could be overridden per call is decorative:
#                      code-high on sonnet is "high" work on the cheap
#                      tier with nothing to say so. The alias stays on
#                      the call rather than being inferred, because it
#                      is what the harness resolves and what the broker
#                      launcher exports per session; the class is the
#                      vocabulary, the alias its binding, and the two
#                      must agree. code-high asks (premium).
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

# The class->alias binding, from the file the launcher exports from. A
# missing or unreadable file must not silently loosen the check: the
# class branch then denies with a message that says so.
ALIASES="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)/aliases.json"
ALIAS_JSON="$(jq -c '.aliases // {}' "$ALIASES" 2>/dev/null || echo '{}')"

# THE VANILLA PIN. On plain claude launched by the fabric
# (runtime/openrouter/launch --provider anthropic) the review class is
# pinned to a native model (routing/capabilities.json, anthropic column) —
# but not by exporting ANTHROPIC_DEFAULT_FABLE_MODEL: that rebinds the
# alias for the whole session, so a hand `/model fable` would land on the
# review model too. Verified live 2026-09-15: the Agent tool's `model`
# accepts only the four aliases (a hook rewriting it to a native id is
# rejected at schema validation), the dispatch's `model` outranks the
# agent file's, and an agent file whose frontmatter names a native id runs
# on it when the dispatch leaves `model` unset. So the pin lives in the
# reviewer's agent file (install-agent-files.sh writes it there from
# routing, merged for THIS login — `pins --me` — since the account's own
# layer may name it), and this guard — AFTER the review rules have held,
# `model: fable` included — allows the dispatch with `model` removed, so
# the file's pin applies. Only under a fabric vanilla launch, only for the
# review class; a coding class's pin is the export of the alias it rides
# and the dispatch's alias reaches the harness as written.
PINNED_JSON='{}'
if [[ "${AGENT_FABRIC_LAUNCH_PROVIDER:-}" == anthropic ]]; then
  ROUTING="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)/tools/fabric/routing.py"
  PINNED_JSON="$(python3 "$ROUTING" pins --me 2>/dev/null | awk '{printf "%s\"%s\":\"%s\"", (NR>1?",":""), $1, $3} END {print ""}' | sed 's/^/{/; s/$/}/')"
  jq -e . <<<"$PINNED_JSON" >/dev/null 2>&1 || PINNED_JSON='{}'
fi

jq -c --argjson aliases "$ALIAS_JSON" --argjson pinned "$PINNED_JSON" '
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
      elif $model != "fable" then
        deny("Review dispatch with model \"" + ($t.model // "unset") + "\". The review class rides the fable alias, always: set model: fable. Not opus -- code-high rides opus, and on the broker path one alias carries one exported model, so a reviewer on opus is whatever code-high resolves to (GLM). Not unset -- the review is not a retryable step, its failure mode is a green PR that merges. The Agent tool accepts no full model id. The review capability is gated by agent-fabric routing/policies/review-grade.json, and the broker launcher (runtime/openrouter/launch) refuses a profile that resolves it to anything else, so policy stays here and vendor plumbing stays in routing/. See CLAUDE.md - Subagent dispatch.")
      elif $iso != "" then
        deny("Review dispatch sets isolation. A review writes nothing, so isolation protects nothing, and it hurts: worktree.baseRef is head, so a reviewer in a worktree cannot see uncommitted work. Omit isolation, pass the repository path, and tell the agent the tree is read-only and it runs no git writes. See CLAUDE.md - Subagent dispatch.")
      elif ($pinned["review"] // "") != "" then
        # The rules held; on the fabric vanilla path the reviewer file carries the pin.
        {hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"allow",
          permissionDecisionReason:("Review dispatch on the fabric vanilla path: model fable checked, then removed so the reviewer runs on its pinned model " + $pinned["review"] + " (the agent file, from routing/capabilities.json) while the session keeps fable as fable."),
          updatedInput:($t | del(.model))}}
      else empty end
    elif $review_desc then
      deny("Description begins with review but subagent_type is \"" + $type + "\". A code review is the blind-reviewer class (fable, no isolation, no session context) -- not a general agent on a cheaper tier. If this is not a code review, re-word the description (Audit ..., Check ..., Inspect ...). See CLAUDE.md - Subagent dispatch.")
    elif ($type | test("^code-(low|medium|high)$")) then
      ($aliases[$type] // "") as $alias
      | if $alias == "" then
          deny("Dispatch names the class \"" + $type + "\" but runtime/claude-code/aliases.json binds no alias to it (file missing, unreadable, or the class is not in it). The class decides the tier and this guard cannot tell which; nothing is inferred. Fix the binding, or set model to the alias the class is documented to ride. See CLAUDE.md - Subagent dispatch.")
        elif $model != $alias then
          deny("Dispatch names the class \"" + $type + "\" with model \"" + ($t.model // "unset") + "\"; that class rides the " + $alias + " alias (runtime/claude-code/aliases.json), and the two must agree -- a class whose tier a call can override is a label, and " + $type + " on another tier is that work on a model nothing chose for it. Set model: " + $alias + ", or name the class that rides the tier you mean. See CLAUDE.md - Subagent dispatch.")
        elif $iso != "worktree" then
          deny("Agent dispatch does not set isolation to worktree. Every writing subagent works in its own worktree, never the session clone: the dispatcher opens and closes it, the agent stays in the path it is given, runs no git, and never commits. A premium-model authorisation grants a model tier, not an isolation exemption. Forks and the review class are the only carve-outs. See CLAUDE.md - Subagent dispatch.")
        elif $type == "code-high" then
          ask("Agent dispatch names code-high, the premium class (" + $alias + "). Per CLAUDE.md, the premium tier is for a subagent only when you explicitly asked for it -- the task looking hard is not authorisation. Approve only if you did.")
        else empty end
    elif ($model | length) == 0 then
      deny("Agent dispatch has no model set. Omitting it is not a neutral default - the subagent INHERITS the session model, so a premium session silently spawns premium agents. Set model explicitly: haiku for mechanical work (extraction, pattern-following edits, structured search), sonnet for judgement work (multi-file reasoning, convention-holding prose). See CLAUDE.md - Subagent dispatch.")
    elif $iso != "worktree" then
      deny("Agent dispatch does not set isolation to worktree. Every writing subagent works in its own worktree, never the session clone: the dispatcher opens and closes it, the agent stays in the path it is given, runs no git, and never commits. A premium-model authorisation grants a model tier, not an isolation exemption. Forks and the review class are the only carve-outs. See CLAUDE.md - Subagent dispatch.")
    elif ($model | test("opus|fable")) then
      ask("Agent dispatch requests the premium model \"" + ($t.model // "") + "\". Per CLAUDE.md, opus/fable are forbidden for subagents unless you explicitly asked for that tier. Approve only if you did.")
    else empty end
'
