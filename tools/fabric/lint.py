#!/usr/bin/env python3
"""tools/roles/lint.py

>>> help
Guard the committed role base the way the contract validators guard the
wire surface.

    tools/roles/lint.py            # lints .roles/
    tools/roles/lint.py --roles PATH

The role base is written by tools and read by sessions, so the failures
worth catching are the quiet ones: an index that no longer matches the
slices beside it, a slice that grew past what a session can afford to
load, provenance that points at nothing, a binding history that cannot be
resolved, or content that should never have been committed at all.

Checks:
  schemas    every structured file validates against .roles/schema/
  frontmatter every slice carries provenance, and it parses
  index      every slice is indexed, and every index line resolves
  budgets    no slice exceeds its token budget
  shared     a shared slice really is shared (two or more owners)
  bindings   one open window per clone; closures only ever move forward
  profiles   every opus tier in model-profiles.json is review-grade, and
             every role row names a role the taxonomy knows
  hygiene    no city or country names, no external project names, no
             credentials, no non-English prose

Exit 0 clean, 1 on findings, 2 on usage error. Uses jsonschema when it is
importable and falls back to a built-in structural check otherwise, so a
clean machine can still run it.
<<< help
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import defaultdict
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

BUDGET_TOKENS = 1800
CHARS_PER_TOKEN = 4
TIER1_BUDGET_TOKENS = 3000

BANNED_PATTERNS = [
    (re.compile(r"\bSpringfield\b", re.I), "city name"),
    (re.compile(r"\bgeorgia\b", re.I), "country name"),
    (re.compile(r"(?<![a-z0-9-])dcs(?![a-z0-9-])", re.I), "external project name"),
    (re.compile(r"\bsibling-alpha\b", re.I), "external project name"),
    (re.compile(r"\bsibling-epsilon\b", re.I), "external project name"),
    (re.compile(r"\bsibling-delta\b", re.I), "external project name"),
    (re.compile(r"\bSiblingBeta\b", re.I), "external project name"),
    (re.compile(r"\bghp_[A-Za-z0-9]{10,}"), "credential"),
    (re.compile(r"\bsk-[A-Za-z0-9]{20,}"), "credential"),
]

ITALIAN_MARKERS = re.compile(
    r"(?<![a-z])(perch[eé]|per[oò]|quindi|anche|questo|questa|quello|quella|"
    r"dovrebbe|bisogna|abbiamo|siamo|essere|molto|senza|nella|nelle|negli|"
    r"dello|della|delle|degli)(?![a-z])",
    re.I,
)

FRONTMATTER_RE = re.compile(r"^---\n(.*?)\n---\n", re.S)


PAYLOAD_DIRS = frozenset({"skills", "commands"})


def hygiene_findings(where: str, text: str) -> list[str]:
    """Banned patterns and the language check — for slices AND payload.

    Payload is exempt from the slice judgements; it is never exempt from
    this. lint.py is the only CI pass over `.roles/**`, and switch.py copies
    payload verbatim into `.claude/` in every clone that adopts the role, so
    this is the only thing between a pasted credential and every one of them.
    """
    out: list[str] = []
    for pattern, label in BANNED_PATTERNS:
        hit = pattern.search(text)
        if hit:
            out.append(f"{where}: {label} -- {hit.group(0)!r}")
    italian = {w.lower() for w in ITALIAN_MARKERS.findall(text)}
    if len(italian) >= 3:
        out.append(
            f"{where}: reads as non-English ({sorted(italian)[:5]}) — translate it"
        )
    return out


def payload_shape_findings(role: str, role_path: str) -> list[str]:
    """Assert what switch.py can actually install, where it is authored.

    switch.py installs a DIRECTORY under skills/ and a .md FILE under
    commands/, and skips anything else without a word. Exempting payload
    from the slice checks would otherwise make misplaced payload invisible
    twice over: silent here, silently dropped at install time.
    """
    out: list[str] = []
    if role == "shared":
        for name in sorted(PAYLOAD_DIRS):
            if os.path.isdir(os.path.join(role_path, name)):
                out.append(
                    f"shared/{name}/: shared ships no payload — switch.py "
                    "resolves it as no role and never installs from it"
                )
        return out
    skills_dir = os.path.join(role_path, "skills")
    if os.path.isdir(skills_dir):
        for name in sorted(os.listdir(skills_dir)):
            entry = os.path.join(skills_dir, name)
            if not os.path.isdir(entry):
                out.append(
                    f"{role}/skills/{name}: not a directory — switch.py "
                    "installs only directories here, and skips the rest silently"
                )
            elif not os.path.isfile(os.path.join(entry, "SKILL.md")):
                out.append(f"{role}/skills/{name}/: no SKILL.md to be discovered by")
    commands_dir = os.path.join(role_path, "commands")
    if os.path.isdir(commands_dir):
        for name in sorted(os.listdir(commands_dir)):
            entry = os.path.join(commands_dir, name)
            if not (os.path.isfile(entry) and name.endswith(".md")):
                out.append(
                    f"{role}/commands/{name}: not a .md file — switch.py "
                    "installs only .md files here, and skips the rest silently"
                )
    return out


def parse_frontmatter(text: str) -> dict[str, Any] | None:
    """Parse the small YAML subset the assembler emits (no external dep)."""
    match = FRONTMATTER_RE.match(text)
    if not match:
        return None
    meta: dict[str, Any] = {}
    key: str | None = None
    for raw in match.group(1).split("\n"):
        if not raw.strip():
            continue
        if raw.startswith("  - ") or raw.startswith("    "):
            if key is None:
                continue
            item = raw.strip().lstrip("- ").strip()
            if ":" in item and not item.startswith('"'):
                sub, _, value = item.partition(":")
                if isinstance(meta.get(key), list) and meta[key] and isinstance(meta[key][-1], dict):
                    meta[key][-1][sub.strip()] = value.strip()
                else:
                    meta.setdefault(key, []).append({sub.strip(): value.strip()})
            else:
                try:
                    item = json.loads(item)
                except json.JSONDecodeError:
                    pass
                meta.setdefault(key, []).append(item)
            continue
        if ":" in raw:
            key, _, value = raw.partition(":")
            key = key.strip()
            value = value.strip()
            if value == "":
                meta[key] = []
            else:
                try:
                    meta[key] = json.loads(value)
                except json.JSONDecodeError:
                    # MATCH assemble.decode_scalar's fallback, which strips the
                    # outer quotes when json.loads fails. Keeping them here made
                    # the two parsers disagree about the same file: a
                    # description written with unescaped inner quotes — which
                    # yaml_scalar would never emit, so it is hand-edited or
                    # pre-dates the current assembler — came back quoted to lint
                    # and unquoted to assemble. Every length, pattern and
                    # equality judgement lint makes on that field was therefore
                    # made on a different string than the index was generated
                    # from. Found because the INDEX description check below fired
                    # on three slices that were not actually drifted.
                    meta[key] = value.strip('"') if value.startswith('"') else value
    return meta


SESSION_TEMP_REFERENCE = re.compile(r"(^|/)(tmp/claude|scratchpad/)|^/tmp/")


def check_durable_references(role: str, crossref: dict[str, Any]) -> list[str]:
    """A crossref key must still resolve after its session is gone.

    The index's whole value is outliving the observation buffer: ADRs,
    PRs, commits and migrations resolve against git and GitHub. A path
    into a session scratchpad resolves against nothing — it names a
    directory belonging to one session on one machine, dead by the
    time anyone reads it, yet still shaped like a file to open. Three
    such keys reached the repo from other sessions before this check
    existed; `assemble.normalize_artifact` now collapses them to a
    `scratch:` pseudo-path on the way in, and this catches any that
    arrive by another route (a hand edit, an older generator).

    Both `scratch:name` and `scratch:name#<digest>` are valid. The
    digest was added later, to keep two dead paths that share a basename
    from merging into one node; it hashes the ORIGINAL path, which no
    buffer still holds for the keys written before it, so those keep the
    bare form permanently. This check is about the session path being
    gone, which is true of both.
    """
    findings: list[str] = []
    for kind, values in (crossref.get("index") or {}).items():
        for value in values:
            if SESSION_TEMP_REFERENCE.search(value):
                findings.append(
                    f"{role}/crossref.json: index.{kind} key {value!r} is a "
                    "session-local temp path and will not resolve for anyone "
                    "else — use the 'scratch:' form"
                )
    return findings


def validate_json(schema: dict[str, Any], doc: Any, where: str) -> list[str]:
    try:
        import jsonschema  # type: ignore
    except ImportError:
        return _structural_check(schema, doc, where)
    validator = jsonschema.Draft202012Validator(schema)
    return [
        f"{where}: {'/'.join(str(p) for p in err.path) or '<root>'}: {err.message}"
        for err in sorted(validator.iter_errors(doc), key=lambda e: list(e.path))
    ]


def _structural_check(schema: dict[str, Any], doc: Any, where: str, path: str = "") -> list[str]:
    """Enough of JSON Schema to be useful without the dependency."""
    problems: list[str] = []
    expected = schema.get("type")
    if expected:
        kinds = {
            "object": dict, "array": list, "string": str,
            "integer": int, "number": (int, float), "boolean": bool,
        }
        types = expected if isinstance(expected, list) else [expected]
        allowed = tuple(kinds[t] for t in types if t in kinds)
        if allowed and not isinstance(doc, allowed):
            if not (doc is None and "null" in types):
                return [f"{where}{path}: expected {expected}"]
    if isinstance(doc, dict):
        for key in schema.get("required", []):
            if key not in doc:
                problems.append(f"{where}{path}: missing required '{key}'")
        props = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            pattern_props = schema.get("patternProperties", {})
            for key in doc:
                if key in props:
                    continue
                if any(re.search(p, key) for p in pattern_props):
                    continue
                problems.append(f"{where}{path}: unexpected property '{key}'")
        for key, sub in props.items():
            if key in doc:
                problems += _structural_check(sub, doc[key], where, f"{path}/{key}")
        extra = schema.get("additionalProperties")
        if isinstance(extra, dict):
            for key, value in doc.items():
                if key not in props:
                    problems += _structural_check(extra, value, where, f"{path}/{key}")
    if isinstance(doc, list):
        items = schema.get("items")
        if isinstance(items, dict):
            for i, value in enumerate(doc):
                problems += _structural_check(items, value, where, f"{path}[{i}]")
        if schema.get("uniqueItems") and len({json.dumps(v, sort_keys=True) for v in doc}) != len(doc):
            problems.append(f"{where}{path}: duplicate items")
    if "enum" in schema and doc not in schema["enum"]:
        problems.append(f"{where}{path}: {doc!r} not in {schema['enum']}")
    if "pattern" in schema and isinstance(doc, str) and not re.search(schema["pattern"], doc):
        problems.append(f"{where}{path}: {doc!r} does not match {schema['pattern']}")
    return problems


def model_profile_findings(doc: dict[str, Any], known_roles: set[str]) -> list[str]:
    """Invariants the schema cannot express for registry/model-profiles.json.

    The file is layered — defaults <- roles.<role> <- instances.<name> — and
    the launcher resolves the opus tier by merging the layers. So the check
    is on the MERGED opus of every row, not on each layer's own value: a
    role row that sets no opus inherits the default and is fine; one that
    sets a cheaper model is the defect this exists to catch, because the
    review class runs on it and a review's failure mode is a green PR that
    merges. Role rows must name roles the taxonomy knows, so a typo cannot
    create a row nobody ever resolves to.
    """
    findings: list[str] = []
    where = "model-profiles.json"
    grade = set(doc.get("review_grade", []))
    default_opus = doc.get("defaults", {}).get("tiers", {}).get("opus")
    if default_opus not in grade:
        findings.append(f"{where}: defaults.tiers.opus {default_opus!r} is not in review_grade")
    for layer in ("roles", "instances"):
        for name, row in (doc.get(layer) or {}).items():
            opus = (row.get("tiers") or {}).get("opus", default_opus)
            if opus not in grade:
                findings.append(
                    f"{where}: {layer}.{name} resolves opus to {opus!r}, which is not in "
                    "review_grade; the review class would run on it"
                )
    if known_roles:
        for name in (doc.get("roles") or {}):
            if name not in known_roles:
                findings.append(f"{where}: roles.{name} is not a role in taxonomy.json")
    return findings


def load_schema(roles_dir: str, name: str) -> dict[str, Any] | None:
    path = os.path.join(roles_dir, "schema", f"{name}.schema.json")
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def main() -> int:
    ap = argparse.ArgumentParser(description="Lint the committed role base.")
    ap.add_argument("--roles", default=".roles")
    args = ap.parse_args()
    roles_dir = args.roles
    if not os.path.isdir(roles_dir):
        print(f"lint: no role base at {roles_dir}", file=sys.stderr)
        return 2

    findings: list[str] = []

    # --- structured files -------------------------------------------------
    taxonomy_schema = load_schema(roles_dir, "taxonomy")
    taxonomy_path = os.path.join(roles_dir, "taxonomy.json")
    known_roles: set[str] = set()
    if taxonomy_schema and os.path.exists(taxonomy_path):
        with open(taxonomy_path, encoding="utf-8") as fh:
            taxonomy = json.load(fh)
        findings += validate_json(taxonomy_schema, taxonomy, "taxonomy.json")
        known_roles = {r["id"] for r in taxonomy.get("roles", [])}

    for name, filename in (("clones", "clones.jsonl"), ("bindings", "bindings.jsonl")):
        schema = load_schema(roles_dir, name)
        path = os.path.join(roles_dir, "registry", filename)
        if not (schema and os.path.exists(path)):
            continue
        with open(path, encoding="utf-8") as fh:
            for lineno, line in enumerate(fh, start=1):
                if line.strip():
                    findings += validate_json(schema, json.loads(line), f"{filename}:{lineno}")

    # --- model profiles ---------------------------------------------------
    profiles_schema = load_schema(roles_dir, "model-profiles")
    profiles_path = os.path.join(roles_dir, "registry", "model-profiles.json")
    if profiles_schema and os.path.exists(profiles_path):
        with open(profiles_path, encoding="utf-8") as fh:
            profiles = json.load(fh)
        schema_findings = validate_json(profiles_schema, profiles, "model-profiles.json")
        findings += schema_findings
        if not schema_findings:
            findings += model_profile_findings(profiles, known_roles)

    # --- binding invariants ----------------------------------------------
    bindings_path = os.path.join(roles_dir, "registry", "bindings.jsonl")
    if os.path.exists(bindings_path):
        with open(bindings_path, encoding="utf-8") as fh:
            rows = [json.loads(line) for line in fh if line.strip()]
        open_windows: dict[str, int] = defaultdict(int)
        for row in rows:
            if row.get("valid_to") in (None, ""):
                open_windows[row["clone_id"]] += 1
            elif row.get("valid_to_epoch") and row.get("valid_from_epoch"):
                if row["valid_to_epoch"] < row["valid_from_epoch"]:
                    findings.append(
                        f"bindings.jsonl: clone {row['clone_id']} has a window that closes "
                        "before it opens"
                    )
        for clone_id, count in open_windows.items():
            if count > 1:
                findings.append(
                    f"bindings.jsonl: clone {clone_id} has {count} open windows; "
                    "a clone is in one place at a time"
                )

    # --- slices -----------------------------------------------------------
    template_schema = load_schema(roles_dir, "role-template")
    crossref_schema = load_schema(roles_dir, "crossref")
    shared_owner_count: dict[str, set[str]] = defaultdict(set)
    role_dirs = [
        d for d in sorted(os.listdir(roles_dir))
        if os.path.isdir(os.path.join(roles_dir, d))
        and d not in {"schema", "registry", ".instance"}
    ]

    for role in role_dirs:
        role_path = os.path.join(roles_dir, role)
        slices: list[str] = []
        # Collected so the INDEX.md check below can compare the DESCRIPTION
        # text, not only the link path. See that check for why.
        slice_descriptions: dict[str, str] = {}
        findings += payload_shape_findings(role, role_path)
        if known_roles and role not in known_roles and role != "shared":
            findings.append(f"{role}: not a role in taxonomy.json")
        for dirpath, _dirnames, filenames in os.walk(role_path):
            for filename in sorted(filenames):
                if not filename.endswith(".md") or filename == "INDEX.md":
                    continue
                full = os.path.join(dirpath, filename)
                rel = os.path.relpath(full, role_path)
                where = f"{role}/{rel}"
                with open(full, encoding="utf-8") as fh:
                    text = fh.read()
                # skills/ and commands/ at the role root are installable
                # payload, not knowledge slices: switch.py copies them
                # verbatim into .claude/, so they carry skill/command
                # frontmatter and never provenance. Exempt from the slice
                # judgements below, and from INDEX membership — but scanned
                # for hygiene like everything else, whole file included,
                # because a credential can sit in frontmatter too.
                if rel.split(os.sep)[0] in PAYLOAD_DIRS:
                    findings += hygiene_findings(where, text)
                    continue
                slices.append(rel)
                meta = parse_frontmatter(text)
                if meta is None:
                    findings.append(f"{where}: no provenance frontmatter")
                    continue
                if template_schema:
                    findings += validate_json(template_schema, meta, where)
                if isinstance(meta.get("description"), str):
                    slice_descriptions[rel] = meta["description"]
                # charter and recall are authored, not distilled: they define
                # the role rather than assert anything about the system, so
                # they carry no evidence by nature.
                if not meta.get("derived_from") and meta.get("class") not in ("charter", "recall"):
                    findings.append(f"{where}: no derived_from — a claim with no evidence")
                for owner in meta.get("shared_with", []) or []:
                    shared_owner_count[where].add(owner)
                body = FRONTMATTER_RE.sub("", text)
                budget = TIER1_BUDGET_TOKENS if meta.get("tier") == 1 else BUDGET_TOKENS
                approx = len(body) // CHARS_PER_TOKEN
                if approx > budget * 1.35:
                    findings.append(
                        f"{where}: ~{approx} tokens exceeds the {budget} budget; split the slice"
                    )
                findings += hygiene_findings(where, body)

        index_path = os.path.join(role_path, "INDEX.md")
        if role == "shared":
            continue

        # A class is either a flat file or a directory, never both. switch.py
        # takes the directory branch and skips the flat file, so the flat one is
        # unreachable — and at tier 1 that silently retires knowledge the index
        # promises loads at activation. The assembler no longer produces this,
        # but the index is now generated from disk and so can no longer betray
        # it, which is why the condition is checked here instead.
        for klass_dir in ("domain", "solution", "intersection", "rationale",
                          "workflow", "threads"):
            if (os.path.isdir(os.path.join(role_path, klass_dir))
                    and os.path.exists(os.path.join(role_path, f"{klass_dir}.md"))):
                findings.append(
                    f"{role}: has both {klass_dir}.md and {klass_dir}/ — the flat file is "
                    "unreachable, switch.py loads only the directory"
                )

        if not os.path.exists(index_path):
            if slices:
                findings.append(f"{role}: has slices but no INDEX.md")
            continue
        with open(index_path, encoding="utf-8") as fh:
            index_text = fh.read()
        linked = set(re.findall(r"\]\(([^)]+)\)", index_text))
        for rel in slices:
            if rel not in linked:
                findings.append(f"{role}/INDEX.md: does not list {rel} — the index has drifted")
        for target in linked:
            resolved = os.path.normpath(os.path.join(role_path, target))
            if not os.path.exists(resolved):
                findings.append(f"{role}/INDEX.md: links {target}, which does not exist")

        # THE DESCRIPTION, NOT ONLY THE PATH.
        #
        # INDEX.md is generated from slice frontmatter (assemble.py), and it is
        # the only thing a session reads before deciding whether to load a
        # slice. Checking paths alone let a slice's `description:` change while
        # the index kept the old wording: lint reported clean and the index
        # quietly described something else, which is the "a hand-written index
        # drifts and then lies" failure that .roles/README.md gives as the
        # reason the index is generated at all.
        #
        # Two independent instances landed the same day in different roles
        # (#610 and #618), each hand-syncing the slice and the index line
        # together with nothing that would have caught them diverging.
        #
        # The line shape is assemble.py's, exactly:
        #     - [`path`](path) — description
        index_described: dict[str, str] = {}
        for line in index_text.splitlines():
            m = re.match(r"^- \[`([^`]+)`\]\(([^)]+)\) — (.*)$", line)
            if m and m.group(1) == m.group(2):
                index_described[m.group(2)] = m.group(3).strip()
        for rel, described in sorted(slice_descriptions.items()):
            listed = index_described.get(rel)
            if listed is None:
                # Already reported as missing above, or the line is shaped
                # differently — not this check's business to guess.
                continue
            if listed != described.strip():
                findings.append(
                    f"{role}/INDEX.md: the entry for {rel} describes it as "
                    f"{listed!r} but the slice's frontmatter says "
                    f"{described.strip()!r} — the index has drifted; "
                    f"re-run tools/roles/assemble.py"
                )

        crossref_path = os.path.join(role_path, "crossref.json")
        if os.path.exists(crossref_path):
            with open(crossref_path, encoding="utf-8") as fh:
                crossref_doc = json.load(fh)
            if crossref_schema:
                findings += validate_json(
                    crossref_schema, crossref_doc, f"{role}/crossref.json")
            findings += check_durable_references(role, crossref_doc)

    for where, owners in shared_owner_count.items():
        if len(owners) < 2:
            findings.append(
                f"{where}: shared slice owned by {len(owners)} role(s); "
                "fold it back into its single owner"
            )

    if findings:
        print(f"role-base lint: {len(findings)} finding(s)\n", file=sys.stderr)
        for finding in findings:
            print(f"  {finding}", file=sys.stderr)
        return 1
    print(f"role-base lint: clean ({len(role_dirs)} role directories)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
