# GZCoord in the gzapp repository

The protocol and its runtime live in agent-fabric
(`communication/gzcoord/`); nothing is copied into gzapp. What gzapp
carries is its own integration: the snippet its root `CLAUDE.md`
includes, the hook that drains the inbox at session start, the relay one
of its agents hosts, and this directory's `config.json`, which tells the
inbox which relay, channel and token location apply to a gzapp working
copy.

Do not create a nested Git repository, and do not vendor the subsystem.

1. Add the contents of [`CLAUDE.snippet.md`](CLAUDE.snippet.md) to gzapp's
   root `CLAUDE.md` (or reference it from the project rules if that
   repository already has a modular rules structure).
2. Wire the `SessionStart` hook in gzapp's `.claude/settings.json` at
   `node "$AGENT_FABRIC_ROOT/communication/gzcoord/scripts/inbox.mjs"`
   (`agent-fabric/runtime/claude-code/bootstrap.sh` writes the workspace
   copy with the path substituted; a project keeps its own for sessions
   launched inside the working copy, resolved as
   `$CLAUDE_PROJECT_DIR/../agent-fabric/…` — hook commands run before
   the fabric hook has exported `AGENT_FABRIC_ROOT` into the session
   shell, so a hook line never relies on the variable).
3. Create the concrete instance configuration outside Git, for example
   `~/.config/gzcoord/gzapp.yaml`, from
   `communication/gzcoord/config/instance.example.yaml`. `role.name`
   is the slug of the role the agent currently holds — `/role` writes it
   to the agent's runtime binding — never authored independently of
   agent-fabric's `identities/roles/catalog.json`.
4. Relay hosting: [`BRIDGE-RELAY-SETUP.md`](BRIDGE-RELAY-SETUP.md). The
   relay's runtime — venv, token, database, log — lives in the hosting
   workspace's `projects/.gzcoord/`, outside every repository. Every
   account gets the token as `CLAUDE_BRIDGE_AUTH_TOKEN` in its environment
   from its own Doppler config (`bin/fabric-secrets sync`,
   `runtime/provisioning/README.md` "Secrets"); the gitignored
   `.claude/settings.local.json` `env` entry and `infra/local/.env.local`
   remain accepted for a clone provisioned by hand.

The agent's address is `<host>/<login>` (SPEC §3.1): the account the
session runs under, not the working-copy directory. `gzapp-claude2` and
`gzapp-gzcoord-coordinator` under the shared account are therefore one
agent to their peers (`user`); the provisioned accounts
(`architect-cto-01`, `backend-dev-02`, …) keep the addresses they already
had.
