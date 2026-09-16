---
name: incomplete-migration
description: The negative space of a change — what should also have moved and stayed behind.
---
For everything the range renames, replaces, retires or relocates, look
for what still points at the old thing: a second call site of the same
shape; a script, hook or Makefile target that still names the old path;
a doc, README or comment that teaches the old flow; a test that pins the
old behaviour and now passes for the wrong reason; a configuration key
the new code no longer reads, still set somewhere; a "transition" or
"legacy" branch that was meant to go and stayed; a forwarder or alias
kept "for now" with no sunset; an installed copy (under /usr/local, in
a home directory, in another checkout) that the repository moved ahead
of. A migration is complete when nothing in the tree, the docs or the
hosts still describes the world before it.
