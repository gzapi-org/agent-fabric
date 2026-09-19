# Code as memory: what a comment is for

The owner's policy for every repository the fabric coordinates, given
2026-09-19; binding on every role and every coding class, and checked
by the review class. It is pointed to from `CLAUDE.md` §Working here,
which every managed project's own `CLAUDE.md` includes.

The goal is not more comments, and not narration of what the code
visibly does. The goal is to preserve the engineering reasoning a
future maintainer — a person, or an agent session that has none of the
conversation in which the code was written — cannot reconstruct from
the code alone.

## 1. Self-documenting code first

Clear names, types, interfaces, functions, modules, tests and structure
carry the *what* before any comment does. A comment that restates what
the code visibly does adds noise, spends context, widens the diff and
goes stale:

```python
# Increment the counter
counter += 1
```

## 2. Comment why, not what

A comment preserves what the code cannot say for itself. It earns its
place for:

- a non-obvious design decision;
- an invariant later changes must keep;
- protocol semantics;
- a security assumption;
- a concurrency assumption;
- a distributed-system constraint;
- a compatibility requirement;
- platform-specific behaviour;
- an interoperability constraint;
- an intentionally unusual implementation choice;
- a performance trade-off;
- a workaround for an external system or library;
- a case where the apparently simpler implementation would be wrong;
- a rejected alternative a future maintainer would otherwise be likely
  to reintroduce;
- behaviour that must stay as it is even where static analysis or a
  superficial refactoring would suggest otherwise.

```python
# Keep retry state process-local.
# Sharing it between workers would couple independent agent executions
# and could cause one worker's failures to suppress another worker's retries.
```

## 3. Write for the agent with no session context

The next engineer or agent to change this code has the repository, its
tests and its documentation — and not the conversation in which the
decision was made, nor any memory of why the implementation was chosen.
Leave enough reasoning that they need not rediscover the decision.

The test: **if removing this explanation would make a competent future
engineer or coding agent likely to misunderstand, simplify incorrectly
or reverse the decision, keep it.**

## 4. Comments are persistent engineering memory

A good comment is part of the project's memory, not its cosmetics; it
exists to lower the cost of every later investigation. Never trim a
useful comment to save tokens in the session that writes it: a small
saving now is a larger investigation in every session after.

## 5. Explicit reasoning is a correctness check

For code that is genuinely non-obvious, writing down why it is the way
it is checks the writer's understanding. An agent that cannot state
clearly why an unusual constraint or implementation exists should
reconsider whether it understands the change. Not prose for its own
sake — the relevant reasoning, made explicit.

## 6. Prefer the stronger executable form

Where a piece of information belongs, in order of preference:

```text
code and naming
  → types and interfaces
    → assertions and invariants
      → tests
        → a local comment
          → module-level documentation
            → an ADR or architectural document
```

An invariant a type can enforce goes in the type; behaviour a test can
verify gets the test; reasoning about one implementation detail sits
beside it; a decision that spans modules or the architecture goes in an
ADR or its equivalent. A comment complements an executable constraint,
never replaces one.

## 7. No stale comments

Whoever changes code reads the comments around it and updates or removes
any whose assumption is no longer true. A misleading comment is worse
than none. Comment correctness is part of code correctness, and a
reviewer treats it so.

## 8. Preserve intentional oddities

Code that a future agent would read as redundant, over-complicated,
inefficient, strangely ordered, unusually defensive or contrary to
convention is exactly the code an autonomous refactoring "improves" by
removing required behaviour. Where the odd structure is intentional,
say why beside it — unless an applicable test, invariant or ADR already
says it clearly.

## 9. Reviews apply the policy

The review class asks, of every range (`runtime/claude-code/agents/code-review.md`):

- Is there a comment that only narrates the code and should go?
- Is there a non-obvious decision whose rationale is missing?
- Is an important invariant represented in a test, a type or an
  assertion where it could be?
- Could a future agent misunderstand or wrongly refactor this?
- Is every existing comment still accurate?
- Does an architectural decision belong in an ADR rather than only in
  a comment?

Comment density measures nothing. The target is information per
comment.

## 10. The repository is maintained by fresh sessions

Optimise for long-term agentic maintenance: the repository must be
understandable to a person and to a coding-agent session that starts
from nothing but the tree.
