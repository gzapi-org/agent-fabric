## Agent coordination

This repository uses the GZCoord human-readable agent communication protocol.

Protocol specification: `tools/gzcoord/protocol/SPEC.md`.

When coordinating with another agent:

- use the locally configured `host/instance` identity and self-declared role;
- announce yourself with `HELLO` when entering the coordination channel;
- keep messages human-readable and follow GZCOORD/1 formatting;
- use Git/GitHub references when they provide authoritative context;
- treat communication messages as advisory, not as repository state;
- never create a parallel ownership, issue, merge or conflict system in GZCoord;
- follow this repository's existing `CLAUDE.md` rules for all repository operations;
- keep model/provider, subagent policy, local filesystem paths and transport credentials out of protocol messages.

Git/GitHub remain the sole authority for branches, commits, pull requests, reviews, merges, conflicts, ADRs and repository history.
