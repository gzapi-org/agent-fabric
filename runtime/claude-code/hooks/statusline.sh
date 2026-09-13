#!/usr/bin/env bash
# Claude Code status line: model · agent@host · working copy · git branch.
#
# The AGENT is the Linux login, from agent-fabric's canonical resolver
# (bin/fabric-whoami); the directory is shown as the working copy the
# session is in — context, never identity. Reads the session JSON on
# stdin; runs locally, no API tokens. Wired by the workspace
# .claude/settings.json `statusLine` that runtime/claude-code/bootstrap.sh
# writes.
input=$(cat)

FABRIC_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
dir=$(printf '%s' "$input" | jq -r '.workspace.current_dir // empty')
[ -z "$dir" ] && dir="$PWD"
model=$(printf '%s' "$input" | jq -r '.model.display_name // "Claude"')
agent=$("$FABRIC_ROOT/bin/fabric-whoami" 2>/dev/null || id -un)
host=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "?")
wc=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)
wc=${wc:+$(basename "$wc")}
branch=$(git -C "$dir" branch --show-current 2>/dev/null)

printf '[%s] 👤 %s@%s 📁 %s 🌿 %s' "$model" "$agent" "$host" "${wc:-$(basename "$dir")}" "${branch:-detached}"
