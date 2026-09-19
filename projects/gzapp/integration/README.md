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
- `gh/` — forwarders to the pull-request tooling, which is general and
  lives in `runtime/github/`: the repository comes from the working copy
  it runs in, the session from the login, and a project's record of the
  directory-bound clones it once had — used to tell an heir from an
  orphan on older branch prefixes — from `legacy_clone_bindings` in
  `projects/registry.json`. `pr-reply.sh` and `pr-sessions.sh` (2026-09-14)
  forward and nothing more. `pr-gate.sh`, `pr-review-status.sh`,
  `post-substitute-review.sh` and `commit-class.sh` (2026-09-19) are
  where this project's OWN names for the tools live — the substitute-
  review marker its earlier reviews were posted under, which the reader
  counts only because the forwarder names it, and the `GZAPP_*`
  environment names its callers still use, mapped to the fabric's. The
  lint refuses a project's name under `runtime/`; that rule is what
  keeps the tools every project's, and this directory is the carve-out.
  gzapp's `tools/gh/` shims forward here.
