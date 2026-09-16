#!/usr/bin/env bash
# Claude Code hook (PreToolUse on every tool, UserPromptSubmit, SessionEnd):
# hold this account's GZCoord inbox while the session is planning.
#
# A plan is written from the context the session has when it enters plan
# mode; a delivery landing in the middle of it is new context the plan
# was not asked to absorb. The harness gives no way to pause
# notifications, but the whole delivery path is ours: a message becomes a
# notification only because the watch (communication/gzcoord/scripts/
# inbox.mjs --follow) polls the relay and prints it. So the session says
# "planning" through a marker, and the watch does not poll while the
# marker is live: nothing is consumed, the relay keeps the cursor, and the
# first poll after the plan is approved delivers everything at once.
#
# The marker is /tmp/agent-fabric-hold-<uid>/<login>.json — per address,
# like the cursor it holds (two sessions under one login share both). It
# names the session and the harness pid (CLAUDE_PID, exported to hooks;
# the hook's parent IS that process, verified on 2.1.273), so the watch
# honours it only while that process is alive: a session that dies in
# plan mode cannot silence the next one. /tmp does not survive a reboot,
# which is the other way a marker could outlive its session.
#
# Every hook event carries permission_mode (verified live 2.1.273:
# UserPromptSubmit and PreToolUse; SessionStart does not), so the marker
# follows the mode rather than the EnterPlanMode/ExitPlanMode calls — a
# rejected plan stays in plan mode, and a plan entered by launch flag
# never calls EnterPlanMode. A subagent's event (agent_id present) is not
# the session's mode and is ignored. SessionEnd clears the session's own
# marker.
#
# Exit 0 always, nothing on stdout: a hook that cannot run must not turn
# a planning session into a broken one. Without jq the marker is never
# written and the inbox behaves as before this hook existed.
set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0
input="$(cat)" || exit 0
[[ -n "$input" ]] || exit 0

login="$(id -un)"
uid="$(id -u)"
dir="${AGENT_FABRIC_HOLD_DIR:-/tmp/agent-fabric-hold-$uid}"
marker="$dir/$login.json"
pid="${CLAUDE_PID:-$PPID}"
session="${CLAUDE_CODE_SESSION_ID:-}"

# One field per line: an empty field must stay empty (the harness sends
# agent_id: null for the session itself; a whitespace-split read would
# slide session_id into it and take the session for a subagent).
{ read -r event; read -r mode; read -r agent_id; read -r sid; } < <(printf '%s' "$input" | jq -r '.hook_event_name // "", .permission_mode // "", .agent_id // "", .session_id // ""' 2>/dev/null)
[[ -n "${event:-}" ]] || exit 0
[[ -z "${agent_id:-}" ]] || exit 0          # a subagent's mode is not the session's
[[ -n "$session" ]] || session="${sid:-}"

marker_pid() { jq -r '.pid // empty' "$marker" 2>/dev/null; }
alive() { [[ -n "$1" ]] && kill -0 "$1" 2>/dev/null; }

if [[ "$event" != "SessionEnd" && "$mode" == "plan" ]]; then
  # Held. Write once per session: a marker already naming this pid stays.
  if [[ "$(marker_pid)" != "$pid" ]]; then
    mkdir -p -m 700 "$dir" 2>/dev/null || exit 0
    tmp="$(mktemp "$dir/.$login.XXXXXX" 2>/dev/null)" || exit 0
    jq -n --arg s "$session" --argjson p "$pid" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '{session_id: $s, pid: $p, since: $t}' > "$tmp" 2>/dev/null && mv -f "$tmp" "$marker" 2>/dev/null
    rm -f "$tmp" 2>/dev/null
  fi
  exit 0
fi

# Not planning (or ending): clear a marker that is this session's, or
# one whose session is gone. Another live session's hold is left alone.
if [[ -f "$marker" ]]; then
  mp="$(marker_pid)"
  if [[ "$mp" == "$pid" ]] || ! alive "$mp"; then rm -f "$marker" 2>/dev/null; fi
fi
exit 0
