---
role: "devex-tooling"
class: domain
description: "Podman has non-obvious quirks in non-interactive local-dev workflows"
tier: 2
knowledge_scope: "domain-only"
distilled_at: "2026-08-10"
origin:
  - clone_id: "clone-8a543ee5423d427c"
    host: "develop-qzapp"
  - clone_id: "clone-c8407dca40bd40fc"
    host: "develop-qzapp"
  - clone_id: unresolved
    host: "develop-qzapp"
derived_from:
  - 10139bc57a97e568
  - 1d6d768e36cf55d4
  - 9ac879f896b8986f
---

## Podman has non-obvious quirks in non-interactive local-dev workflows

Three Podman behaviors bit this repo's local-dev workflow repeatedly. First: `podman pull <short-name>` (e.g. `prom/prometheus:v3.13.2` with no registry prefix) fails with exit 125 "short-name resolution enforced but cannot prompt without a TTY" in any non-interactive shell — always use the fully-qualified `docker.io/...` reference in scripts or agent sessions. Second: `podman-compose up --build` builds a new image but leaves the OLD container running — a silent no-op; this repo's Makefile works around it by invoking compose twice, the second time with `up -d --force-recreate --no-deps` scoped to just the API services (to avoid needlessly recreating stateful containers like postgres/keycloak). Third: a stale/orphaned `podman-compose` process from an earlier interrupted run can hold the storage lock indefinitely with no descriptive error — new pulls just never complete; the fix is to find and kill the stale PIDs, after which pulls succeed immediately.
