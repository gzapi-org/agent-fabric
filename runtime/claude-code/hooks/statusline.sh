#!/usr/bin/env bash
# Claude Code status line: model · host · clone-dir · git branch.
# Surfaces which host + clone + branch the session is on — the
# <hostname>/<clone-dir>/<task> attribution model (CLAUDE.md §Git discipline →
# Concurrent contributors). Reads the session JSON on stdin; runs locally,
# no API tokens. Configured by .claude/settings.json `statusLine`.
input=$(cat)

dir=$(printf '%s' "$input" | jq -r '.workspace.current_dir // empty')
[ -z "$dir" ] && dir="$PWD"
model=$(printf '%s' "$input" | jq -r '.model.display_name // "Claude"')
host=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "?")
clone=$(basename "$dir")
branch=$(git -C "$dir" branch --show-current 2>/dev/null)

printf '[%s] 🖥  %s 📁 %s 🌿 %s' "$model" "$host" "$clone" "${branch:-detached}"
