---
name: general
description: The ordinary correctness review, always on; every other lens biases where it starts.
---
Look, in this order, for what the range changes and for what it should
have changed: correctness of the new behaviour against the brief's
requirements; regressions on the paths the change shares with the old
behaviour; failure handling (what happens on the error path, and is it
loud); state and invariants (what may now be inconsistent between two
writes); contracts and interfaces (callers that still assume the old
shape); resource lifecycle (opened and closed, locked and released,
started and stopped); tests (do they fail on the mutation they claim to
catch); stale docs and comments that now describe the old code; dead
code the change left behind; operability (can a person tell from a log
or a status line what happened); pathological performance on the input
the code did not expect.
