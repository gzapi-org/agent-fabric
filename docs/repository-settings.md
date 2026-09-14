# Repository settings — what lives on GitHub, not in git

Recorded 2026-09-14, when `gzapi-org/agent-fabric` was recreated as a public
repository with rewritten history. Everything the CI needs is
in the tree (`.github/workflows/ci.yml`, `tests/run.sh`, `policies/`); this
file is the rest, and `tools/fabric/github-repo-settings.sh` reapplies it.

## The repository

| setting | value |
|---|---|
| name | `agent-fabric` (org `gzapi-org`) |
| visibility | **public** |
| description | Control plane for the agents working on sibling repositories: identities, roles, memory, model routing, GZCoord |
| default branch | `main` |
| features | issues on, projects on, wiki on, discussions off |
| merge methods | merge commit, squash and rebase all allowed; merge-commit title `MERGE_MESSAGE`, message `PR_TITLE`; squash title `COMMIT_OR_PR_TITLE`, message `COMMIT_MESSAGES` |
| auto-merge | off; delete branch on merge off; "always suggest updating branches" off |
| web commit sign-off | not required |
| topics | none |

## Rules

None on GitHub: no rulesets, no branch protection, no merge queue. The
repository is read-only for every role but `fabric-coordinator` by the
git hooks and the CI tripwire (`policies/AUTHORITY.md`), and its commits
go to `main` directly by that role. If a branch rule is ever wanted, the
required check context is `ci / guards-and-suites`.

## Actions

| setting | value |
|---|---|
| Actions | enabled; all actions and reusable workflows allowed; SHA pinning not required |
| default workflow permissions | read-only; Actions may not approve pull requests |
| secrets | **none** — the workflow needs no credential |
| variables | none |
| environments | none |
| self-hosted runners | none |

## Access

One collaborator, the owner. No teams, no webhooks.

## Elsewhere, about this repository

- A managed project's CI checks this repository out to run the
  `.agent-fabric/` guard and lint against its tree
  (`.github/workflows/_ban-checks.yml` in gzapp). The repository is
  public, so that checkout needs no credential.
- Every account on the developer host holds a clone at
  `~/projects/agent-fabric` with `core.hooksPath` set by `bootstrap.sh`;
  after a history rewrite each is reset onto the new `main`.
