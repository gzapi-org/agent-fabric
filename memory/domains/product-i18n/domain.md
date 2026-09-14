---
role: "product-i18n"
class: domain
description: Intl.RelativeTimeFormat can silently fall back to another locale instead of erroring
tier: 2
knowledge_scope: "domain-only"
distilled_at: "2026-08-10"
origin:
  - clone_id: "clone-8a543ee5423d427c"
    host: "develop-qzapp"
  - clone_id: unresolved
    host: "develop-qzapp"
derived_from:
  - 101990863729552d
  - 52e5c950265c929b
---

## Intl.RelativeTimeFormat can silently fall back to another locale instead of erroring

A browser's/runtime's ICU data does not necessarily cover every locale a product ships. When a locale is missing, `Intl.RelativeTimeFormat.supportedLocalesOf([locale])` correctly returns an empty array, but simply constructing `new Intl.RelativeTimeFormat(locale)` anyway does not throw: `resolvedOptions().locale` silently reports whichever fallback locale the runtime chose (commonly `en-US`), and every string that formatter produces renders in that fallback language with no error, warning, or signal reaching application code. This was confirmed for `ka-GE` (Georgian) specifically, while `ru-RU` and `en-US` both resolved correctly — so locale coverage in built-in Intl formatters cannot be assumed uniform across a product's locale set and must be spot-checked per formatter (RelativeTimeFormat, DateTimeFormat, NumberFormat, etc. can each have different coverage) rather than inferred from one working.
