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
