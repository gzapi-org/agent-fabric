# routing-distinct

The routing column and effort file as they stood on 2026-09-24. On that
day every class on plain claude had a different model (Haiku 4.5,
Sonnet 5, Opus 5.5, Fable 5.1, and `claude-opus-5[1m]` for the review
class), and the levels ran from low to xhigh. On 2026-09-25 the owner
moved every class to Opus 5.5 at medium. A test of the mechanics (layering,
seeding, the alias exports, the reviewer's own pin and effort) needs
classes it can tell apart, so it runs on this frozen copy.
`tests/test_routing.py` asserts the committed policy itself.
