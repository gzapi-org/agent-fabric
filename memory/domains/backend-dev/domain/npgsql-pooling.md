---
role: "backend-dev"
class: domain
description: "NpgsqlDataSource, not raw NpgsqlConnection, is what OTel query-span instrumentation hooks"
tier: 2
knowledge_scope: "domain-only"
distilled_at: "2026-08-10"
origin:
  - clone_id: "clone-8a543ee5423d427c"
    host: "develop-qzapp"
  - clone_id: unresolved
    host: "develop-qzapp"
derived_from:
  - 33454e9bbd7cfc50
  - b9efb6c3bebe4fae
  - c802541cd313b2b5
  - ce3b041d011223f9
---

## NpgsqlDataSource, not raw NpgsqlConnection, is what OTel query-span instrumentation hooks

Npgsql 9.x should be wired through a shared `NpgsqlDataSource` (built once per connection string via `NpgsqlDataSourceBuilder`, cached in a `ConcurrentDictionary<string, NpgsqlDataSource>`) rather than `new NpgsqlConnection(connectionString)` per call. The raw-connection form still works and still pools, but it silently opts out of `.AddNpgsql()`'s OTel query-span instrumentation, which only hooks the data source object, not ad-hoc connections. Keying the cache by connection string (instead of a single global instance) matters under Testcontainers specifically: each test database naturally gets its own pool instead of either multiplying pools per factory instance or forcing every test database to share one pool meant for a single production connection string.

*References: ADR-021*
