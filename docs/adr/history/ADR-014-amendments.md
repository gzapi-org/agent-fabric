# ADR-014 — amendments

The full notes; the ADR's body reads current and its Amendments table lists them.

### Amendment 2026-10-10 — A retitle replaces only the section it names; a section can be retired

Two rules move with ADR-050. Rule 4(a): the same-agent retitle replaced
every section of a topic, so a new claim that shared nothing with a topic
deleted sections it never named, measured in the 2026-10-10 drain. It now
replaces only the section the claim names by `merge_target` or shares its
cue with; a claim sharing nothing is a new topic. The assembler change is
not yet made; until it is, ADR-050 rule 11 has the drain report list every
same-agent retitle. Rule 7: a `merge_target` memory with no body retires
the named section, the route by which a record that is not a lesson leaves
the corpus (`slices.remove_sections` already exists). The retire path is
not built: the claims schema requires a non-empty body and `writer.py`
replaces the section with an empty heading, so ADR-050 rule 7 names the
three changes it needs.
