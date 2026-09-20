#!/usr/bin/env bash
# runtime/github/test_commit-class.sh (lifted from the first managed project's tools/gh/ on 2026-09-19 — the commit names it; general to every managed project, whose own tools/gh/ copy is a forwarder through projects/<id>/integration/gh/) — the shared work/fix/merge classifier,
# on the subjects the count rule was calibrated against.
set -u
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=commit-class.sh
. "$SCRIPT_DIR/commit-class.sh"
failures=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1" >&2; failures=$((failures + 1)); }
expect() {  # expect <class> <parents> <subject> [<answers trailer value>]
    local got; got="$(commit_class "$2" "$3" "${4:-}")"
    if [[ "$got" == "$1" ]]; then pass "$1: $3"; else fail "expected $1, got $got: $3"; fi
}
echo "commit-class: merges by parent count, whatever the subject"
expect merge "aaa bbb" "Merge origin/main"
expect merge "aaa bbb" "fix: not a merge subject but two parents"
expect work  "aaa"     "Merge-shaped subject with one parent is work"
echo "commit-class: a review fix names a review AND answers one"
expect fix "aaa" "review F4: the guard reads the count from the file"
expect fix "aaa" "pr-gate: address the blind review of #878"
expect fix "aaa" "review fixes: the three nits on the README"
expect fix "aaa" "tests: the re-review findings on 8c4ae884"
expect fix "aaa" "docs(advertiser): the venue edit rows name 3.1.0 (#861 F6)"
expect work "aaa" "docs(advertiser): the venue edit rows name 3.1.0 (F6)"
echo "commit-class: the Answers: trailer wins over any subject (seq 2821: three fixes with no review word on #892)"
expect fix  "aaa" "db: 0055's guard was too broad and stopped the file re-applying" "F3"
expect fix  "aaa" "docs(adr): ADR-071 §2.4 — a backfilled row with no known severance time keeps its updated_at" "PE-6, PR-1"
expect fix  "aaa" "feat: anything at all" "re-review F1 (the rationale)"
echo "commit-class: a subject that OPENS with the review word is an answer with no label, no fix word, no #PR (#894 review F3)"
expect fix "aaa" "review: the classifier itself"
expect fix "aaa" "re-review: wording only"
echo "commit-class: the review word as a COMPONENT's name is not an opener (agent-fabric #25: two work commits read as fixes)"
expect work "aaa" "review class: described as the review everywhere, not a stand-in"
expect work "aaa" "review brief: the lens vocabulary lists every lens"
expect fix  "aaa" "review tooling: the review round's fixes — configuration refused loudly"
# ("re-review — wording only" is NOT an opener-only case: re-review sits in the
# answer-word list too, so the fallback rule reads it as a fix as well.)
expect work "aaa" "reviewing the roster is the admin's act"
expect work "aaa" "db: 0055's guard was too broad and stopped the file re-applying" ""
expect work "aaa" "db: 0055's guard was too broad and stopped the file re-applying" "   "
expect merge "aaa bbb" "Merge origin/main" "F3"
echo "commit-class: labels of every shape the team writes (seq 2736: PE-6 and PR-1 read as work on #883)"
expect fix "aaa" "review PE-6: the pre-registered seed has one home"
expect fix "aaa" "review PR-1: the SQL belt pins all five statuses, rejected included"
expect fix "aaa" "review P3-1/P3-3/PE-5: the pre-registered row is the applicant's own"
expect fix "aaa" "re-review G2: the pattern alongside minLength"
expect fix "aaa" "docs(advertiser): no sentence left saying the address has no clear (#861 G1/G2)"
expect fix "aaa" "the review's PE-2 on the seed helper"
expect work "aaa" "docs(adr): ADR-021 §2.15 R16 — attribution resolves, never mints (#861)"
expect work "aaa" "test doc: SeedPreRegisteredApplicant's summary sits on the helper again"
expect work "aaa" "driver review: rejection ends the applicant's own lifecycle (ADR-071 §2.4)"
echo "commit-class: a bug fix, a review word alone, a fix word alone, a label alone is work"
expect work "aaa" "fix(scope): the nap is clamped to what is left"
expect work "aaa" "admin driver review: approving a driver reads the roster"
expect work "aaa" "the review decision's reason is persisted"
expect work "aaa" "wait-merged: only PRIVATE repositories' minutes count"
echo
if [[ $failures -eq 0 ]]; then echo "test_commit-class: OK — all assertions passed."; else echo "test_commit-class: FAILED — $failures assertion(s)." >&2; exit 1; fi
