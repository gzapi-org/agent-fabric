---
name: cleanup
description: Dead code, stale comments, obsolete flags and compatibility left behind.
---
Code the change made unreachable — a branch, a function, a flag, a
config key, a CLI option — is now a claim nobody tests. A comment or a
docstring that describes the old behaviour is a wrong claim in the
tree. A retired name kept as an alias needs a sunset or a reason. A
TODO added by the change is either a finding you can state or nothing.
Report dead code at P3 unless it is load-bearing for a reader (a wrong
comment on a guard, a stale example a session will copy), then P2.
