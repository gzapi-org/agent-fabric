---
name: database
description: Constraints that constrain, migrations that apply, plans that hold on the major CI runs.
---
A CHECK that passes on NULL constrains nothing. A pair of columns that
must agree needs a pair constraint, not two singles. An append-only
table needs a trigger that names its table and fires on the statement
that would violate it. A migration number that collides with another
branch's merges cleanly and fails on the runner. A new index is
necessary only if the plan on the major CI actually runs needs it — a
newer major may serve the query without it, and a plan test is
seed-size-sensitive. A migration that is idempotent on the second run
is one that can be re-applied after a partial failure; one that is not
must say so.
