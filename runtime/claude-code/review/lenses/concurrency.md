---
name: concurrency
description: Shared state, ordering, locks, retries and what two of anything at once do to each other.
---
Two processes, two sessions, two hosts, two hooks: for every write the
change makes, who else writes the same thing, and what happens when
they interleave? A read-modify-write without a lock loses one of the
two updates. A lock taken in two orders deadlocks. A retry that is not
idempotent does the work twice. A temporary file with a fixed name
collides. A check-then-act on the filesystem races with the thing it
checked. A signal, a kill or a full disk between two writes leaves the
first without the second — what does the next run find, and does it
converge or compound?
