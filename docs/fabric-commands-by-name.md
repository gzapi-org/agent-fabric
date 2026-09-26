# Fabric commands run by name, without an approval

*2026-09-26. What changed meaning: a session used to be told where a
fabric command lives (`node "$AGENT_FABRIC_ROOT/communication/gzcoord/
scripts/inbox.mjs"`). It is now told what the command is called
(`gzcoord-inbox`).*

## Why

The harness asks for approval before any command that carries a shell
expansion, whatever the permission mode and whatever the allow rules
say. The inbox watch is re-armed every thirty minutes, so every re-arm
asked. The owner's rule: no approval for any fabric script or
executable.

## How

`runtime/claude-code/commands.json` is the one list of session-facing
commands, each a name and the script it runs. From it:

- `bootstrap.sh` links each name into `~/.local/bin`, which is on every
  account's PATH. It refreshes a link it made, and refuses, by name, a
  file there that it did not make.
- `user-settings.py` writes a narrow `Bash(<name> *)` allow rule for each
  name into the account's user settings. User settings reach every
  session, wherever it starts. In auto mode a narrow Bash rule is
  resolved before the classifier, and a Monitor follows the Bash rules
  (Claude Code docs: tools-reference, Monitor tool; auto-mode-config).
- **Not allowed outright:** `fabric-lease` runs whatever follows `--`,
  and `fabric-host … run` runs anything on a host. An allow rule for
  either would allow every command, so both are linked but still ask.
  An `ask` rule an account sets still wins over any allow rule.

A skill, a hook message or a project snippet names these commands, never
a path through `$AGENT_FABRIC_ROOT`. `tests/test_session_commands.py`
fails on any session-facing text that runs a command through the
variable, and on a listed command that is not an executable script.

Hooks are not affected: the harness runs them without a permission
check, and they keep resolving the fabric from their own location.
