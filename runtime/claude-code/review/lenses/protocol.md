---
name: protocol
description: Wire contracts, versions, adapters and the malformed message nobody expected.
---
What crosses the boundary — a schema, a message grammar, an engine's
response — is the contract; the code on either side conforms to it or
does not. A field added is a field every reader must tolerate; a field
removed is a reader that breaks; a meaning changed under an unchanged
name is the worst of both. An adapter is not the engine: the engine's
clock, units and error shapes are the engine's, and a malformed reply
is an error, never an empty result. A version bump is a compatibility
claim — name the reader it breaks. Where the brief names a contract by
path, read it and hold the code to it, not to the commit message.
