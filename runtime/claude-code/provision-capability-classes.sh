#!/usr/bin/env bash
# runtime/claude-code/provision-capability-classes.sh
#
# Install the capability-class agent files from THIS REPOSITORY into
# every account on this host.
#
# WHY (PR #681; devex-tooling-0029/0030): subagent dispatch names a
# capability class — code-low (mechanical), code-medium (judgement),
# code-high (premium, only when asked). The classes are USER-LEVEL
# agents, ~/.claude/agents/code-{low,medium,high}.md: an account
# without the three files fails every class-named dispatch as an
# unknown agent type. The CANONICAL COPIES live in the repo at
# runtime/claude-code/agents/ — not in any one account's home — so
# provisioning a new account never depends on another account being
# present or current. runtime/provisioning/README.md is the durable home of
# the procedure.
#
# RUN AS ROOT — the role homes are mode 700, so only root can write
# into them. The owner runs it:
#
#   sudo runtime/claude-code/provision-capability-classes.sh --dry-run   # preview
#   sudo runtime/claude-code/provision-capability-classes.sh             # do it
#
# WHAT IT DOES per account: mkdir -p ~/.claude/agents, copy the three
# files, mode 644, owned by the account. Nothing else under ~/.claude
# is read or written. Idempotent: a copy already identical is reported
# and left untouched, so re-running only refreshes what changed — the
# first run installed devex-tooling's copies; against the repo copies
# it is a no-op until the repo copies move.
#
# SAFETY: the real run refuses to run as non-root; it aborts if a
# repo source file is missing; it skips a /home entry whose owner is
# not a real account. The dry run writes nothing and may run as any
# user.

set -euo pipefail

AGENTS=(code-low.md code-medium.md code-high.md)
DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then DRY_RUN=1; fi

# The repo's canonical copies, beside this script.
SRC_DIR="$(cd "$(dirname "$0")/agents" && pwd)"

if [ "$DRY_RUN" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
  echo "This writes into every account's ~/.claude/agents/ — run it as root:" >&2
  echo "  sudo $0" >&2
  exit 1
fi

for f in "${AGENTS[@]}"; do
  if [ ! -f "$SRC_DIR/$f" ]; then
    echo "missing repo source: $SRC_DIR/$f" >&2
    exit 1
  fi
done

targets=0 copied=0 identical=0
for home in /home/*/; do
  home="${home%/}"
  # A home is an account's when the directory NAME is a login whose passwd
  # home is this directory. Keying on the directory's owner instead let an
  # orphaned pre-rename home (a legacy pre-rename home, owned by its successor account)
  # be provisioned as if it were an account, 2026-09-13.
  name="$(basename "$home")"
  if ! getent passwd "$name" >/dev/null; then
    echo "skip   $home ('$name' is not an account)"
    continue
  fi
  if [ "$(getent passwd "$name" | cut -d: -f6)" != "$home" ]; then
    echo "skip   $home (account '$name' lives elsewhere)"
    continue
  fi
  owner="$(stat -c '%U' "$home")"
  group="$(stat -c '%G' "$home")"
  targets=$((targets+1))
  dest="$home/.claude/agents"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "would   provision $owner -> $dest"
    continue
  fi
  mkdir -p "$dest"
  # Anything root just created must belong to the account; chowning a
  # directory the account already owns is a no-op.
  chown "$owner:$group" "$home/.claude" "$dest"
  state=""
  for f in "${AGENTS[@]}"; do
    if [ -f "$dest/$f" ] && cmp -s "$SRC_DIR/$f" "$dest/$f"; then
      identical=$((identical+1))
      state="$state =$f"
    else
      install -m 644 -o "$owner" -g "$group" "$SRC_DIR/$f" "$dest/$f"
      copied=$((copied+1))
      state="$state +$f"
    fi
  done
  echo "done    $owner  ($state )"
done

if [ "$DRY_RUN" -eq 1 ]; then
  echo "dry run: $targets account(s) would be provisioned from $SRC_DIR"
else
  echo "provisioned $targets account(s): $copied copied, $identical already identical"
fi
