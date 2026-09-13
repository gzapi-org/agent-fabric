# Runtime boundary

Runtime configuration belongs to the local agent instance, not to GZCOORD/1 messages.

It may contain:

- model provider and model name;
- subagent limits and capabilities;
- local tool permissions;
- local transport selection;
- process launch configuration.

The protocol may announce semantic `CAPABILITIES`, but it MUST NOT expose the concrete model/provider, local working directory, credentials, token budgets or subagent implementation details.

The stable logical identity is `host/instance`. A local filesystem path is never an address.

## Role sourcing

GZCoord keeps no role catalog of its own (`protocol/SPEC.md` §4) — a
GZAPP deployment does not need a second one. The `ROLE` announced in
`HELLO` MUST be the `id` (slug) of the role this working copy holds in
`.roles/taxonomy.json` — `backend-dev`, `flutter-dev`, `architect-cto` —
never its title; a `TO-ROLE` MUST be a slug from the same file. The
title stays in the catalogue for reading. The address is not bound to
the role: a clone is usually named for the role it was launched as
(`architect-cto-01`, `gzapp-gzcoord-coordinator`), but a role can change
without the address changing (`protocol/SPEC.md` §4), and a clone named
otherwise (`gzapp-claude2`) is as much a session as any. Which role this
working copy holds is `.roles/.instance/state.json`, written by `/role`
and read by `tools/roles/switch.py --status`; `role.name`/`specialties`/
`capabilities` in local config follow the same source and are never
authored independently of it. `scripts/gzmsg.mjs` finds the taxonomy by
walking up from the working directory and enforces both slug rules;
`hello` derives `--role` when it is omitted — from the active-role
record, else from a slug the address carries — so the one spelling a
peer can match is the default, and it warns when an address names a
role other than the one announced. A record that says nothing usable
(unreadable, or without a `role`) warns and falls back; a record naming
a role the catalogue does not have is refused outright, naming the file
and asking for an explicit `--role`, because a clone asserting a role
the deployment does not know is a state to fix, not to guess past.
