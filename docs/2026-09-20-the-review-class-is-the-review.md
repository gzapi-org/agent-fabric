# The review class's review is the review

*2026-09-20 — the owner's decision, applied at fabric level.*

## What changed meaning

Until this day the fabric's tooling called the review class's blind
review a **substitute**: `post-substitute-review.sh` posted it, the
reader counted it on a "substitute reviews" line worth less than "a
real review", the class's agent file described it as the reviewer for
"a PR the automated reviewer will not cover", dispatched when the
status tool reported a DECLINE. That framing came from the first
managed project, where an automated reviewer ran on every pull request
and the review class covered its outages.

That automated reviewer is deactivated. The review class's review is
now **the** review of a pull request — the one dispatched on every
head, the one that judges a finding before it is answered, the one
that re-reviews a fix range, and the one the arm gate counts. Nothing
in the fabric calls it a substitute or a fallback, because there is
nothing it substitutes for.

## What moved

- `runtime/github/post-review.sh` (was `post-substitute-review.sh`)
  posts the review as a review object at the head, first line
  `<!-- agent-fabric-review v1 -->`. The body names the method — a
  blind review, briefed with facts — and carries no disclaimer.
- `runtime/github/pr-review-status.sh` reports `blind reviews` beside
  `independent reviews` and `self reviews`; a head is reviewed when an
  independent or a blind review targets it. `pr-gate.sh` reads that
  line.
- The reader **assumes no automated reviewer**. The machinery that
  read one's verdict comments, declines and asks stays, generic and
  off: `AGENT_FABRIC_VERDICT_AUTHORS` (a JSON array, default `[]`),
  `AGENT_FABRIC_REVIEWER_REFUSAL_RE` and `AGENT_FABRIC_REVIEW_REQUEST_RE`
  (regexes, default empty). A project that runs one sets the three in
  its integration forwarder (`projects/<id>/integration/gh/`); a value
  that cannot be applied is refused at start (exit 2), never read as
  "none". `--automated-only` is gone with the reviewer it narrowed to.
- The class's description — `runtime/claude-code/agents/code-review.md`,
  `routing/capabilities.json`, `policies/subagent-dispatch/SKILL.md`,
  the briefs that named it — says what it is now.

## The two markers

Reviews posted before this day carry `<!-- agent-fabric-substitute-review v1 -->`
(the fabric's) or a project's own earlier marker. Both keep counting:
the fabric's is built into the reader, a project's is named by its
forwarder in `AGENT_FABRIC_LEGACY_REVIEW_MARKERS`. **Sunset:** the
built-in legacy marker goes when no open pull request in any managed
repository carries a review posted before 2026-09-20; a project drops
its own from the forwarder on the same test for its repository. Until
then a reader without them would report real coverage as "0 reviews",
the defect the marker exists to end.

## A marker is not a signature (2026-09-25)

The marker says what a review is, never who posted it. It is published
in every tree that carries `post-review.sh`, so on a public repository
any account can post a review whose first line is the marker. Until
2026-09-25 the reader counted such a review as the head's coverage,
indistinguishable in the report from the one the session posted.
Coverage now needs both: the marker, and a poster who is the PR author
(the account every session pushes and posts as) or a login in
`AGENT_FABRIC_REVIEW_POSTERS`. Any other marked review is listed under
"marked, other login", with its login, and is not coverage. Every blind
row names its login too, so a reader checks the poster without leaving
the report. The same holds for an unmarked review: it counts as
independent only from the repository's owner, an organisation member or
a collaborator (GitHub's `author_association`), or from a reviewer the
project names in `AGENT_FABRIC_VERDICT_AUTHORS`. Anyone else's review is
listed as "not trusted" and is not coverage. Binding only the marked
review would have left a stranger free to cover a head by leaving the
marker out. `--json` carries the same answer as fields, for a caller
that arms on it.

## Why "blind" survives as a word

"Review" is the noun everywhere. "Blind" appears only where the method
matters to the reader: the coverage line (so provenance survives beside
independent reviews) and the posted body's first sentence (so a person
reading the PR knows the reviewer saw the range and a brief of facts,
not the author's reasoning). It describes how the review was made, not
what it is worth.
