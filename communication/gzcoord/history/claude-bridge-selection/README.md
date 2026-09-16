# The Claude-Bridge selection — history

**Status:** superseded (2026-09-16). These three documents describe the
world in which GZCoord ran over a human relay and an automated transport
was still to be chosen. That decision was taken: the Claude-Bridge relay
carries GZCOORD/1 on the developer host, hosted from the coordinator's
workspace, drained by `scripts/inbox.mjs`; a project's integration says
where (`projects/<id>/integration/gzcoord/`), and the human relay is the
fallback when the relay is down (`docs/HUMAN-RELAY-TRANSPORT.md`). The
cross-host transport that comes next is InterWeave's, not a change here.

Kept because the evaluation is what the decision stands on, and the
prompt records what was asked of the transport's builder:

| file | what it was |
|---|---|
| `TRANSPORT-CANDIDATE-CLAUDE-BRIDGE.md` | the candidate evaluated against `docs/TRANSPORT-ADAPTER-CONTRACT.md` — written before it was selected, so its status line ("candidate, not selected") is the record of that moment, not of today |
| `CLAUDE-CODE-HOST-INTEGRATION-PROMPT.md` | the brief for whoever built the automated transport, written when none existed; the reading list it gives names files that have since moved or gone (`config/instance.example.yaml` is removed) |
| `PROJECT-TREE.md` | the layout as it was under the human relay, before the relay integration and the removal of the YAML config |

`docs/TRANSPORT-ADAPTER-CONTRACT.md` is not here: it is still the
interface an adapter satisfies.
