#!/usr/bin/env bash
# Claude Code hook: set the terminal tab title to <agent> <working-copy>/<branch>.
#
# WHY. Several sessions run in parallel, one agent (Linux login) each, and
# what tells them apart is the agent plus the working copy and branch it is
# on. The status line already shows those while you are looking at a pane;
# this puts them on the TAB, which is what you read when you are looking at
# a different pane. The agent comes from agent-fabric's canonical resolver;
# the working copy is the checkout's basename — context, never identity.
#
# WHY NOT /rename. That sets the session name, and the session name normally
# drives the tab title -- but it cannot be automated. Hooks are shell
# processes, not conversation turns, so nothing can invoke a slash command,
# and no setting, CLI flag or plugin renames a running session. "claude -n
# <name>" names a session once at startup and never follows a branch. The
# Agent SDK does expose a rename call, but it is a separate product appending
# to the live session's own transcript from a second process: whether a
# running session reflects it is undocumented, and so is racing that
# session's own writer. So the tab title is driven directly instead, which is
# the part that was reachable without betting on any of that.
#
# HOW. A hook cannot write to the terminal itself -- hooks run with no
# controlling terminal, so an OSC escape printed to /dev/tty goes nowhere. A
# hook may instead RETURN a top-level "terminalSequence" field, which the
# harness writes through its own terminal path: race-free, and it survives
# tmux. The allowlist is narrow -- OSC 0/1/2 for titles, 9/99/777 for
# notifications, and BEL -- and OSC 0 sets both the window and the icon
# title, which is what tab bars read.
#
# NO COMMAND FILTER, deliberately. It would be cheaper to recompute only
# after a "git checkout" or "git switch", but a filter only catches branch
# changes made by a command this session ran AND matched. A script that
# switches branches, a rebase, or anything the regex did not anticipate would
# leave a stale title -- and a stale title is worse than no title, because it
# is believed. Two git calls per tool call does not buy that risk.
#
# Wired for SessionStart (set it at launch) and PostToolUse on Bash (which
# runs after the command, so a branch change has already happened) in
# settings.json. Outside a git repo it emits nothing, which is a no-op.
#
# The exit code is always 0, explicitly at the end: a hook that fails must
# never block or annotate the tool call it is observing.
set -uo pipefail

input=$(cat)
FABRIC_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
agent=$("$FABRIC_ROOT/bin/fabric-whoami" 2>/dev/null || id -un)

# The hook payload carries the session's directory; $PWD is the fallback for
# a manual run or a payload without it.
dir=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "${dir:-}" ] && [ -d "$dir" ] || dir="$PWD"

# THE MAIN WORKTREE, not the current one. Every subagent dispatch runs in a
# linked worktree under .claude/worktrees/ on its own generated branch, so
# resolving "here" would title the tab agent-<id>/worktree-agent-<id> -- 55
# characters saying nothing about which clone or which task, which is the
# whole point of the title. Worse, it would persist after the agent finished,
# until the session happened to run a Bash call of its own. --git-common-dir
# points at the SHARED .git for a linked worktree and at this one otherwise,
# so its parent is the session's clone either way.
common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
if [ -z "${common:-}" ]; then
  # --path-format predates neither git nor this repo's floor, but a relative
  # answer is still better than none.
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null)
  case "${common:-}" in
    "" ) exit 0 ;;
    /* ) ;;
    *  ) common="$dir/$common" ;;
  esac
fi
toplevel=$(cd "$(dirname "$common")" 2>/dev/null && pwd) || exit 0
[ -n "$toplevel" ] || exit 0
wc=$(basename "$toplevel")

# Read the branch from that same main worktree, for the same reason.
# Detached HEAD gets a short SHA rather than an empty half-title; if even
# that is unavailable, emit nothing -- a half-title is worse than none.
branch=$(git -C "$toplevel" branch --show-current 2>/dev/null)
[ -n "$branch" ] || branch=$(git -C "$toplevel" rev-parse --short HEAD 2>/dev/null)
[ -n "$branch" ] || exit 0

# gzapp branches are named <host>/<agent>/<type>/<desc> (older ones carry
# the working-copy name in the second segment), so the prefix is redundant
# on a narrow tab. Strip it when it is this session's own — by agent or by
# working copy — leaving <type>/<desc>. Any other branch is left as it is.
host=$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)
if [ -n "${host:-}" ]; then
  case "$branch" in
    "$host/$agent/"*) branch=${branch#"$host/$agent/"} ;;
    "$host/$wc/"*) branch=${branch#"$host/$wc/"} ;;
  esac
fi

# Built inside jq rather than with printf: the ESC and BEL bytes stay inside
# jq's own string literal, so nothing depends on the shell preserving control
# characters through a command substitution.
jq -nc --arg title "$agent $wc/$branch" '{terminalSequence: "\u001b]0;\($title)\u0007"}' 2>/dev/null

# The last command's status is NOT the script's contract: a missing jq would
# otherwise exit 127, and a non-zero hook exit surfaces an error notice on
# EVERY Bash tool call. A cosmetic feature must never do that.
exit 0
