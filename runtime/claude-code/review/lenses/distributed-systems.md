---
name: distributed-systems
description: Two hosts, no shared filesystem, partial failure, and who reports what about where they are.
---
Assume the coordinator and the agent are on different machines. A path
that means something only on one host, a file read where it was
written by another process, a `getent` or a passwd lookup for an
account that exists elsewhere, an environment that was set on the wrong
side of an ssh — each works on one host and fails on two. A command
that runs remotely must carry its arguments whole (quoting) and its
secrets over stdin, never in argv. A host must report itself; the
caller never assumes the name of the machine it is not on. Partial
failure is the normal case: what state does a dropped connection leave,
and does a retry converge? The same-host path must keep working when
the remote one is added.
