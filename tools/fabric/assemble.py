#!/usr/bin/env python3
"""tools/fabric/assemble.py

>>> help
Turn distiller claims into the knowledge corpus, filed by scope.

    tools/fabric/assemble.py --claims DIR --drain DIR --project gzapp --stamp DATE

Where a slice lands is decided by tools/fabric/layout.py from its class:
domain knowledge under memory/domains/<role>/, everything learned about
the project under <working copy>/.agent-fabric/memory/<role>/ (the
project's own repository; fabric-coordinator's to write), multi-owner
slices under the matching shared/. The generated INDEX.md for each
(project, role) lists all of it with paths relative to the working copy
(fabric-side slices through ../agent-fabric/), plus the role's authored
charter and recall from identities/roles/<role>/.

Distillers judge; this assembles. A distiller emits claims and nothing
else — no files, no frontmatter, no index — because everything mechanical
belongs here where it is deterministic: same claims in, byte-identical
tree out. That property is what makes a drain reviewable as a content
diff rather than a diff of formatting noise.

What it does:

  * Places each claim in its class/topic slice, splitting a slice when it
    outgrows its token budget so no single file can quietly become
    enormous.
  * Writes provenance frontmatter: which observations a slice came from,
    and which clone and host produced them, so a claim stays auditable
    after the observation store has been archived and emptied.
  * Regenerates every role INDEX.md from slice frontmatter. The index is
    the only thing a session reads before deciding to load a slice, so it
    is generated rather than maintained — a hand-written index drifts.
  * Routes a claim owned by two or more roles to `.roles/shared/`, so
    knowledge two roles need lives once instead of in two copies that
    will disagree later.
  * Merges the citation graph into each role's crossref.json.
  * Runs the hygiene checks that must never reach a commit.

Merge mode is the default: existing slices are read, and a claim whose
`merge_target` names an existing section updates it instead of appending
beside it. Regenerating from scratch would discard accumulated curation,
so it is never done implicitly.
<<< help
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import hashlib
import re
import sys
from collections import defaultdict
from typing import Any

_spec = importlib.util.spec_from_file_location(
    "fabric_layout", os.path.join(os.path.dirname(os.path.realpath(__file__)), "layout.py"))
layout = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(layout)

TIER1 = {"charter", "workflow", "index"}
DEFAULT_SLICE_BUDGET_TOKENS = 1800
CHARS_PER_TOKEN = 4  # rough, and only used to decide when to split a slice

CLASS_FILES = {
    "domain": "domain",
    "solution": "solution",
    "intersection": "intersection",
    "rationale": "rationale",
    "workflow": "workflow",
    "threads": "threads",
}

# Hygiene: the generic patterns live in layout.load_hygiene_patterns; a
# project's own (deployment names, sibling projects — that project's to
# keep) come from its working copy's .agent-fabric/hygiene.json, loaded
# once the project is known (main()).
BANNED_PATTERNS: list = []

# Italian function words that would not appear in ordinary English prose.
ITALIAN_MARKERS = re.compile(
    r"(?<![a-z])(perch[eé]|per[oò]|quindi|anche|questo|questa|quello|quella|"
    r"dovrebbe|bisogna|abbiamo|siamo|sono|essere|fare|molto|senza|dopo|prima di|"
    r"nella|nelle|negli|dello|della|delle|degli)(?![a-z])",
    re.I,
)


_SCRATCHPAD = re.compile(r"(?:^|/)scratchpad/")
_SESSION_TEMP = re.compile(r"^/?tmp/")


def normalize_artifact(kind: str, value: str) -> str:
    """Rewrite a `files` reference into one that still resolves later.

    The crossref index earns its keep by outliving the observation
    buffer: ADRs, PRs, commits and migrations resolve against git and
    GitHub, so an entry stays answerable long after the session that
    recorded it is gone. A path into a session's scratchpad resolves
    against nothing. It names a directory that belongs to ONE session
    on ONE machine — `/tmp/claude-1000/<clone>/<session-uuid>/...` —
    and is already dead by the time anyone reads the index, while
    still looking like a file someone could open.

    Such references are collapsed to a `scratch:` pseudo-path. That
    keeps the provenance fact worth keeping (this knowledge came from
    a throwaway probe, not from tracked code, so there is no source to
    go read) while dropping the session identity that made it a lie.
    Non-`files` kinds pass through untouched.

    TWO THINGS THIS DELIBERATELY DOES NOT DO, each found by review:

    A `scratchpad/` segment is ephemeral only UNDER a session-temp
    root. `docs/scratchpad/decision.md` is a tracked file someone can
    open, and rewriting it to `scratch:decision.md` would delete a
    valid repository path from the citation graph — the opposite of
    what this exists for. The temp root is checked FIRST, and a path
    that is not under one is returned untouched whatever it is named.

    And two dead paths that share a basename are not the same
    artifact. `/tmp/run-a/probe.cs` and `/tmp/run-b/probe.cs` both
    reduced to `scratch:probe.cs`, so the assembler merged their
    observation and slice lists into one node and conflated unrelated
    provenance. A short digest of the ORIGINAL path distinguishes them
    and stays stable across drains — without reintroducing the session
    identity, which is the thing being dropped.
    """
    if kind != "files":
        return value
    if not _SESSION_TEMP.match(value):
        # Tracked, whatever it is called. A `scratchpad/` segment under
        # the repo is a real directory with real files in it.
        return value
    match = _SCRATCHPAD.search(value)
    tail = value[match.end():] if match else value.rsplit("/", 1)[-1]
    # Distinguishes same-named artifacts; says nothing about where they
    # were, which is the point.
    digest = hashlib.sha256(value.encode("utf-8")).hexdigest()[:8]
    return f"scratch:{tail}#{digest}"


def slugify(value: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", (value or "").lower()).strip("-")
    return slug or "general"


# A YAML scalar that LOOKS like a number, bool or null is read back as one.
# Content hashes are hex, so roughly one in every few thousand is all digits
# plus an `e` — `23258632804400e6` parses as 2.3e+19 and the hash is gone.
# That is not hypothetical: it reached a committed slice and the lint caught
# it as "derived_from/0 is not of type 'string'".
YAML_AMBIGUOUS = re.compile(
    r"""(?xi)
    ^(?:
        [-+]?(?:\d[\d_]*)                      # int
      | [-+]?(?:\d[\d_]*)?\.\d*(?:[eE][-+]?\d+)?   # float, .5, 1.5e3
      | [-+]?(?:\d[\d_]*)(?:[eE][-+]?\d+)      # 1e6, and hex hashes shaped like it
      | 0[bo][0-7_01]+ | 0x[0-9a-f_]+           # other integer bases
      | [-+]?\.(?:inf|nan)
      | true|false|yes|no|on|off|y|n
      | null|~
    )$"""
)


def yaml_scalar(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    text = str(value)
    if (
        re.search(r"[:#\-\[\]{}&*!|>'\"%@`]", text)
        or re.search(r"[\n\r\t]", text)
        or text.strip() != text
        or text == ""
        or YAML_AMBIGUOUS.match(text)
    ):
        return json.dumps(text, ensure_ascii=False)
    return text


# An origin record says who produced the evidence and where. New records
# name the AGENT (the Linux login) with host, project and working copy;
# records written by the old clone-bound system name a `clone_id` and are
# preserved verbatim as historical provenance. Rendered in this key order.
ORIGIN_KEYS = ("agent", "clone_id", "host", "project", "working_copy")


def origin_of_row(row: dict[str, Any]) -> dict[str, str]:
    """The origin record for one observation row."""
    if row.get("agent") or "clone_id" not in row:
        origin = {"agent": row.get("agent") or "unresolved", "host": row.get("host") or "unknown"}
        for key in ("project", "working_copy"):
            if row.get(key):
                origin[key] = str(row[key])
        return origin
    return {"clone_id": row.get("clone_id") or "unresolved", "host": row.get("host") or "unknown"}


def origin_key(origin: dict[str, Any]) -> tuple:
    return tuple(sorted((k, str(v)) for k, v in origin.items() if v is not None))


def render_origin(item: dict[str, Any]) -> list[str]:
    lines: list[str] = []
    for key in ORIGIN_KEYS:
        if item.get(key) is None:
            continue
        prefix = "  - " if not lines else "    "
        lines.append(f"{prefix}{key}: {yaml_scalar(str(item[key]))}")
    return lines


def render_frontmatter(meta: dict[str, Any]) -> str:
    lines = ["---"]
    for key in ("role", "class", "description", "tier", "knowledge_scope",
                "shared_with", "token_budget", "corpus", "distilled_at",
                "collisions", "origin", "derived_from"):
        if key not in meta:
            continue
        value = meta[key]
        if isinstance(value, list):
            if not value:
                continue
            if key == "origin":
                lines.append(f"{key}:")
                for item in value:
                    lines.extend(render_origin(item))
            else:
                lines.append(f"{key}:")
                for item in value:
                    lines.append(f"  - {yaml_scalar(item)}")
        else:
            lines.append(f"{key}: {yaml_scalar(value)}")
    lines.append("---")
    return "\n".join(lines)


def hygiene_check(text: str, where: str) -> list[str]:
    problems = []
    for pattern, label in BANNED_PATTERNS:
        hit = pattern.search(text)
        if hit:
            problems.append(f"{where}: {label} -- {hit.group(0)!r}")
    italian = ITALIAN_MARKERS.findall(text)
    if len(set(w.lower() for w in italian)) >= 3:
        problems.append(f"{where}: reads as non-English (markers: {sorted(set(italian))[:5]})")
    return problems


def scan_collisions(dirs: list[str]) -> list[str]:
    """Report title collisions still recorded in the committed corpus.

    Read from the `collisions` frontmatter the assembler writes, not from the
    shape of the headings: an authored document may legitimately contain "X"
    and "X (2)", and so may a claim whose real title ends that way. Reading a
    recorded fact keeps the warning alive across drains that admit nothing —
    the file states it — without inventing one where nothing collided.
    """
    found: list[str] = []
    for base in dirs:
        for dirpath, _dirnames, filenames in os.walk(base):
            for name in sorted(filenames):
                if not name.endswith(".md"):
                    continue
                path = os.path.join(dirpath, name)
                meta, _sections = read_existing_slice(path)
                for title in meta.get("collisions", []) or []:
                    found.append(
                        f"{layout.root_rel(path)}: {title!r} appears twice "
                        "— set merge_target to resolve"
                    )
    return sorted(found)


def decode_scalar(text: str) -> str:
    """Undo what `yaml_scalar` did.

    A value with punctuation is written JSON-quoted, so reading it back by
    stripping the outer quotes leaves the escapes behind. For a field that is
    unioned across drains — collisions — that means the same title returns
    slightly more escaped every cycle and accumulates a fresh entry each time,
    without bound.
    """
    text = text.strip()
    if text.startswith('"'):
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            return text.strip('"')
    return text


def read_existing_slice(path: str) -> tuple[dict[str, Any], dict[str, str]]:
    """Return (frontmatter, {heading: section-text}) for a slice already on disk.

    Merge mode needs the previous drain's claims back in hand: a drain writes
    only what it admitted this cycle, so rendering that alone would silently
    delete everything earlier cycles had learned.
    """
    if not os.path.exists(path):
        return {}, {}
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    meta: dict[str, Any] = {}
    match = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    body = text
    if match:
        body = text[match.end():]
        current = None
        for line in match.group(1).split("\n"):
            stripped = line.strip()
            if line.startswith("  - ") and current:
                item = line[4:].strip()
                # `origin` is a list of small mappings (agent or clone_id,
                # host, project, working_copy). Keeping it is what makes a
                # carried claim still say who produced it and where — the
                # audit trail has to survive the drain that inherits the
                # section, not just the one that wrote it.
                if current == "origin" and ":" in item:
                    k, _, v = item.partition(":")
                    meta.setdefault("origin", []).append({k.strip(): decode_scalar(v)})
                else:
                    meta.setdefault(current, []).append(decode_scalar(item))
            elif current == "origin" and line.startswith("    ") and ":" in stripped and meta.get("origin"):
                k, _, v = stripped.partition(":")
                meta["origin"][-1][k.strip()] = decode_scalar(v)
            elif ":" in line and not line.startswith(" "):
                key, _, value = line.partition(":")
                current = key.strip()
                value = value.strip()
                meta[current] = [] if value == "" else decode_scalar(value)
    sections: dict[str, str] = {}
    for part in re.split(r"^## ", body, flags=re.M)[1:]:
        heading, _, rest = part.partition("\n")
        sections[heading.strip()] = rest.strip()
    return meta, sections


def claim_block(claim: dict[str, Any]) -> str:
    title = claim.get("title") or claim["topic"].replace("-", " ").capitalize()
    body = claim["body"].strip()
    cites = claim.get("citations") or {}
    flat = [c for values in cites.values() for c in values]
    tail = ""
    if flat:
        tail = "\n\n*References: " + ", ".join(sorted(set(flat))) + "*"
    scope = ""
    if claim.get("knowledge_scope") == "domain-only":
        scope = "\n\n> Learned outside this system; it describes the field, not our implementation.\n"
    return f"## {title}\n{scope}\n{body}{tail}\n"


def main() -> int:
    ap = argparse.ArgumentParser(description="Assemble knowledge slices from claims.")
    ap.add_argument("--claims", required=True, help="directory of <role>.json claim files")
    ap.add_argument("--drain", required=True, help="harvest output directory")
    ap.add_argument("--project", required=True,
                    help="logical project id the project-scoped classes are filed under")
    ap.add_argument("--fabric", default=None,
                    help="agent-fabric root (default: this checkout, or $AGENT_FABRIC_ROOT)")
    ap.add_argument("--working-copy", default=None,
                    help="the project's checkout; its .agent-fabric/memory/ receives the "
                         "project-scoped classes (default: the agent's binding, or this checkout "
                         "for agent-fabric itself)")
    ap.add_argument("--stamp", required=True, help="distillation date (YYYY-MM-DD)")
    ap.add_argument("--budget", type=int, default=DEFAULT_SLICE_BUDGET_TOKENS)
    args = ap.parse_args()
    if args.fabric:
        layout.FABRIC_ROOT = os.path.abspath(args.fabric)
    project = args.project
    if args.working_copy:
        layout.set_working_copy(project, args.working_copy)
    try:
        layout.project_memory_root(project)
    except LookupError as exc:
        sys.exit(f"assemble: {exc}")
    BANNED_PATTERNS[:] = layout.load_hygiene_patterns([project])

    def base_for(role: str, klass: str) -> str:
        """The directory a slice of `klass` for `role` lives in."""
        return layout.class_home(klass, role, project)

    with open(os.path.join(args.drain, "references.json"), encoding="utf-8") as fh:
        references = json.load(fh)
    origins: dict[str, dict[str, str]] = {}
    obs_path = os.path.join(args.drain, "observations.final.jsonl")
    if not os.path.exists(obs_path):
        obs_path = os.path.join(args.drain, "observations.jsonl")
    with open(obs_path, encoding="utf-8") as fh:
        for line in fh:
            if line.strip():
                row = json.loads(line)
                origins[row["content_hash"]] = origin_of_row(row)

    claim_files = sorted(
        f for f in os.listdir(args.claims) if f.endswith(".json") and not f.startswith(".")
    )
    all_claims: dict[str, list[dict[str, Any]]] = {}
    telemetry: dict[str, Any] = {}
    scope_violations: list[str] = []
    for name in claim_files:
        with open(os.path.join(args.claims, name), encoding="utf-8") as fh:
            payload = json.load(fh)
        role = payload["role"]
        all_claims[role] = payload.get("claims", [])
        telemetry[role] = payload.get("telemetry", {})

        # DOMAIN-ONLY EVIDENCE MAY SUPPORT ONLY A DOMAIN CLAIM.
        #
        # Evidence carried over from a sibling project is transferable
        # knowledge about a FIELD, not a statement about this repository.
        # Filed as `solution` it becomes an as-of-dated claim about what this
        # system implements; as `workflow` or `rationale` it becomes a claim
        # about how this team works. Both are false in the same way, and the
        # in-body disclaimer the assembler adds is prose a reader may skim,
        # not a boundary.
        #
        # Checked here in code, not left to the schema alone: this is the
        # only consumer of a claims file, and lint's fallback validator
        # cannot evaluate a conditional when jsonschema is absent.
        for claim in all_claims[role]:
            if (claim.get("knowledge_scope") == "domain-only"
                    and claim.get("class") != "domain"):
                scope_violations.append(
                    f"{name}: {claim.get('title') or claim.get('topic')!r} is "
                    f"domain-only evidence filed as {claim.get('class')!r} — "
                    "sibling-project evidence may support only a domain claim"
                )

    # Refuse BEFORE writing anything. A scope violation is an input defect,
    # so assembling and reporting afterwards would leave a tree that has to
    # be reverted rather than simply re-run.
    if scope_violations:
        print("CLAIM SCOPE VIOLATIONS:", file=sys.stderr)
        for problem in scope_violations:
            print(f"  {problem}", file=sys.stderr)
        return 1

    # A claim owned by several roles lives once, in shared/, and every owner's
    # index points at it. Copies would drift.
    shared: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    per_role: dict[str, dict[tuple[str, str], list[dict[str, Any]]]] = defaultdict(
        lambda: defaultdict(list)
    )
    shared_owners: dict[tuple[str, str], set[str]] = defaultdict(set)

    # A claim whose body fails the hygiene check (RUBRIC.md: deployment
    # specifics, secrets, session-local detail) is REJECTED here, before any
    # bucket, and named in the report. Writing it and warning afterwards put
    # the text in the tree first and asked for a fix second — and lint then
    # failed the drain's branch on exactly that text. The author fixes the
    # memory; the corpus never receives the claim.
    rejected_hygiene: list[str] = []
    for role, claims in list(all_claims.items()):
        kept = []
        for claim in claims:
            issues = hygiene_check(claim.get("body") or "", f"{role}/{claim['class']}:{claim['topic']}")
            if issues:
                rejected_hygiene.extend(issues)
                telemetry.setdefault(role, {}).setdefault("rejected_hygiene", 0)
                telemetry[role]["rejected_hygiene"] += 1
            else:
                kept.append(claim)
        all_claims[role] = kept

    for role, claims in all_claims.items():
        for claim in claims:
            key = (claim["class"], claim["topic"])
            owners = set(claim.get("shared_with") or [])
            owners.discard(role)
            if owners:
                owners.add(role)
                shared[key].append(claim)
                shared_owners[key] |= owners
            else:
                per_role[role][key].append(claim)

    problems: list[str] = []
    oversized: list[str] = []
    migrated: list[str] = []

    def crossref_slice_ids(role: str) -> set[str]:
        """Every `class:topic` id the role's committed crossref names."""
        path = os.path.join(layout.project_dir(project, role), "crossref.json")
        try:
            doc = json.load(open(path, encoding="utf-8"))
        except (OSError, ValueError):
            return set()
        ids: set[str] = set()
        for kinds in (doc.get("index") or {}).values():
            for entry in (kinds or {}).values():
                ids.update(x for x in (entry.get("slices") or []) if isinstance(x, str))
        return ids
    collisions: list[str] = []
    written: list[str] = []
    index_entries: dict[str, list[dict[str, str]]] = defaultdict(list)

    DESCRIPTION_MAX = 240  # identities/schemas/role-template.schema.json
    clipped_descriptions: list[str] = []

    def clip_description(description: str, where: str) -> str:
        """The description is the retrieval cue an index shows; the schema
        caps it. A cue that runs on is clipped at a word boundary and the
        clip reported, rather than failing the whole drain on lint."""
        if len(description) <= DESCRIPTION_MAX:
            return description
        cut = description[: DESCRIPTION_MAX - 1].rsplit(" ", 1)[0].rstrip(" ,;:—-")
        clipped_descriptions.append(f"{where}: description clipped from {len(description)} to {len(cut) + 1} characters")
        return cut + "…"

    def write_slice(
        directory: str, filename: str, role: str, klass: str, claims: list[dict[str, Any]],
        description: str, shared_with: list[str] | None = None,
    ) -> None:
        os.makedirs(directory, exist_ok=True)
        description = clip_description(description, os.path.join(directory, filename))
        evidence = sorted({h for c in claims for h in c.get("evidence", [])})
        origin_set = {
            origin_key(origins.get(h) or {"agent": "unresolved", "host": "unknown"})
            for h in evidence
        }
        scope = "domain-only" if all(
            c.get("knowledge_scope") == "domain-only" for c in claims
        ) else "full"
        meta = {
            "role": role,
            "class": klass,
            "description": description,
            "tier": 1 if klass in TIER1 else 2,
            "knowledge_scope": scope,
            "distilled_at": args.stamp,
            "origin": [dict(k) for k in sorted(origin_set)],
            "derived_from": evidence,
        }
        if shared_with:
            meta["shared_with"] = sorted(shared_with)
        path = os.path.join(directory, filename)

        # MERGE MODE. A drain renders only what it admitted this cycle, so
        # writing that alone would delete everything earlier cycles learned.
        # Sections already on disk are carried forward; a claim naming an
        # existing heading in `merge_target` replaces that section (the rubric
        # prefers strengthening a claim over adding beside it); anything else
        # is appended. Provenance unions, so a merged claim keeps the evidence
        # both drains found for it.
        previous_meta, previous_sections = read_existing_slice(path)
        collided: list[str] = []
        resolved: list[str] = []
        blocks: dict[str, str] = dict(previous_sections)
        order: list[str] = list(previous_sections)
        for claim in claims:
            heading = (claim.get("title")
                       or claim["topic"].replace("-", " ").capitalize()).strip()
            target = (claim.get("merge_target") or "").strip()
            authorised = bool(target and target in blocks)
            if authorised:
                # Replacement is opt-in, and this is the opt-in.
                heading = target
                # CONSOLIDATION RETIRES THE SUFFIXED SIBLINGS.
                #
                # A collision leaves "X" and "X (2)" side by side and
                # records "X" so the drain report can ask for a
                # merge_target. Naming it rewrote "X" alone: "X (2)"
                # stayed in the body forever and the recorded collision
                # was unioned forward on every later drain, so the
                # remedy the report prescribes could never clear the
                # report. Only an explicit merge_target reaches here, so
                # retiring the siblings is the author's instruction
                # rather than an inference.
                sibling = 2
                while f"{target} ({sibling})" in blocks:
                    stale = f"{target} ({sibling})"
                    del blocks[stale]
                    if stale in order:
                        order.remove(stale)
                    sibling += 1
                resolved.append(target)
            base_heading = heading
            rendered = claim_block(claim).split("\n", 1)[1].strip()
            if not authorised and heading in blocks and blocks[heading] != rendered:
                # A heading that already holds DIFFERENT text is a second
                # claim, not this one again. Overwriting on a bare title match
                # made replacement implicit and silent — a drain deleting a
                # finding nobody asked it to touch. Keep both and report it.
                # (Identical text is simply the same claim re-rendered, which
                # must stay a no-op or re-assembly would duplicate everything.)
                suffix = 2
                while f"{heading} ({suffix})" in blocks and blocks[f"{heading} ({suffix})"] != rendered:
                    suffix += 1
                collided.append(base_heading)
                heading = f"{heading} ({suffix})"
            if heading not in blocks:
                order.append(heading)
            blocks[heading] = rendered

        # SCOPE UNIONS WITH WHAT IS CARRIED, and `full` wins.
        #
        # `scope` above is computed from THIS drain's claims alone, because
        # the file on disk had not been read yet. A cycle contributing only
        # domain-only claims to a slice that already holds a full-scope
        # section therefore relabelled the whole file `domain-only` while
        # the system-specific text was still sitting in it — defeating the
        # cross-project boundary the field exists to draw.
        #
        # Erring toward `full` is the safe direction: it over-restricts what
        # may cross a project boundary, where the opposite leaks.
        if previous_sections and previous_meta.get("knowledge_scope") == "full":
            meta["knowledge_scope"] = "full"

        carried = [h for h in previous_meta.get("derived_from", []) or []
                   if isinstance(h, str)]
        meta["derived_from"] = sorted(set(evidence) | set(carried))
        # Origins must union with the carried evidence they belong to,
        # otherwise a preserved hash lists no clone or host and the trail it
        # exists to provide is broken exactly when the store has been cleared.
        prior_origin = {
            origin_key(o) for o in previous_meta.get("origin", []) or [] if isinstance(o, dict)
        }
        meta["origin"] = [dict(k) for k in sorted(origin_set | prior_origin)]
        # An unresolved collision is recorded in the slice that has it, so the
        # warning is a fact the file states rather than a shape inferred from
        # its headings — an authored document may legitimately carry "X" and
        # "X (2)" without anything having collided.
        carried_collisions = [c for c in previous_meta.get("collisions", []) or []
                              if isinstance(c, str)]
        # A resolved title stops being reported. Without this the record
        # was write-only: unioned forward every drain, with no path that
        # ever removed one, so `title_collisions` in the drain report
        # named pairs that no longer existed.
        outstanding = (set(collided) | set(carried_collisions)) - set(resolved)
        if outstanding:
            meta["collisions"] = sorted(outstanding)

        body = "\n\n".join(f"## {h}\n\n{blocks[h]}" for h in order) + "\n"
        text = render_frontmatter(meta) + "\n\n" + body
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text.rstrip() + "\n")
        written.append(path)
        problems.extend(hygiene_check(body, layout.root_rel(path)))

    def carried_chars(*candidates: str) -> int:
        """How much text merge mode will carry into the FIRST part.

        Sized from whichever candidate path actually exists: the layout of a
        slice depends on whether it ever split, so the same topic can live at
        `<class>.md` or `<class>/<topic>.md` and only the tree knows which.
        """
        for path in candidates:
            _meta, sections = read_existing_slice(path)
            if sections:
                return sum(len(h) + len(t) + 8 for h, t in sections.items())
        return 0

    def split_by_budget(
        claims: list[dict[str, Any]], carried: int = 0
    ) -> list[list[dict[str, Any]]]:
        """Keep a slice inside its budget; a file nobody can afford to read is
        the same as a file nobody reads.

        `carried` is what merge mode will re-emit from the file on disk.
        Sizing this drain's claims ALONE is what let a slice grow without
        bound: each cycle split its own contribution correctly, then
        write_slice added every earlier section back underneath, so the file
        crept past the budget across drains while no single run looked wrong
        — until the mandatory lint budget check failed on a tree nobody had
        touched.
        """
        limit = args.budget * CHARS_PER_TOKEN
        groups: list[list[dict[str, Any]]] = []
        current: list[dict[str, Any]] = []
        size = carried
        for claim in claims:
            claim_size = len(claim["body"]) + len(claim.get("title") or "") + 40
            # `carried` counts toward the first group, so a file already at
            # its limit pushes the next claim into a new part instead of
            # overflowing — which is why an EMPTY first group is a legitimate
            # outcome here, meaning "part one is full of carried text".
            if size + claim_size > limit and (current or carried):
                groups.append(current)
                current, size = [], 0
            current.append(claim)
            size += claim_size
        if current or not groups:
            groups.append(current)
        return groups

    def described(path: str, fallback: str) -> str:
        with open(path, encoding="utf-8") as fh:
            head = fh.read(2000)
        match = re.search(r"^description:\s*(.+)$", head, re.M)
        description = match.group(1).strip() if match else fallback
        if description.startswith('"'):
            try:
                description = json.loads(description)
            except json.JSONDecodeError:
                description = description.strip('"')
        return description

    # Shared slices first, so role indexes can point at them. A shared slice
    # lives with its class: field knowledge under memory/shared/, project
    # knowledge under the project's shared/.
    shared_index: dict[str, list[dict[str, str]]] = defaultdict(list)
    for (klass, topic), claims in sorted(shared.items()):
        owners = sorted(shared_owners[(klass, topic)])
        shared_dir = layout.shared_home(klass, project)
        prior = carried_chars(os.path.join(shared_dir, f"{klass}-{topic}.md"))
        for part, group in enumerate(split_by_budget(claims, prior), start=1):
            suffix = "" if part == 1 else f"-{part}"
            filename = f"{klass}-{topic}{suffix}.md"
            description = clip_description(
                (group[0].get("title") if group else None)
                or f"{topic.replace('-', ' ')} ({klass})",
                os.path.join(shared_dir, filename))
            write_slice(shared_dir, filename, "shared", klass, group, description, owners)
            for owner in owners:
                shared_index[owner].append(
                    {"path": layout.link_rel(os.path.join(shared_dir, filename), project),
                     "description": description, "class": klass}
                )

    # Every role that owns anything gets a project directory and an index —
    # including one whose claims all live in shared slices, which would
    # otherwise end up with knowledge and no way to find it.
    owning_roles = sorted(set(per_role) | set(shared_index) | set(all_claims))
    for role in owning_roles:
        buckets = per_role.get(role, {})
        proj_dir = layout.project_dir(project, role)
        os.makedirs(proj_dir, exist_ok=True)
        by_class: dict[str, list[tuple[str, list[dict[str, Any]]]]] = defaultdict(list)
        for (klass, topic), claims in sorted(buckets.items()):
            by_class[klass].append((topic, claims))

        for klass, topics in sorted(by_class.items()):
            base = base_for(role, klass)
            # The layout is a property of the TREE, not of this drain. Deciding
            # it from `len(topics)` means a class that already has a `<class>/`
            # directory gains a flat `<class>.md` the moment a later drain
            # touches exactly one topic in it — and the activator takes the
            # directory branch and skips the flat file, so a tier-1 workflow
            # slice written that way is never loaded at activation. That is the
            # defect 08dd4164 fixed in code and this reintroduced through
            # content: two roles shipped workflow.md files no session would read.
            already_split = os.path.isdir(os.path.join(base, CLASS_FILES[klass]))
            multi = already_split or len(topics) > 1
            # SWITCHING TO THE DIRECTORY SHAPE MOVES THE FLAT FILE IN. The
            # activator loads only the directory once it exists, so a flat
            # `<class>.md` left beside `<class>/` is unreachable knowledge,
            # and its size was being counted as carried text for whatever
            # topic came first — which produced an empty "part one" with no
            # provenance. The flat file may hold several topics' sections
            # (the crossref says which), so it is not split: it moves whole,
            # named for the one topic when there is one, else as the carried
            # file of its class, and its description keeps it findable.
            flat = os.path.join(base, f"{CLASS_FILES[klass]}.md")
            if multi and os.path.exists(flat):
                prior_topics = sorted({sid.split(":", 1)[1] for sid in crossref_slice_ids(role)
                                       if sid.startswith(f"{klass}:")})
                if len(prior_topics) == 1:
                    name = f"{prior_topics[0]}.md"
                else:
                    stamp = (read_existing_slice(flat)[0].get("distilled_at") or "earlier")
                    name = f"{CLASS_FILES[klass]}-carried-{stamp}.md"
                os.makedirs(os.path.join(base, CLASS_FILES[klass]), exist_ok=True)
                os.replace(flat, os.path.join(base, CLASS_FILES[klass], name))
                migrated.append(f"{role}/{klass}: {CLASS_FILES[klass]}.md -> {CLASS_FILES[klass]}/{name}")
            for topic, claims in topics:
                # Both candidate layouts, because only the tree knows whether
                # this topic has split before.
                prior = carried_chars(
                    os.path.join(base, f"{CLASS_FILES[klass]}.md"),
                    os.path.join(base, CLASS_FILES[klass], f"{topic}.md"),
                )
                groups = split_by_budget(claims, prior)
                # An empty group means "part one is full of carried text":
                # legitimate when the file on disk exists, a phantom header
                # otherwise. A claim larger than the budget cannot be split
                # (claims are atomic); it is written whole and REPORTED, so
                # the author splits the memory — lint says the same thing.
                limit = args.budget * CHARS_PER_TOKEN
                for claim in claims:
                    if len(claim["body"]) > limit:
                        oversized.append(f"{role}/{klass}:{topic}: one claim is ~{len(claim['body']) // CHARS_PER_TOKEN} tokens, "
                                         f"over the {args.budget} budget; split the memory it came from")
                for part, group in enumerate(groups, start=1):
                    suffix = "" if part == 1 else f"-{part}"
                    if not group:
                        exists = (os.path.exists(os.path.join(base, CLASS_FILES[klass], f"{topic}{suffix}.md"))
                                  or os.path.exists(os.path.join(base, f"{CLASS_FILES[klass]}.md")))
                        if not exists:
                            continue
                    if multi or len(groups) > 1:
                        directory = os.path.join(base, CLASS_FILES[klass])
                        filename = f"{topic}{suffix}.md"
                    else:
                        directory = base
                        filename = f"{CLASS_FILES[klass]}.md"
                    description = clip_description(
                        (group[0].get("title") if group else None)
                        or f"{topic.replace('-', ' ')} ({klass})",
                        os.path.join(directory, filename))
                    write_slice(directory, filename, role, klass, group, description)
                    index_entries[role].append(
                        {"path": layout.link_rel(os.path.join(directory, filename), project),
                         "description": description, "class": klass}
                    )

        for entry in shared_index.get(role, []):
            index_entries[role].append(
                {"path": entry["path"], "description": entry["description"] + " (shared)",
                 "class": entry["class"]}
            )

        # Authored files (charter, recall) are not distilled from claims, but
        # they are part of the role and the index must account for them — an
        # index that lists only what this tool wrote would read as complete
        # while omitting the first thing a session should open.
        for filename, klass in (("charter.md", "charter"), ("recall.md", "recall")):
            path = os.path.join(layout.role_dir(role), filename)
            if not os.path.exists(path):
                continue
            index_entries[role].append(
                {"path": layout.link_rel(path, project), "description": described(path, filename),
                 "class": klass}
            )

        # Every slice ON DISK, not merely the ones this run wrote. Merge mode
        # rewrites only the slices a claim touched, so from cycle two onward a
        # role's untouched slices would vanish from its own index — and the
        # index is the ONLY thing a session reads before deciding what to load,
        # so losing an entry silently retires the knowledge behind it. On the
        # first drain every slice was written and this could not be seen; the
        # second drain dropped 101 entries across ten roles.
        listed = {e["path"] for e in index_entries[role]}
        for klass, subdir in CLASS_FILES.items():
            base = base_for(role, klass)
            candidates = (
                sorted(os.path.join(base, subdir, n)
                       for n in os.listdir(os.path.join(base, subdir)) if n.endswith(".md"))
                if os.path.isdir(os.path.join(base, subdir)) else []
            ) + ([os.path.join(base, f"{subdir}.md")]
                 if os.path.exists(os.path.join(base, f"{subdir}.md")) else [])
            for path in candidates:
                rel = layout.link_rel(path, project)
                if rel in listed:
                    continue
                index_entries[role].append(
                    {"path": rel, "description": described(path, rel), "class": klass}
                )
                listed.add(rel)

        # crossref: artifact -> where it was learned and where it landed,
        # keyed by a reference that still RESOLVES later (see
        # normalize_artifact).
        crossref: dict[str, dict[str, dict[str, list[str]]]] = defaultdict(
            lambda: defaultdict(lambda: {"observations": [], "slices": []})
        )
        # SHARED CLAIMS COUNT AS THIS ROLE'S, and they are not in `buckets`.
        #
        # A claim owned by two or more roles is routed out of `per_role` and
        # into `shared` so it is stored once. The graph iterated `buckets`
        # alone, so every observation, ADR, PR and migration edge behind
        # shared knowledge was missing from BOTH owners' crossref.json — the
        # INDEX pointed at the shared slice correctly, which is exactly what
        # made the omission invisible: only a citation-graph query could see
        # it, and it silently under-reported.
        graph_sources: list[tuple[str, str, list[dict[str, Any]]]] = [
            (klass, f"{klass}:{topic}", claims)
            for (klass, topic), claims in sorted(buckets.items())
        ]
        graph_sources += [
            (klass, f"shared:{klass}:{topic}", claims)
            for (klass, topic), claims in sorted(shared.items())
            if role in shared_owners[(klass, topic)]
        ]

        for _klass, slice_name, claims in graph_sources:
            for claim in claims:
                for h in claim.get("evidence", []):
                    for kind, values in (references.get(h) or {}).items():
                        for value in values:
                            node = crossref[kind][normalize_artifact(kind, value)]
                            if h not in node["observations"]:
                                node["observations"].append(h)
                            if slice_name not in node["slices"]:
                                node["slices"].append(slice_name)
        # Carried sections keep their citation edges. Rebuilding the graph from
        # this drain alone would drop every ADR, PR and migration edge belonging
        # to knowledge that is still sitting in the role base.
        crossref_path_existing = os.path.join(proj_dir, "crossref.json")
        if os.path.exists(crossref_path_existing):
            with open(crossref_path_existing, encoding="utf-8") as fh:
                old = json.load(fh).get("index", {})
            for kind, values in old.items():
                for value, node in values.items():
                    # Normalized on the way IN as well, so a run also
                    # repairs legacy keys already sitting in the file.
                    target = crossref[kind][normalize_artifact(kind, value)]
                    for h in node.get("observations", []):
                        if h not in target["observations"]:
                            target["observations"].append(h)
                    for sl in node.get("slices", []):
                        if sl not in target["slices"]:
                            target["slices"].append(sl)

        crossref_doc = {
            "role": role,
            "generated_at": args.stamp,
            "index": {
                kind: {
                    value: {
                        "observations": sorted(node["observations"]),
                        "slices": sorted(node["slices"]),
                    }
                    for value, node in sorted(values.items())
                }
                for kind, values in sorted(crossref.items())
            },
        }
        with open(os.path.join(proj_dir, "crossref.json"), "w", encoding="utf-8") as fh:
            json.dump(crossref_doc, fh, ensure_ascii=False, indent=2, sort_keys=True)
            fh.write("\n")

        # INDEX.md is generated, never hand-maintained: it is the only thing a
        # session sees before choosing what to load, so it must not drift.
        # Paths are relative to the project's working copy, because that is
        # where a session stands; the slices a role knows live in three
        # places (its identity and its domain in the fabric, this project
        # here), and the fabric ones are reached through ../agent-fabric/ so
        # a reader never reconstructs `../../..`.
        lines = [
            render_frontmatter({
                "role": role,
                "class": "index",
                "description": f"What {role} knows and where it lives.",
                "tier": 1,
                "distilled_at": args.stamp,
            }),
            "",
            f"# {role} — knowledge index",
            "",
            # The banner has to name WHICH sections load when, because two of
            # the sections below are tier 1. Saying "everything below loads on
            # demand" over a list that opens with `charter` was wrong from the
            # start and became load-bearing once `workflow` joined it: a
            # session that believes workflow is cued will not read it until
            # something has already gone wrong.
            "Tier 1 — the charter, this index, and every `workflow` slice —",
            "loads at activation. Every other section waits for a cue: open a",
            "slice when its description matches what you are working on.",
            "Paths are relative to this working copy; `../agent-fabric/` is the",
            "control plane checked out beside it.",
            "",
        ]
        by_class_index: dict[str, list[dict[str, str]]] = defaultdict(list)
        for entry in index_entries[role]:
            by_class_index[entry["class"]].append(entry)
        for klass in ("charter", "domain", "solution", "intersection", "rationale",
                      "workflow", "threads", "recall"):
            entries = by_class_index.get(klass)
            if not entries:
                continue
            lines.append(f"## {klass}")
            lines.append("")
            for entry in sorted(entries, key=lambda e: e["path"]):
                lines.append(f"- [`{entry['path']}`]({entry['path']}) — {entry['description']}")
            lines.append("")
        with open(os.path.join(proj_dir, "INDEX.md"), "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines).rstrip() + "\n")
        written.append(os.path.join(proj_dir, "INDEX.md"))

    # An unresolved collision is a property of the corpus, not of the drain
    # that happened to create it. Deriving it from the tree is what makes the
    # warning survive a drain with an empty delta for that slice — a valid and
    # expected outcome — instead of going quiet while both sections sit there.
    collisions = scan_collisions([
        os.path.join(layout.FABRIC_ROOT, "memory", "domains"),
        layout.project_memory_root(project),
        layout.shared_dir(),
    ])

    # The harvest's own provenance has to survive into the COMMITTED record,
    # because the drain directory it lives in is temporary. Two things were
    # being lost with it:
    #
    #   * the watermark. Without it the next drain cannot answer "since when",
    #     and the only anchor left is the stamp date — which has to be turned
    #     back into an epoch by hand, per store, every cycle.
    #   * the provisional-binding tally. A row whose (host, label, timestamp)
    #     resolves to no clone is reported provisional and never guessed, but
    #     nothing downstream read that number, so a drain in which EVERY row
    #     was unattributable landed looking exactly like a clean one.
    #
    # `database` is deliberately not carried: it is an absolute path into
    # somebody's home directory, and committing it would pin an environment
    # literal into a file every clone reads.
    harvest_meta: dict[str, Any] | None = None
    watermarks: dict[str, int] = {}
    harvest_report = os.path.join(args.drain, "harvest-report.json")
    if os.path.exists(harvest_report):
        with open(harvest_report, encoding="utf-8") as fh:
            hr = json.load(fh)
        counts = hr.get("counts") or {}
        harvest_meta = {
            "host": hr.get("host"),
            "since_watermark": hr.get("since_watermark"),
            "next_watermark": hr.get("next_watermark"),
            # `provisional_clone` is the key the clone-bound harvester wrote.
            "provisional_agent": counts.get("provisional_agent", counts.get("provisional_clone")),
            "in_scope": counts.get("in_scope"),
        }
        # Keyed by host: the store is per machine, so "the" watermark is a
        # per-host fact. One drain contributes one key; a future multi-store
        # cycle extends the map instead of overwriting a scalar.
        if hr.get("host") is not None and hr.get("next_watermark") is not None:
            watermarks[hr["host"]] = hr["next_watermark"]

    report = {
        "stamp": args.stamp,
        "project": project,
        "roles": owning_roles,
        "files_written": len(written),
        "shared_slices": len(shared),
        "telemetry": telemetry,
        "hygiene_problems": problems,
        "rejected_hygiene": rejected_hygiene,
        "oversized_claims": oversized,
        "clipped_descriptions": clipped_descriptions,
        "migrated": migrated,
        "title_collisions": collisions,
        "harvest": harvest_meta,
        "watermarks": watermarks,
    }
    report_path = layout.project_report_path(project)
    os.makedirs(os.path.dirname(report_path), exist_ok=True)
    with open(report_path, "w", encoding="utf-8") as fh:
        json.dump(report, fh, ensure_ascii=False, indent=2, sort_keys=True)
        fh.write("\n")

    for role in owning_roles:
        counts = telemetry.get(role, {})
        print(
            f"{role:16} claims={sum(len(v) for v in per_role.get(role, {}).values()):>3} "
            f"slices={sum(1 for p in written if f'/{role}/' in p):>3} "
            f"admitted={counts.get('admitted', '?')} rejected={counts.get('rejected', '?')}"
        )
    print(f"\n{len(written)} files, {len(shared)} shared slices")
    if rejected_hygiene:
        print("\nREJECTED (hygiene — fix the memory, the corpus did not receive it; this run exits 1):", file=sys.stderr)
        for note in rejected_hygiene:
            print(f"  {note}", file=sys.stderr)
    if oversized:
        print("\nOVER BUDGET (written whole; lint will fail until the memory is split):", file=sys.stderr)
        for note in oversized:
            print(f"  {note}", file=sys.stderr)
    if clipped_descriptions:
        print("\nDESCRIPTIONS CLIPPED to the schema limit (shorten the memory's description to choose the cue):", file=sys.stderr)
        for note in clipped_descriptions:
            print(f"  {note}", file=sys.stderr)
    if migrated:
        print("\nLAYOUT: flat class file moved into its directory:", file=sys.stderr)
        for note in migrated:
            print(f"  {note}", file=sys.stderr)
    if collisions:
        print("\nTITLE COLLISIONS (both claims kept):", file=sys.stderr)
        for note in collisions:
            print(f"  {note}", file=sys.stderr)
    # A WARNING, not a failure: an unattributable row is still knowledge, and
    # the harvest reports it provisional rather than guessing. But the tally
    # used to exist only in the transient harvest report, so a drain of a
    # clone that had never registered — every row provisional — landed
    # looking exactly like a clean one. Loud here, and never a gate: gating
    # would refuse valid knowledge for a registry gap it cannot itself fix.
    provisional = (harvest_meta or {}).get("provisional_agent") or 0
    if provisional:
        in_scope = (harvest_meta or {}).get("in_scope") or 0
        share = f" of {in_scope}" if in_scope else ""
        print(
            f"\nPROVISIONAL BINDINGS: {provisional}{share} observation(s) resolved "
            f"to no agent.\n"
            "  Their knowledge is kept; only the agent attribution is missing.\n"
            "  A row from a legacy store is attributed by (host, working-copy label,\n"
            "  time) through docs/migration/legacy-registry/agent-map.json; a label\n"
            "  absent there stays provisional rather than guessed. Add the mapping,\n"
            "  or drain through harvest_memory.py, which stamps the agent at source.",
            file=sys.stderr,
        )
    if problems:
        # Carried text can still trip hygiene (a slice written before the
        # check existed): reported the same way, and the run is not clean.
        print("\nHYGIENE PROBLEMS in carried text:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
    if problems or rejected_hygiene:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
