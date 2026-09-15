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
# The branch segment exists only inside a repository: a branch name, or
# the short SHA of a detached HEAD (as tab-title.sh reads it). Outside a
# repository — the parent projects/ workspace, by design — there is no
# segment at all. It used to print the word "detached" for both, and a
# session launched from projects/ read as sitting on a detached HEAD it
# had never made (owner, 2026-09-15).
branch=""
if [ -n "$wc" ]; then
    branch=$(git -C "$dir" branch --show-current 2>/dev/null)
    [ -n "$branch" ] || branch=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)
    [ -n "$branch" ] || branch="unborn"
fi

printf '[%s] 👤 %s@%s 📁 %s' "$model" "$agent" "$host" "${wc:-$(basename "$dir")}"
[ -z "$branch" ] || printf ' 🌿 %s' "$branch"
