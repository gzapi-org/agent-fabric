# Provisioning — what an agent account needs from the control plane

An agent is a Linux login. Giving a role its own account is a host
action, and most of it is the deployment's (SSH and forge credentials,
commit signing, the toolchain of the projects it will work on, data
areas): that runbook lives with the deployment. This is the part that is
the control plane's, the same for every deployment and every project.

## The layout every account has

```text
~/projects/
├── CLAUDE.md                 workspace instructions: one line and an import
│                             of agent-fabric/CLAUDE.md (written by bootstrap)
├── .claude/settings.json     the hooks, wired to the checkout below (bootstrap)
├── agent-fabric/             this repository — a checkout per account
└── <working copy>/…          the managed repositories the account works in
```

The account name identifies the agent (`bin/fabric-whoami`); the
directory it stands in identifies context, never identity.

## The steps, per account

1. **Clone agent-fabric** beside the working copies:
   `git clone git@github.com:gzapi-org/agent-fabric.git ~/projects/agent-fabric`.
2. **Run bootstrap** as the account:
   `~/projects/agent-fabric/runtime/claude-code/bootstrap.sh`. It writes
   the workspace `CLAUDE.md` and `.claude/settings.json`, installs
   user-scope the `/role` command, the capability-class agent files, the
   review class's Bash fence and the `subagent-dispatch` skill, and sets
   `core.hooksPath` on this checkout and on every registered working copy
   beside it (the attribution ban and the `.agent-fabric/` fence).
   Idempotent; re-run after pulling.
3. **Bind a role once** from inside a working copy: `/role <role>`
   (`tools/fabric/role.py`). The binding lives under
   `${XDG_STATE_HOME:-~/.local/state}/agent-fabric/agents/<login>/`;
   the broker launcher refuses to run without one.
4. **For the broker path**, `OPENROUTER_API_KEY` in the account's shell
   environment (never in a file this repository tracks) and the `ori` CLI
   on its `PATH`; then `runtime/openrouter/launch` from the working copy
   (`runtime/openrouter/README.md`).

`runtime/claude-code/provision-capability-classes.sh` does step 2's
agent-file part for every account at once, as root, when the class files
change. `moveto/` opens a shell as another account in its working copy.

## What does not transfer between accounts

Session memory is the account's (`~/.claude/projects/…/memory/`); a drain
distils it into the corpus, nothing copies it across. Runtime bindings,
role history and local model overrides are per account for the same
reason: they say what *this* agent is doing.
