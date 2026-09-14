---
role: "backend-dev"
class: domain
description: Guard middleware that throws must be registered after the problem-details middleware
tier: 2
knowledge_scope: "domain-only"
distilled_at: "2026-08-10"
origin:
  - clone_id: "clone-74e1ddd4096a45ce"
    host: "develop-qzapp"
  - clone_id: unresolved
    host: "develop-qzapp"
derived_from:
  - 9425f2439787f356
  - a62c7a624f4de501
  - e3d01a5fc02b0e55
---

## Guard middleware that throws must be registered after the problem-details middleware

A custom guard middleware that rejects requests by throwing the project's typed exception (rather than writing the HTTP response directly) must be registered *after* the problem-details middleware in the ASP.NET Core pipeline — reversing the order silently breaks RFC 9457 error-envelope formatting for that middleware's rejections, since the problem-details middleware is what catches that exception and renders it. a header-guard middleware (rejecting a client-class credential header outside its one allowed endpoint) throws rather than short-circuiting the response specifically so the standard error envelope still applies to its 400s.

*References: ADR-025*
