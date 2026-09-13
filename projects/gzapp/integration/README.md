# projects/gzapp/integration/

How the gzapp repository is wired to agent-fabric. Everything here is
gzapp-specific by design and is the only place gzapp may be named outside
`memory/projects/gzapp/` and `projects/gzapp/taxonomy.json`.

- `gzcoord/` — gzapp's use of the GZCoord protocol: the relay it hosts
  (`BRIDGE-RELAY-SETUP.md`), the channel and token locations
  (`config.json`), the subsystem context its sessions read (`CLAUDE.md`)
  and the snippet its root `CLAUDE.md` carries (`CLAUDE.snippet.md`).
- `gh/` — the pull-request tooling gzapp's workflow uses (`pr-reply.sh`,
  `pr-sessions.sh`). It reads the branch convention
  `<host>/<agent>/<type>/<desc>` and the legacy working-copy registry
  under `docs/migration/legacy-registry/` to attribute branches that
  predate the login identity model.

What gzapp itself still has to carry after the embedded copies are
removed is listed in `docs/migration/REMOVAL-PLAN.md`.
