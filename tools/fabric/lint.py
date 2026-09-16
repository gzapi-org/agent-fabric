#!/usr/bin/env python3
"""tools/fabric/lint.py

>>> help
Guard the committed corpus the way the contract validators guard the
wire surface.

    tools/fabric/lint.py                 # lints this agent-fabric checkout
    tools/fabric/lint.py --fabric PATH

The corpus is written by tools and read by sessions, so the failures
worth catching are the quiet ones: an index that no longer matches the
slices it points at, a slice that grew past what a session can afford to
load, provenance that points at nothing, or content that should never
have been committed at all.

Checks:
  schemas    the role catalogue, every project taxonomy, the routing
             profiles and every slice's frontmatter validate
  identity   every role directory is catalogued; charter, brief and recall
             are the only authored classes; payload is well-shaped
  index      every (project, role) index lists every slice the role has —
             its domain slices, its project slices, its charter and recall,
             its shared slices — and every index line resolves
  budgets    no slice exceeds its token budget
  shared     a shared slice really is shared (two or more owners)
  profiles   every review-grade gate in routing/profiles.json holds, and
             every role row names a catalogued role
  hygiene    no city or country names, no external project names, no
             credentials, no non-English prose
  prompt     the launch-prompt sections (identities/prompt/) exist, carry
             the {role} placeholder, are hygiene-clean and within budget

Exit 0 clean, 1 on findings, 2 on usage error. Uses jsonschema when it is
importable and falls back to a built-in structural check otherwise, so a
clean machine can still run it.
<<< help
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import sys
from collections import defaultdict
from typing import Any

_spec = importlib.util.spec_from_file_location(
    "fabric_layout", os.path.join(os.path.dirname(os.path.realpath(__file__)), "layout.py"))
layout = importlib.util.module_from_spec(_spec)
_wc_spec = importlib.util.spec_from_file_location(
    "fabric_workingcopy", os.path.join(os.path.dirname(os.path.realpath(__file__)), "workingcopy.py"))
workingcopy = importlib.util.module_from_spec(_wc_spec)
_spec.loader.exec_module(layout)
_wc_spec.loader.exec_module(workingcopy)

BUDGET_TOKENS = 1800
CHARS_PER_TOKEN = 4
TIER1_BUDGET_TOKENS = 3000

# The generic patterns plus every visible project's own list (its working
# copy's .agent-fabric/hygiene.json), loaded in main() once the working
# copies are known: layout.load_hygiene_patterns.
BANNED_PATTERNS: list = []

ITALIAN_MARKERS = re.compile(
    r"(?<![a-z])(perch[eé]|per[oò]|quindi|anche|questo|questa|quello|quella|"
    r"dovrebbe|bisogna|abbiamo|siamo|essere|molto|senza|nella|nelle|negli|"
    r"dello|della|delle|degli)(?![a-z])",
    re.I,
)

FRONTMATTER_RE = re.compile(r"^---\n(.*?)\n---\n", re.S)


PAYLOAD_DIRS = frozenset({"skills", "commands"})


def prompt_template_findings() -> list[str]:
    """The sections every launch prompt appends after the role's own files
    (tools/fabric/launch_prompt.py): each must exist, carry `{role}` so it
    is rendered for a role rather than read generically, pass hygiene, and
    the set must fit its budget — every session pays for these bytes."""
    findings: list[str] = []
    total = 0
    for name in layout.PROMPT_TEMPLATES:
        path = layout.prompt_template_path(name)
        rel = os.path.join(layout.PROMPT_DIR_NAME, name)
        if not os.path.isfile(path):
            findings.append(f"{rel}: missing — every launch prompt appends it")
            continue
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        if not text.strip():
            findings.append(f"{rel}: empty")
        if "{role}" not in text:
            findings.append(f"{rel}: no {{role}} placeholder — it would read the same for every role")
        findings += hygiene_findings(rel, text)
        total += len(text)
    approx = total // CHARS_PER_TOKEN
    if approx > layout.PROMPT_TEMPLATE_BUDGET_TOKENS:
        findings.append(f"{layout.PROMPT_DIR_NAME}: ~{approx} tokens across {', '.join(layout.PROMPT_TEMPLATES)} "
                        f"exceeds the {layout.PROMPT_TEMPLATE_BUDGET_TOKENS} budget every session pays")
    return findings


def hygiene_findings(where: str, text: str) -> list[str]:
    """Banned patterns and the language check — for slices AND payload.

    Payload is exempt from the slice judgements; it is never exempt from
    this. lint.py is the only CI pass over the corpus, and role.py copies
    payload verbatim into `.claude/` in every workspace that adopts the role, so
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
    """Assert what role.py can actually install, where it is authored.

    role.py installs a DIRECTORY under skills/ and a .md FILE under
    commands/, and skips anything else without a word. Exempting payload
    from the slice checks would otherwise make misplaced payload invisible
    twice over: silent here, silently dropped at install time.
    """
    out: list[str] = []
    if role == "shared":
        for name in sorted(PAYLOAD_DIRS):
            if os.path.isdir(os.path.join(role_path, name)):
                out.append(
                    f"shared/{name}/: shared ships no payload — role.py "
                    "resolves it as no role and never installs from it"
                )
        return out
    skills_dir = os.path.join(role_path, "skills")
    if os.path.isdir(skills_dir):
        for name in sorted(os.listdir(skills_dir)):
            entry = os.path.join(skills_dir, name)
            if not os.path.isdir(entry):
                out.append(
                    f"{role}/skills/{name}: not a directory — role.py "
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
                    f"{role}/commands/{name}: not a .md file — role.py "
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


def _structural_check(schema: dict[str, Any], doc: Any, where: str, path: str = "",
                      root: dict[str, Any] | None = None) -> list[str]:
    """The no-dependency validator: type, required, properties, items, enum,
    pattern — and the two composition keywords the schemas here use,
    local `$ref` (#/$defs/…) and `allOf`. Anything else is jsonschema's."""
    root = root if root is not None else schema
    if "$ref" in schema:
        ref = schema["$ref"]
        if ref.startswith("#/"):
            target: Any = root
            for part in ref[2:].split("/"):
                target = target.get(part, {}) if isinstance(target, dict) else {}
            merged = {k: v for k, v in schema.items() if k != "$ref"}
            problems = _structural_check(target, doc, where, path, root)
            return problems + (_structural_check(merged, doc, where, path, root) if merged else [])
    if "allOf" in schema:
        problems: list[str] = []
        for sub in schema["allOf"]:
            problems += _structural_check(sub, doc, where, path, root)
        rest = {k: v for k, v in schema.items() if k != "allOf"}
        return problems + (_structural_check(rest, doc, where, path, root) if rest else [])
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
                problems += _structural_check(sub, doc[key], where, f"{path}/{key}", root)
        extra = schema.get("additionalProperties")
        if isinstance(extra, dict):
            for key, value in doc.items():
                if key not in props:
                    problems += _structural_check(extra, value, where, f"{path}/{key}", root)
    if isinstance(doc, list):
        items = schema.get("items")
        if isinstance(items, dict):
            for i, value in enumerate(doc):
                problems += _structural_check(items, value, where, f"{path}[{i}]", root)
        if schema.get("uniqueItems") and len({json.dumps(v, sort_keys=True) for v in doc}) != len(doc):
            problems.append(f"{where}{path}: duplicate items")
    if "enum" in schema and doc not in schema["enum"]:
        problems.append(f"{where}{path}: {doc!r} not in {schema['enum']}")
    if "pattern" in schema and isinstance(doc, str) and not re.search(schema["pattern"], doc):
        problems.append(f"{where}{path}: {doc!r} does not match {schema['pattern']}")
    return problems


def model_profile_findings(root: str, doc: dict[str, Any], known_roles: set[str]) -> list[str]:
    """Invariants the schema cannot express for routing/profiles.json.

    The file is layered — defaults <- roles.<role> <- agents.<login> — over
    routing/capabilities.json, and the launcher resolves each capability
    by merging the layers. So the review gate is on the MERGED review
    model of every row, not on each layer's own value: a row that sets no
    review model inherits the provider's and is fine; one that sets a
    cheaper model is the defect this exists to catch, because a review's
    failure mode is a green PR that merges. Role rows must name roles the
    catalogue knows; agent rows are keyed by login, never by a directory.
    The rest of the routing consistency — classes, providers, shims,
    aliases, the declared review id — is tools/fabric/routing.py's check().
    """
    findings: list[str] = []
    where = "routing/profiles.json"
    routing_path = os.path.join(os.path.dirname(os.path.realpath(__file__)), "routing.py")
    spec = importlib.util.spec_from_file_location("fabric_routing", routing_path)
    routing = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(routing)
    findings += [f"routing: {f}" for f in routing.check(root)]
    grade = routing.load_review_grade(root)
    gated = grade.get("capability", "code-review")
    try:
        routing.load_capabilities(root)
    except (OSError, KeyError, ValueError):
        return findings
    rows = [("defaults", None, None)]
    rows += [("roles", name, None) for name in (doc.get("roles") or {})]
    rows += [("agents", None, name) for name in (doc.get("agents") or {})]
    for layer, role, agent in rows:
        label = layer if layer == "defaults" else f"{layer}.{role or agent}"
        for provider in routing.PROVIDERS:
            try:
                model = routing.resolve(gated, provider, role, agent, None, root)["model"]
            except (KeyError, ValueError) as exc:
                findings.append(f"{where}: {label} on {provider}: {exc}")
                continue
            if not routing.ADAPTERS[provider].is_model(model):
                continue  # an alias is the harness's choice, ungated
            if not routing.review_grade_ok(model, root):
                findings.append(f"{where}: {label} resolves {gated} on {provider} to {model!r}, which is not in "
                                "routing/policies/review-grade.json; the review class would run on it")
    # The bottom layer must give every provider a session: the launcher
    # refuses a path with none rather than guess one.
    for provider in routing.PROVIDERS:
        try:
            routing.resolve_session(root=root, provider=provider)
        except (KeyError, ValueError) as exc:
            findings.append(f"{where}: defaults name no session for {provider}: {exc}")
    if known_roles:
        for name in (doc.get("roles") or {}):
            if name not in known_roles:
                findings.append(f"{where}: roles.{name} is not a role in identities/roles/catalog.json")
    for name in (doc.get("agents") or {}):
        if "/" in name or name.startswith("clone-"):
            findings.append(f"{where}: agents.{name} is not a Linux login")
    return findings


def license_findings(root: str) -> list[str]:
    """This repository is one license, Apache-2.0, throughout — REUSE.toml
    assigns nothing else, and every identifier it does use has its text
    under LICENSES/. projects/registry.json names each project's OWN
    license as information about that project's tree; it is required (a
    project with no stated license cannot be reasoned about) but binds
    nothing here. A project's knowledge never lives here at all."""
    findings: list[str] = []
    reg_path = os.path.join(root, "projects", "registry.json")
    reuse_path = os.path.join(root, "REUSE.toml")
    if not os.path.exists(reg_path):
        return findings
    try:
        registry = json.load(open(reg_path, encoding="utf-8"))
    except (OSError, ValueError):
        return findings  # the registry's own parse is reported elsewhere
    for pid, entry in sorted((registry.get("projects") or {}).items()):
        lic = entry.get("license")
        if not isinstance(lic, str) or not lic:
            findings.append(f"projects/registry.json: project {pid!r} names no license")
        if os.path.isdir(os.path.join(root, "memory", "projects", pid)):
            findings.append(f"memory/projects/{pid}/: a project's knowledge lives in the project's repository "
                            "(<working copy>/.agent-fabric/memory/), not here")
    if not os.path.exists(reuse_path):
        findings.append("REUSE.toml: missing; the repository states its license there")
        return findings
    try:
        import tomllib
        reuse = tomllib.load(open(reuse_path, "rb"))
    except Exception as exc:  # noqa: BLE001 - any parse failure is the finding
        return [f"REUSE.toml: does not parse ({exc})"]
    licenses_dir = os.path.join(root, "LICENSES")
    for ann in reuse.get("annotations") or []:
        lic = ann.get("SPDX-License-Identifier", "")
        if lic != "Apache-2.0":
            findings.append(f"REUSE.toml: assigns {lic!r} to {ann.get('path')}; this repository is Apache-2.0 throughout")
        if lic and not os.path.exists(os.path.join(licenses_dir, lic + ".txt")):
            findings.append(f"REUSE.toml: {lic!r} has no LICENSES/{lic}.txt")
    return findings


CLASS_DOCS = {
    # Where the class list is written out for a reader; each must name every
    # class in routing/capabilities.json and nothing that is not one — the
    # README said `review` for a class named code-review until 2026-09-16.
    "README.md": r"`routing/capabilities.json` classes:([^|\n]*)",
    "CLAUDE.md": r"name a capability class in `subagent_type`[^.]*?the five\s+are (.*?)— and",
}


def class_doc_findings(root: str) -> list[str]:
    """The capability class names a document lists must be exactly the
    classes routing/capabilities.json defines."""
    findings: list[str] = []
    cap_path = os.path.join(root, "routing", "capabilities.json")
    try:
        classes = set((json.load(open(cap_path, encoding="utf-8")).get("classes") or {}).keys())
    except (OSError, ValueError):
        return findings  # the file's own parse is reported by the routing check
    if not classes:
        return findings
    for rel, pattern in CLASS_DOCS.items():
        path = os.path.join(root, rel)
        try:
            text = open(path, encoding="utf-8").read()
        except OSError:
            continue
        m = re.search(pattern, text, flags=re.S)
        if not m:
            findings.append(f"{rel}: the capability class list was not found (lint looks for {pattern!r})")
            continue
        named = set(re.findall(r"`([a-z][a-z0-9-]*)`", m.group(1)))
        for extra in sorted(named - classes):
            findings.append(f"{rel}: names capability class {extra!r}, which routing/capabilities.json does not define "
                            f"(classes: {', '.join(sorted(classes))})")
        for missing in sorted(classes - named):
            findings.append(f"{rel}: does not name capability class {missing!r} (routing/capabilities.json defines it)")
    return findings


def load_schema(root: str, subdir: str, name: str) -> dict[str, Any] | None:
    path = os.path.join(root, subdir, f"{name}.schema.json")
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def load_json(path: str, where: str, findings: list[str]) -> Any:
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except ValueError as exc:
        findings.append(f"{where}: not valid JSON ({exc})")
        return None


CLASS_DIRS = ("domain", "solution", "intersection", "rationale", "workflow", "threads")


def lint_slices(base: str, where_prefix: str, template_schema: dict[str, Any] | None,
                findings: list[str], shared_owner_count: dict[str, set[str]],
                descriptions: dict[str, str], project: str | None = None) -> list[str]:
    """Judge every slice under `base`; return their paths as an index links
    them (relative to the fabric root, or to the project's working copy
    when `project` names one whose memory lives in its repository)."""
    slices: list[str] = []
    if not os.path.isdir(base):
        return slices
    for dirpath, dirnames, filenames in os.walk(base):
        # Payload is exempt only at the ROOT of a role identity directory:
        # `identities/roles/<role>/skills/`. A `skills/` nested anywhere
        # else is a directory of slices like any other.
        if dirpath == base and where_prefix.startswith("identities/"):
            dirnames[:] = [d for d in dirnames if d not in PAYLOAD_DIRS]
        for filename in sorted(filenames):
            # README.md is documentation of a directory, never a slice.
            if not filename.endswith(".md") or filename in ("INDEX.md", "README.md"):
                continue
            full = os.path.join(dirpath, filename)
            rel = layout.link_rel(full, project)
            with open(full, encoding="utf-8") as fh:
                text = fh.read()
            slices.append(rel)
            meta = parse_frontmatter(text)
            if meta is None:
                findings.append(f"{rel}: no provenance frontmatter")
                continue
            if template_schema:
                findings += validate_json(template_schema, meta, rel)
            if isinstance(meta.get("description"), str):
                descriptions[rel] = meta["description"]
            # charter, brief and recall are authored, not distilled: they define
            # the role rather than assert anything about the system, so
            # they carry no evidence by nature — and they live ONLY under
            # identities/roles/; a slice of that class anywhere in memory/
            # is a hand-authored claim smuggled past provenance.
            klass = meta.get("class")
            if klass in layout.IDENTITY_CLASSES and not where_prefix.startswith("identities/"):
                findings.append(f"{rel}: class {klass!r} is authored role identity and "
                                "belongs under identities/roles/, not in memory/")
            if not meta.get("derived_from") and klass not in layout.IDENTITY_CLASSES:
                findings.append(f"{rel}: no derived_from — a claim with no evidence")
            for owner in meta.get("shared_with", []) or []:
                shared_owner_count[rel].add(owner)
            body = FRONTMATTER_RE.sub("", text)
            budget = TIER1_BUDGET_TOKENS if meta.get("tier") == 1 else BUDGET_TOKENS
            approx = len(body) // CHARS_PER_TOKEN
            if approx > budget * 1.35:
                findings.append(f"{rel}: ~{approx} tokens exceeds the {budget} budget; split the slice")
            findings += hygiene_findings(rel, body)
    return slices


def flat_and_dir_findings(base: str, label: str) -> list[str]:
    """A class is either a flat file or a directory, never both. The
    activator takes the directory branch and skips the flat file, so the
    flat one is unreachable — and at tier 1 that silently retires knowledge
    the index promises loads at activation."""
    out: list[str] = []
    for klass_dir in CLASS_DIRS:
        if (os.path.isdir(os.path.join(base, klass_dir))
                and os.path.exists(os.path.join(base, f"{klass_dir}.md"))):
            out.append(f"{label}: has both {klass_dir}.md and {klass_dir}/ — the flat file is "
                       "unreachable, the activator loads only the directory")
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="Lint the committed corpus.")
    ap.add_argument("--fabric", default=None, help="agent-fabric root (default: this checkout)")
    ap.add_argument("--working-copy", action="append", default=[], metavar="[PROJECT=]DIR",
                    help="a managed project's checkout whose .agent-fabric/memory/ is linted too "
                         "(repeatable; the project is resolved from the checkout's remote unless "
                         "named as PROJECT=DIR)")
    args = ap.parse_args()
    if args.fabric:
        layout.FABRIC_ROOT = os.path.abspath(args.fabric)
    root = layout.FABRIC_ROOT
    if not os.path.isdir(os.path.join(root, "identities")):
        print(f"lint: no agent-fabric checkout at {root}", file=sys.stderr)
        return 2
    for wc in args.working_copy:
        pid, sep, path = wc.partition("=")
        if not sep:
            pid, path = workingcopy.resolve(wc).get("project"), wc
        if not pid:
            print(f"lint: {wc} is not a working copy of a registered project "
                  "(name it as PROJECT=DIR)", file=sys.stderr)
            return 2
        layout.set_working_copy(pid, path)

    findings: list[str] = []
    schemas = os.path.join("identities", "schemas")
    # Every project whose working copy this run knows contributes its
    # hygiene list — whether or not that working copy holds memory yet.
    BANNED_PATTERNS[:] = layout.load_hygiene_patterns(
        sorted(set(layout.list_projects()) | set(layout.explicit_working_copies())))

    # --- the role catalogue ------------------------------------------------
    known_roles: set[str] = set()
    catalog_schema = load_schema(root, schemas, "catalog")
    catalog_path = layout.catalog_path()
    if os.path.exists(catalog_path):
        catalog = load_json(catalog_path, "identities/roles/catalog.json", findings)
        if catalog is not None:
            if catalog_schema:
                findings += validate_json(catalog_schema, catalog, "identities/roles/catalog.json")
            known_roles = {r.get("id") for r in catalog.get("roles", []) if isinstance(r, dict)}
    else:
        findings.append("identities/roles/catalog.json: missing")

    # --- project bindings --------------------------------------------------
    # A project's taxonomy lives in its working copy (.agent-fabric/
    # taxonomy.json) — the fabric's own included — or, for a project not
    # yet moved, under projects/<id>/ here. Judged for every project whose
    # taxonomy this run can reach.
    taxonomy_schema = load_schema(root, os.path.join("projects", "schemas"), "taxonomy")
    projects_root = os.path.join(root, "projects")
    project_ids: list[str] = []
    registry_ids: list[str] = []
    try:
        registry_ids = sorted((json.load(open(os.path.join(projects_root, "registry.json"), encoding="utf-8"))
                               .get("projects") or {}).keys())
    except (OSError, ValueError):
        pass
    bound_here_ids = [d for d in (sorted(os.listdir(projects_root)) if os.path.isdir(projects_root) else [])
                      if os.path.isfile(os.path.join(projects_root, d, "taxonomy.json"))]
    for pid in sorted(set(registry_ids) | set(bound_here_ids) | set(layout.explicit_working_copies())):
        if True:
            tax_path = layout.project_taxonomy_path(pid)
            if not tax_path:
                continue
            project_ids.append(pid)
            where = (f"projects/{pid}/taxonomy.json" if tax_path.startswith(root)
                     else f"{pid}:{layout.PROJECT_DIRNAME}/taxonomy.json")
            tax = load_json(tax_path, where, findings)
            if tax is None:
                continue
            if taxonomy_schema:
                findings += validate_json(taxonomy_schema, tax, where)
            if tax.get("project") not in (None, pid):
                findings.append(f"{where}: names project {tax.get('project')!r} but lives under {pid}/")
            for r in tax.get("roles", []) or []:
                rid = r.get("id") if isinstance(r, dict) else None
                if known_roles and rid not in known_roles:
                    findings.append(f"{where}: role {rid!r} is not in identities/roles/catalog.json")
                for prefix in (r.get("paths") if isinstance(r, dict) else None) or []:
                    if os.path.isabs(prefix) or prefix.startswith("~"):
                        findings.append(f"{where}: role {rid!r} path {prefix!r} is machine-specific; "
                                        "paths must be repository-relative")

    # --- licenses ----------------------------------------------------------
    findings += license_findings(root)

    # --- the class list a reader sees --------------------------------------
    findings += class_doc_findings(root)

    # --- routing profiles --------------------------------------------------
    profiles_schema = load_schema(root, os.path.join("routing", "schemas"), "model-profiles")
    profiles_path = os.path.join(root, "routing", "profiles.json")
    if profiles_schema and os.path.exists(profiles_path):
        profiles = load_json(profiles_path, "routing/profiles.json", findings)
        if profiles is not None:
            schema_findings = validate_json(profiles_schema, profiles, "routing/profiles.json")
            findings += schema_findings
            if not schema_findings:
                findings += model_profile_findings(root, profiles, known_roles)

    # --- role identities ---------------------------------------------------
    template_schema = load_schema(root, schemas, "role-template")
    crossref_schema = load_schema(root, schemas, "crossref")
    shared_owner_count: dict[str, set[str]] = defaultdict(set)
    descriptions: dict[str, str] = {}
    identity_slices: dict[str, list[str]] = {}
    roles_dir = layout.roles_dir()
    role_ids = [d for d in sorted(os.listdir(roles_dir))
                if os.path.isdir(os.path.join(roles_dir, d))] if os.path.isdir(roles_dir) else []
    for role in role_ids:
        role_path = os.path.join(roles_dir, role)
        if known_roles and role not in known_roles:
            findings.append(f"identities/roles/{role}: not in identities/roles/catalog.json")
        if not os.path.isfile(os.path.join(role_path, "charter.md")):
            findings.append(f"identities/roles/{role}: no charter.md — a role without a charter has no boundary")
        findings += payload_shape_findings(role, role_path)
        for sub in sorted(PAYLOAD_DIRS):
            payload = os.path.join(role_path, sub)
            if os.path.isdir(payload):
                for dirpath, _d, filenames in os.walk(payload):
                    for filename in sorted(filenames):
                        if filename.endswith(".md"):
                            full = os.path.join(dirpath, filename)
                            with open(full, encoding="utf-8") as fh:
                                findings += hygiene_findings(layout.root_rel(full), fh.read())
        identity_slices[role] = lint_slices(role_path, f"identities/roles/{role}", template_schema,
                                            findings, shared_owner_count, descriptions)
        for rel in identity_slices[role]:
            klass = (parse_frontmatter(open(os.path.join(root, rel), encoding="utf-8").read()) or {}).get("class")
            if klass not in layout.IDENTITY_CLASSES:
                findings.append(f"{rel}: class {klass!r} is knowledge, not identity — it belongs under memory/")
    for role in known_roles - set(role_ids):
        findings.append(f"identities/roles/catalog.json: role {role!r} has no identities/roles/{role}/ directory")

    # --- domain memory -----------------------------------------------------
    domain_slices: dict[str, list[str]] = {}
    domains_root = os.path.join(root, "memory", "domains")
    if os.path.isdir(domains_root):
        for domain in sorted(os.listdir(domains_root)):
            base = os.path.join(domains_root, domain)
            if not os.path.isdir(base):
                continue
            findings += flat_and_dir_findings(base, f"memory/domains/{domain}")
            domain_slices[domain] = lint_slices(base, f"memory/domains/{domain}", template_schema,
                                                findings, shared_owner_count, descriptions)

    # --- project memory, and the indexes ------------------------------------
    # A project's memory lives in ITS repository (<working copy>/.agent-fabric/
    # memory/); this run sees the projects whose working copy it knows.
    # Index links are relative to the working copy; fabric-side slices
    # reach back through ../agent-fabric/, which resolve_link maps onto
    # this checkout.
    indexed_domains: set[str] = set()
    for pid in layout.list_projects():
        pbase = layout.project_memory_root(pid)
        plabel = f"{pid}:{layout.PROJECT_MEMORY_SUBDIR}"
        if project_ids and pid not in project_ids:
            findings.append(f"{plabel}: no projects/{pid}/taxonomy.json binds this project")
        for role in sorted(os.listdir(pbase)):
            rbase = os.path.join(pbase, role)
            if not os.path.isdir(rbase):
                continue
            label = f"{plabel}/{role}"
            if role == "shared":
                lint_slices(rbase, label, template_schema, findings, shared_owner_count, descriptions, pid)
                continue
            if known_roles and role not in known_roles:
                findings.append(f"{label}: not a role in identities/roles/catalog.json")
            findings += flat_and_dir_findings(rbase, label)
            slices = lint_slices(rbase, label, template_schema, findings, shared_owner_count, descriptions, pid)
            # Fabric-side slices as THIS project's index links them.
            fabric_side = {layout.link_rel(os.path.join(root, r), pid): r
                           for r in domain_slices.get(role, []) + identity_slices.get(role, [])}
            expected = list(slices) + list(fabric_side)
            indexed_domains.add(role)

            index_path = os.path.join(rbase, "INDEX.md")
            if not os.path.exists(index_path):
                if expected:
                    findings.append(f"{label}: has slices but no INDEX.md")
                continue
            with open(index_path, encoding="utf-8") as fh:
                index_text = fh.read()
            linked = set(re.findall(r"\]\(([^)]+)\)", index_text))
            for rel in expected:
                if rel not in linked:
                    findings.append(f"{label}/INDEX.md: does not list {rel} — the index has drifted")
            for target in linked:
                if not os.path.exists(layout.resolve_link(target, pid)):
                    findings.append(f"{label}/INDEX.md: links {target}, which does not exist")

            # THE DESCRIPTION, NOT ONLY THE PATH. INDEX.md is generated from
            # slice frontmatter (assemble.py), and it is the only thing a
            # session reads before deciding whether to load a slice. Checking
            # paths alone let a slice's description change while the index
            # kept the old wording: lint reported clean and the index quietly
            # described something else. The line shape is assemble.py's:
            #     - [`path`](path) — description
            index_described: dict[str, str] = {}
            for line in index_text.splitlines():
                m = re.match(r"^- \[`([^`]+)`\]\(([^)]+)\) — (.*)$", line)
                if m and m.group(1) == m.group(2):
                    index_described[m.group(2)] = m.group(3).strip()
            for rel in sorted(expected):
                listed = index_described.get(rel)
                described = descriptions.get(fabric_side.get(rel, rel))
                if listed is None or described is None:
                    continue
                if listed != described.strip():
                    findings.append(
                        f"{label}/INDEX.md: the entry for {rel} describes it as "
                        f"{listed!r} but the slice's frontmatter says "
                        f"{described.strip()!r} — the index has drifted; "
                        f"re-run tools/fabric/assemble.py"
                    )

            crossref_path = os.path.join(rbase, "crossref.json")
            if os.path.exists(crossref_path):
                crossref_doc = load_json(crossref_path, f"{label}/crossref.json", findings)
                if crossref_doc is not None:
                    if crossref_schema:
                        findings += validate_json(crossref_schema, crossref_doc, f"{label}/crossref.json")
                    findings += check_durable_references(label, crossref_doc)

    # A domain's slices are listed by the project indexes of the role that
    # owns them. That can only be judged for roles some VISIBLE project
    # files knowledge for: once a project's memory lives in its repository,
    # a lint run that cannot see that working copy sees no index for it —
    # which is absence of evidence, not drift.
    # So: judged whenever some managed project's memory (other than this
    # repository's own) is visible to this run; silent otherwise.
    projects_visible = any(pid != layout.FABRIC_PROJECT_ID for pid in layout.list_projects())
    for domain, slices in domain_slices.items():
        if slices and domain not in indexed_domains and projects_visible:
            findings.append(f"memory/domains/{domain}: {len(slices)} slice(s) indexed by no project — "
                            f"no project's .agent-fabric/memory/{domain}/INDEX.md lists them "
                            "(pass --working-copy for a project whose memory lives in its repository)")

    # --- shared ----------------------------------------------------------------
    shared_root = layout.shared_dir()
    if os.path.isdir(shared_root):
        lint_slices(shared_root, "memory/shared", template_schema, findings, shared_owner_count, descriptions)
    for where, owners in shared_owner_count.items():
        if len(owners) < 2:
            findings.append(f"{where}: shared slice owned by {len(owners)} role(s); "
                            "fold it back into its single owner")

    # --- launch prompt sections --------------------------------------------
    findings += prompt_template_findings()

    if findings:
        print(f"corpus lint: {len(findings)} finding(s)\n", file=sys.stderr)
        for finding in findings:
            print(f"  {finding}", file=sys.stderr)
        return 1
    print(f"corpus lint: clean ({len(role_ids)} roles, {len(domain_slices)} domains, "
          f"{len(layout.list_projects())} project(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
