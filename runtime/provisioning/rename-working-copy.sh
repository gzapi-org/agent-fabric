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
# skipped.
set -uo pipefail
login="${1:-}"; old="${2:-}"; new="${3:-}"; dry=0
[[ "${4:-}" == "--dry-run" ]] && dry=1
[[ -n "$login" && -n "$old" && -n "$new" ]] || { sed -n '2,6p' "$0" >&2; exit 2; }
home="$(getent passwd "$login" | cut -d: -f6)"; [[ -n "$home" ]] || { echo "no such login: $login" >&2; exit 2; }
say() { printf 'rename: %s\n' "$*" >&2; }
as() { if [[ "$login" == "$(id -un)" ]]; then "$@"; else sudo -u "$login" -H env -i HOME="$home" PATH=/usr/local/bin:/usr/bin:/bin bash -c 'cd "$HOME" && exec "$@"' -- "$@"; fi; }

if pgrep -u "$login" -x claude >/dev/null 2>&1; then say "$login has a live claude session; not touching it"; exit 1; fi
oldp="$home/projects/$old"; newp="$home/projects/$new"
if ! sudo test -d "$oldp"; then
  sudo test -d "$newp" && { say "$login: already at $newp"; } || { say "$login: no $oldp"; exit 1; }
fi

if sudo test -d "$oldp"; then
  # A rename loses nothing that is on disk — untracked files and the
  # checked-out branch move with the directory — so only uncommitted
  # changes to TRACKED paths are a reason to stop: they are work in a
  # state the account expects to find exactly where it left it.
  dirty="$(as git -C "$oldp" status --porcelain --untracked-files=no | wc -l)"
  branch="$(as git -C "$oldp" branch --show-current)"
  if (( dirty )); then
    say "$login: $oldp ('$branch') has $dirty uncommitted change(s) to tracked paths; refusing to move a tree mid-work"; exit 1
  fi
  [[ "$branch" == "main" ]] || say "$login: on '$branch' (committed); moving it as is"
  if (( dry )); then say "would: mv $oldp $newp"; else as mv "$oldp" "$newp" && as git -C "$newp" worktree prune && say "$login: moved to $newp"; fi
fi

as python3 - "$home" "$login" "$oldp" "$newp" "$dry" <<'PY'
import json, os, re, sys
home, login, oldp, newp, dry = sys.argv[1:5] + [sys.argv[5] == "1"]
key = lambda p: p.replace("/", "-")
pdir_old, pdir_new = os.path.join(home, ".claude", "projects", key(oldp)), os.path.join(home, ".claude", "projects", key(newp))
def note(m): print("rename: " + m, file=sys.stderr)
# 1. the project directory: transcripts and memory
if os.path.isdir(pdir_old):
    if dry: note(f"would: mv {pdir_old} -> {pdir_new}")
    else:
        if os.path.isdir(pdir_new):
            # merge: an earlier session under the new key must not be lost
            for f in os.listdir(pdir_old):
                os.replace(os.path.join(pdir_old, f), os.path.join(pdir_new, f))
            os.rmdir(pdir_old)
        else:
            os.replace(pdir_old, pdir_new)
        note(f"{login}: history {os.path.basename(pdir_new)}")
if os.path.isdir(pdir_new) and not dry:
    n = 0
    old_field, new_field = json.dumps({"cwd": oldp}, separators=(",", ":"))[1:-1], json.dumps({"cwd": newp}, separators=(",", ":"))[1:-1]
    for f in os.listdir(pdir_new):
        if not f.endswith(".jsonl"): continue
        p = os.path.join(pdir_new, f)
        data = open(p, "rb").read()
        if old_field.encode() in data:
            open(p, "wb").write(data.replace(old_field.encode(), new_field.encode())); n += 1
    note(f"{login}: cwd field rewritten in {n} transcript(s)")
# 2. ~/.claude.json project key
cj = os.path.join(home, ".claude.json")
try: d = json.load(open(cj))
except (OSError, ValueError): d = None
if d and isinstance(d.get("projects"), dict) and oldp in d["projects"]:
    if dry: note(f"would: rename projects[{oldp}] in ~/.claude.json")
    else:
        if newp in d["projects"]:
            merged = {**d["projects"][oldp], **d["projects"][newp]}
            for k in ("allowedTools",):
                a, b = d["projects"][oldp].get(k) or [], d["projects"][newp].get(k) or []
                merged[k] = list(dict.fromkeys(a + b))
            d["projects"][newp] = merged
        else:
            d["projects"][newp] = d["projects"][oldp]
        del d["projects"][oldp]
        tmp = cj + ".tmp"; json.dump(d, open(tmp, "w"), indent=2); os.replace(tmp, cj)
        note(f"{login}: ~/.claude.json project key renamed")
# 3. prompt history
hj = os.path.join(home, ".claude", "history.jsonl")
if os.path.exists(hj):
    old_pf, new_pf = json.dumps({"project": oldp}, separators=(",", ":"))[1:-1], json.dumps({"project": newp}, separators=(",", ":"))[1:-1]
    data = open(hj, "rb").read()
    if old_pf.encode() in data:
        if dry: note("would: rewrite history.jsonl project field")
        else: open(hj, "wb").write(data.replace(old_pf.encode(), new_pf.encode())); note(f"{login}: history.jsonl project field rewritten")
# 4. the binding
state = os.environ.get("XDG_STATE_HOME") or os.path.join(home, ".local", "state")
bj = os.path.join(state, "agent-fabric", "agents", login, "binding.json")
try: b = json.load(open(bj))
except (OSError, ValueError): b = None
if b and any(b.get(k) == oldp for k in ("working_copy", "workspace")):
    if dry: note("would: rewrite binding working_copy/workspace")
    else:
        for k in ("working_copy", "workspace"):
            if b.get(k) == oldp: b[k] = newp
        json.dump(b, open(bj, "w"), indent=2); open(bj, "a").write("\n"); note(f"{login}: binding updated")
PY
