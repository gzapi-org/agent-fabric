# projects/gzapp/integration/

How the gzapp repository is wired to agent-fabric. Everything here is
gzapp-specific by design and the only place gzapp is named in this
repository (its taxonomy, memory, remits and hygiene list are in gzapp,
under `.agent-fabric/`). gzapp's own knowledge lives in
gzapp (`.agent-fabric/memory/`), never here.

- `gzcoord/` — gzapp's use of the GZCoord protocol: the relay it hosts
  (`BRIDGE-RELAY-SETUP.md`), the channel and token locations
  (`config.json`), the subsystem context its sessions read (`CLAUDE.md`)
  and the snippet its root `CLAUDE.md` carries (`CLAUDE.snippet.md`).
- `gh/` — two compatibility forwarders only. The pull-request tooling
  (`pr-reply.sh`, `pr-sessions.sh`) is general and lives in
  `runtime/github/`: the repository comes from the working copy it runs
  in, the session from the login, and a project's record of the
  directory-bound clones it once had — used to tell an heir from an
  orphan on older branch prefixes — from `legacy_clone_bindings` in
  `projects/registry.json`. gzapp's `tools/gh/` shims still name this
  path; once they are repointed, `gh/` goes.
