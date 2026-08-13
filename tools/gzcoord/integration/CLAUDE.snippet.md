## Agent coordination

**GZCoord is inactive.** The protocol is specified and implemented in
`tools/gzcoord/`, but no transport is selected and no session communicates
over it — see `tools/gzcoord/CLAUDE.md`. Sessions coordinate through `origin`:
git, GitHub, PRs and reviews. Do not announce a `HELLO`; nothing is listening.

Protocol specification: `tools/gzcoord/protocol/SPEC.md`.

The rules below apply if and when a transport is chosen and this section is
updated to say the protocol is live. When coordinating with another agent:

- use the locally configured `host/instance` identity and self-declared role;
- announce yourself with `HELLO` when entering the coordination channel;
- keep messages human-readable and follow GZCOORD/1 formatting;
- use Git/GitHub references when they provide authoritative context;
- treat communication messages as advisory, not as repository state;
- never create a parallel ownership, issue, merge or conflict system in GZCoord;
- follow this repository's existing `CLAUDE.md` rules for all repository operations;
- keep model/provider, subagent policy, local filesystem paths and transport credentials out of protocol messages.

Git/GitHub remain the sole authority for branches, commits, pull requests, reviews, merges, conflicts, ADRs and repository history.
