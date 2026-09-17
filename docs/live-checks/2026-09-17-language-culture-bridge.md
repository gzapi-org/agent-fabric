# The language-culture bridge, read back — 2026-09-17

`docs/language-culture-bridge.md` and the lint budget for a locale
charter rest on one measurement outside the fabric — what a Georgian
body costs in tokens — and on the read-backs below after the roll-out.
Measured on `develop-qzapp`, as login `user`, with the harness's own
`claude -p --model haiku --output-format json`.

## What a Georgian charter costs

The two bodies (frontmatter stripped) sent as a prompt after a fixed
preamble, against the preamble alone; the cost of a body is the
difference in total input (`input_tokens` + `cache_creation_input_tokens`
+ `cache_read_input_tokens`, since the harness caches its own prefix).

| body | characters | total input | body tokens | chars / token |
|---|---|---|---|---|
| preamble alone | — | 25 785 | — | — |
| `charter.md` (English, at `70fa2cb`) | 10 931 | 28 427 | 2 642 | 4.1 |
| `locale/ge/charter.md` (Georgian) | 11 041 | 33 369 | 7 584 | 1.46 |

- The rendering is the size of its source in characters (Georgian is
  compact: 1.01×) and **2.9× its tokens**. Decides: the character
  ceiling on a locale launch prompt needs little headroom
  (`launch_prompt.LOCALE_CHARS_FACTOR` stays 1.35); the token cost is
  the one the plan named ("~2–3×") and the CEO accepted for the role.
- The guess lint carried before the measurement — 2 characters a token
  and a ceiling of 1.35× the tier-1 budget (4 050 tokens) — was
  optimistic on the divisor and impossible on the ceiling: no full
  rendering of a 2 600-token charter fits 4 050 at any divisor.
  Decides: `NON_LATIN_CHARS_PER_TOKEN = 1.5`, `LOCALE_BUDGET_FACTOR = 3`
  (9 000 tokens); the first rendering lints at ~7 360.
- The launch prompt for `language-culture-ge` renders at 17 862
  characters with the English charter (ceiling 20 000) — the Georgian
  render is measured after the roll-out, below.
