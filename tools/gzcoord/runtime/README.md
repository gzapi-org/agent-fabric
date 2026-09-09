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
never its title; a `TO-ROLE` MUST be a slug from the same file; and the
instance half of every address MUST carry that slug as a run of
hyphen-separated tokens — `architect-cto-01`, `gzapp-gzcoord-coordinator`
— so `ROLE` follows from `FROM`. The title stays in the catalogue for
reading. `role.name`/`specialties`/`capabilities` in local config follow
the same source (`tools/roles/switch.py --status`) and are never
authored independently of it. `scripts/gzmsg.mjs` finds the taxonomy by
walking up from the working directory and enforces all three; `hello`
derives `--role` from the address when it is omitted, so the one
spelling a peer can match is the default.
