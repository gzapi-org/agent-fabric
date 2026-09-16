---
name: performance
description: The input the code did not expect — unbounded growth, N+1, a full scan where an index was assumed.
---
Trace the change with the largest input it could plausibly receive: a
list that is read whole into memory, a loop that queries per row, a
regular expression on an unbounded line, a cache with no eviction, a
retry with no backoff, a file that is re-read on every call, a lock held
across I/O. A timeout that is absent is infinite. Report a performance
finding only with the input that triggers it and the resource it
exhausts; a "could be slow" without either is a Risk.
