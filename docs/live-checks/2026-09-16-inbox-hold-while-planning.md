# The inbox hold, read back — 2026-09-16

The design in `docs/inbox-hold-while-planning.md` rests on three
harness facts and one end-to-end behaviour. Each was measured on
`develop-qzapp`, Claude Code 2.1.273, as login `user`.

## The harness facts (headless probes, a hook that dumps its input)

1. **Every hook event carries `permission_mode`**, except SessionStart.
   A session started with `--permission-mode plan` delivered
   `UserPromptSubmit` and `PreToolUse` events with `permission_mode:
   "plan"`; the SessionStart event had only `hook_event_name` and
   `source`. So the marker follows the mode from the first prompt, and
   the session-start drain is not held (it runs before any planning).
2. **Hooks get `CLAUDE_PID` and `CLAUDE_CODE_SESSION_ID` in their
   environment, and their parent process is the harness itself**
   (`PPID` → `comm=claude`). The marker names that pid; liveness is
   `kill -0`.
3. **The session itself sends `agent_id: null`**, not an absent key.
   The first version of the hook split its four fields on whitespace
   and slid `session_id` into `agent_id`, taking every session for a
   subagent and writing nothing — the unit test had passed because its
   payloads carried no `session_id`. Fixed to one field per line, and
   the test now sends the harness's shape (`session_id` present,
   `agent_id: null`). This is the defect the read-back existed to find.

## End to end (a watch in this session, a plan session under the same login)

The watch (`inbox.mjs --follow` under a Monitor) was armed in this
interactive session. A second, headless session under the same login
was started with `--permission-mode plan` and the bootstrapped
workspace settings (the hook wired on `PreToolUse`, `UserPromptSubmit`
and `SessionEnd`), and given six Read calls to make. Meanwhile a
message addressed to `develop-qzapp/user` was sent through `send.mjs`.

| UTC | observed |
|---|---|
| 11:42:39 | first prompt: `/tmp/agent-fabric-hold-1000/user.json` written, naming the plan session and pid 1453504; `--held` says held |
| 11:42:41 | probe message accepted by the relay as seq 414 |
| 11:42:50 | `--held` still held; the watch's stderr says `inbox held — the session is planning`; nothing on its stdout |
| 11:43:02 | plan session replied "done" and exited; SessionEnd cleared the marker; `--held` says not held |
| 11:43:03 | watch stderr `hold released; polling again`; seq 414 delivered to this session as one notification |

So: a message sent while the account plans is not consumed, not
printed and not notified until the planning session ends, then lands
whole, once, with no loss (the relay re-showed it on the first poll
after release).

## What it decides

- The hold works at the address, across sessions of the login, which
  is the semantics the cursor already has.
- `SessionEnd` is a reliable release for a session that ends in plan
  mode; approval of a plan releases at the next tool call or prompt of
  that session (a `permission_mode` other than `plan`), which was not
  exercised here because a headless session cannot approve a plan.
- The unit tests must send the harness's real payload shape; a hand-made
  payload that omits a field the harness always sends is how this
  defect got past the suite.

## Not read back

- **Release by plan approval in an interactive session** (the
  `ExitPlanMode` → next-event path). The mechanism is the same field on
  the same events; the timing of the first post-approval event is the
  only unmeasured thing.
- **A launched (broker) session.** The workspace settings are the same
  file on every path, so the hook is wired identically; not measured.
- **The 55 s slice cut.** The unit test covers the abort; live, the hold
  began before the watch's slice in flight returned, so the cut was not
  observed separately from the ordinary hold.
