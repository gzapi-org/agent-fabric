# Per-agent state is one layer — what changed on 2026-09-16

A note under `docs/` because a concept moved: **what a file under
`agents/<login>/` is, and who may write it.**

## Before

`runtime/identity.py` owned the binding's *shape* — `read_binding` refused
another agent's record, `write_binding` stamped agent and host — but not
its *writes*. Four places rewrote per-agent state in their own way: the
role activator (binding and `role-history.jsonl`), the session-start hook
(the session id and working copy on every start and resume),
`rename-working-copy.sh` (the binding, transcripts, `~/.claude.json`,
`history.jsonl`, all rewritten in place from a shell heredoc) and the
launcher's stamps. None held a lock; a hook firing while `fabric-role`
wrote lost one of the two updates, and a kill mid-rewrite left a
truncated file. The host was recorded but never checked, so a home
directory shared between two machines carried a binding from one to the
other. A history directory that already existed under the new key was
overwritten file by file (review, 2026-09-16, items 1, 2, 5, 6).

## After

**Every write to `agents/<login>/` goes through `runtime/identity.py`,
and only through it.**

- `atomic_write(path, data)`: a temporary beside the target, fsync,
  `os.replace`. The previous file is whole at every instant; a temporary
  left by a crash is removed by the next write. Used for every state
  file and, by `rename_history.py`, for every Claude Code file the
  rename touches.
- `agent_lock(agent)`: a re-entrant `flock` on `agents/<login>/.lock`.
  Every read-modify-write of per-agent state holds it — activation,
  deactivation, the hook's stamp, the rename — across processes.
  `tests/test_identity.py` proves it with four processes racing one
  counter and one history file.
- `update_binding(mutate, agent)` and `append_history(record, agent)`:
  the two operations callers actually need, built on both. `role.py`,
  `session-start.py` and `rename_history.py` use them; no caller opens
  `binding.json` for writing.
- **A binding is per (agent, host).** `read_binding` refuses a record
  whose `host` is not this machine's, with the same wording it uses for
  another agent's, and says how to bind here. The agent's identity does
  not change — it is still the login — but what it *holds* is bound
  where it was bound.
- **A rename merges, never overwrites.** `runtime/provisioning/
  rename_history.py` (the Python half of `rename-working-copy.sh`, run
  as the account) plans the merge before moving anything: same name and
  bytes, one copy; same name and different bytes, both kept, the
  incoming one suffixed `.from-<old key>`; a directory on both sides is
  refused before the first move. `tests/test_rename_history.py`.

## What this decides

A tool that needs to write per-agent state imports `identity` and calls
one of these; a new file under `agents/<login>/` gets its writer added
there, not a rewrite in place elsewhere. The hook stays non-blocking: a
refused binding (another agent's, another host's) reaches the session as
context, not as a failed start.
