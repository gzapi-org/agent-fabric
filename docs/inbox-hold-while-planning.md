# The inbox is held while a session plans — 2026-09-16

**What changed in meaning.** Until now a GZCoord delivery reached a
session the moment the watch printed it, whatever the session was doing.
Now a session in plan mode does not receive: its account's inbox is
*held*, and the deliveries of the whole planning span land together at
the first turn boundary after the plan is approved. "Received" therefore
no longer means "arrived at the relay"; it means "polled by a watch that
was not held".

**Why.** A plan is written from the context the session had when it
entered plan mode. A delivery landing in the middle of it is new context
the plan was not asked to absorb; it changes the plan without anyone
having decided that it should, and the approval that follows judges a
plan whose inputs moved under it. The owner's objective (2026-09-16):
while planning, nothing new lands.

**Where the hold lives.** The harness offers no way to pause
notifications, and none is needed: a delivery is a notification only
because the watch (`communication/gzcoord/scripts/inbox.mjs --follow`)
polls the relay and prints. So the hold is two small things in our own
lane:

- **the marker** — `runtime/claude-code/hooks/plan-hold.sh`, on every
  tool call (`PreToolUse`, unmatched), every prompt (`UserPromptSubmit`)
  and `SessionEnd`, writes `~/.cache/agent-fabric/hold/<pid>.json`
  while the event's `permission_mode` is `plan` and removes it
  otherwise — one marker per planning session, under the login's own
  home (a per-uid name under `/tmp` could be created first and owned by
  another login), in a directory that must be the login's, mode 700 and
  not a symlink. The marker names the session, the harness pid
  (`CLAUDE_PID`, which hooks receive; verified live on 2.1.273) and the
  pid's start time from `/proc`, so a reused pid is not the harness. It follows the mode, not the
  `EnterPlanMode`/`ExitPlanMode` calls: a rejected plan stays in plan
  mode, and a plan entered by launch flag never calls the tool. A
  subagent's event (`agent_id` present) is not the session's mode and is
  ignored.
- **the watch** — is held while any marker names a live harness of
  this login (the pid answers a signal as this uid; EPERM is another
  login's process and never a hold), checked before every slice, once a
  second during one, and when the slice returns. Held: it polls nothing
  (an in-flight long-poll is cut, and a page that landed in the same
  second is dropped unread; nothing was acknowledged, so the relay
  re-shows it). Released: it polls, and whatever accumulated is
  delivered in one page. Held and released are one line each on stderr,
  never stdout — stdout is what becomes a notification.

**What is not held.** The session-start drain: a session launched
straight into plan mode sees its backlog at start, before any planning.
Sending: a planning session may still send. Reading on demand: `--wait
3` is a deliberate read and is not held either.

**Staleness.** A marker is a hold only while the harness it names is
alive with the start time recorded. A session that dies planning leaves
a marker the next hook event of any session under that login sweeps,
and the watch ignores meanwhile; a reboot leaves markers naming pids
that no longer exist or have another start time, which is the same
case. Without `jq` the hook writes nothing and the inbox behaves as
before this change. A permission mode changed with the keyboard while
the session is idle fires no hook: the hold begins, or ends, at the
session's next prompt or tool call.

**Scope.** Per address, like the cursor: two sessions under one login
share the hold as they share the cursor — each planning session holds
with its own marker, and the account is released when the last of them
leaves plan mode. The hook reaches a session through the settings file
the session was started under: the workspace template wires it for a
session started from `~/projects`, and each managed project's
`.claude/settings.json` must wire it for a session started inside that
clone (`projects/gzapp/integration/gzcoord/INSTALL.md`). A sender with `REPLY-EXPECTED:
yes` waits for the plan's approval; the protocol calls every delivery
late and advisory, and a plan is bounded by an approval.

**Where it is checked.** `runtime/claude-code/hooks/test_plan-hold.sh`
(the marker), `communication/gzcoord/tests/protocol.test.mjs` (the
loop, the abort, `--follow` against a fake relay, `--held`),
`tests/test_session_start.py` (the template wires the hook on the three
events), and the live read-back in
`docs/live-checks/2026-09-16-inbox-hold-while-planning.md`.
