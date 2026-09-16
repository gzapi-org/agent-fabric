#!/usr/bin/env bash
# runtime/provisioning/rename-working-copy.sh — move an account's working
# copy and carry its Claude Code history with it. Host tooling, run by the
# coordinator with sudo.
#
#   rename-working-copy.sh <login> <old-name> <new-name> [--dry-run]
#
# Claude Code keys a project's transcripts, memory, settings and prompt
# history by the clone's ABSOLUTE PATH. Renaming the directory alone
# strands all of it under the old key; this applies the same rename to
# every place that holds the path, as the account:
#   ~/projects/<old>                      -> ~/projects/<new>   (mv; a tree with
#                                            uncommitted changes to tracked
#                                            paths is refused — untracked
#                                            files and the branch move along)
#   ~/.claude/projects/-home-<login>-projects-<old>/
#                                         -> …-<new>/  (transcripts, memory),
#                                            and the "cwd" field of every
#                                            transcript record — that field
#                                            only; recorded tool output keeps
#                                            the path it saw
#   ~/.claude.json  projects["<old path>"] -> projects["<new path>"]
#   ~/.claude/history.jsonl "project"      -> the new path
#   the agent's binding (working_copy, workspace)
# Nothing else holds the path: hooks resolve the fabric from
# $CLAUDE_PROJECT_DIR, core.hooksPath is absolute to the fabric checkout,
# secrets come from the environment, and a GZCoord address is the login.
#
# Refused when the account has a live `claude` process: a session mid-flight
# would keep writing under the old key. Idempotent: a step already done is
# skipped. The shell half stops where it fails (review, 2026-09-16): a
# `mv` that did not happen, or a prune that failed, ends the run before
# any history is rewritten — the Python half runs only once the tree is
# at its new path, so the two never disagree about where the clone is.
set -uo pipefail
login="${1:-}"; old="${2:-}"; new="${3:-}"; dry=0
[[ "${4:-}" == "--dry-run" ]] && dry=1
[[ -n "$login" && -n "$old" && -n "$new" ]] || { sed -n '2,6p' "$0" >&2; exit 2; }
home="$(getent passwd "$login" | cut -d: -f6)"; [[ -n "$home" ]] || { echo "no such login: $login" >&2; exit 2; }
say() { printf 'rename: %s\n' "$*" >&2; }
die() { printf 'rename: %s\n' "$*" >&2; exit 1; }
must() { "$@" || die "step failed: $* — nothing after it ran; the tree and the history are as they were"; }
SUDO="${SUDO:-sudo}"   # a test puts a fake here
as() { if [[ "$login" == "$(id -un)" ]]; then "$@"; else $SUDO -u "$login" -H env -i HOME="$home" PATH=/usr/local/bin:/usr/bin:/bin bash -c 'cd "$HOME" && exec "$@"' -- "$@"; fi; }
# The account's own copy of the state layer (runtime/identity.py): the coordinator's checkout is not readable to it.
FABRIC_IDENTITY="$home/projects/agent-fabric/runtime/identity.py"
[[ -f "$FABRIC_IDENTITY" ]] || FABRIC_IDENTITY="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)/runtime/identity.py"
RENAME_HISTORY="$(dirname "$FABRIC_IDENTITY")/../runtime/provisioning/rename_history.py"
[[ -f "$RENAME_HISTORY" ]] || RENAME_HISTORY="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/rename_history.py"

if pgrep -u "$login" -x claude >/dev/null 2>&1; then die "$login has a live claude session; not touching it"; fi
oldp="$home/projects/$old"; newp="$home/projects/$new"
if ! $SUDO test -d "$oldp"; then
  $SUDO test -d "$newp" && { say "$login: already at $newp"; } || die "$login: no $oldp"
fi

if $SUDO test -d "$oldp"; then
  $SUDO test -d "$newp" && die "$login: both $oldp and $newp exist; nothing moved — resolve by hand"
  # A rename loses nothing that is on disk — untracked files and the
  # checked-out branch move with the directory — so only uncommitted
  # changes to TRACKED paths are a reason to stop: they are work in a
  # state the account expects to find exactly where it left it.
  status="$(as git -C "$oldp" status --porcelain --untracked-files=no)" || die "$login: git status failed in $oldp (not a repository, or not readable as the account); nothing moved"
  dirty="$(printf '%s' "$status" | grep -c .)"
  branch="$(as git -C "$oldp" branch --show-current)"
  if (( dirty )); then
    die "$login: $oldp ('$branch') has $dirty uncommitted change(s) to tracked paths; refusing to move a tree mid-work"
  fi
  [[ "$branch" == "main" ]] || say "$login: on '$branch' (committed); moving it as is"
  if (( dry )); then say "would: mv $oldp $newp"; else
    must as mv "$oldp" "$newp"
    must as git -C "$newp" worktree prune
    say "$login: moved to $newp"
  fi
fi

# The history follows the tree, and only a tree that is where the new key
# says: a dry run reports; a real run past this line has $newp in place.
(( dry )) || $SUDO test -d "$newp" || die "$login: $newp is not there after the move; history left under its old key"
must as python3 "$RENAME_HISTORY" "$home" "$login" "$oldp" "$newp" "$dry" "$FABRIC_IDENTITY"
