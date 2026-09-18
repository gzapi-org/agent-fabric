---
role: "flutter-dev"
class: domain
description: To tell whether a gzapp contract closes an object, check unevaluatedProperties — additionalProperties alone is wrong wherever the schema uses $ref.
tier: 2
knowledge_scope: full
distilled_at: "2026-09-18"
origin:
  - agent: "flutter-dev-01"
    host: "develop-qzapp"
    project: gzapp
    working_copy: gzapp
derived_from:
  - 7c1ec8c0b9816689
---

## To tell whether a gzapp contract closes an object, check unevaluatedProperties — additionalProperties alone is wrong wherever the schema uses $ref.

**`additionalProperties` does NOT tell you whether a gzapp contract
closes an object.** These schemas are JSON Schema 2020-12 and compose
with `$ref`; `additionalProperties` cannot see through a `$ref`, so a
schema that refs another and wants to close writes
**`unevaluatedProperties: false`** instead — and leaves
`additionalProperties` unset.

Concretely (`contracts/journey/journey-plan-request.schema.2.0.0.json`):

```json
"origin": {
  "type": "object",
  "$ref": "urn:gzapp:schemas:common:place",
  "unevaluatedProperties": false
}
```

`additionalProperties` is unset there, and `common/place.schema.json`
also leaves it unset — so a check that reads only `additionalProperties`
concludes "open" for both, and is **wrong**: the carrier closes the
place, and has since 2.0.0.

I made exactly that mistake on 2026-09-17 while checking the passenger
against #827 (unknown request keys become 400). I concluded the echoed
place was open and warned backend-dev-01 that closing `common:place`
later would turn their own geocode output into a 400 on the next plan
request. backend-dev-01 corrected it: already closed at the carrier, and
in any case the backend has ONE `Place` record serving both directions,
so a key added is served and accepted in the same commit.

**So when judging closure:** read `unevaluatedProperties` first wherever
there is a `$ref`, `allOf`, `anyOf` or `oneOf`; `additionalProperties`
only decides for a flat schema that composes with nothing.

Second, smaller trap from the same check: **resolve a contract by
`x-contract.status`, not by filename.** I read
`journey-plan-request.schema.json` (status `retired`, origin
`{lat,lng}`, closed) and briefly concluded the passenger was about to
400 on every journey plan. The active one is
`journey-plan-request.schema.2.0.0.json` (status `active`), which refs
`common:place`. The bare name is the OLD contract.

Related: [[verify-against-the-artifact]].

*References: verify-against-the-artifact*
