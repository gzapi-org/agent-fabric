#!/usr/bin/env python3
"""tools/fabric/routing.py — capability -> model -> family shim.

Two independent dimensions, one derived artifact:

    CAPABILITY CLASS -> CONCRETE MODEL       routing/capabilities.json (+ profile layers)
    MODEL FAMILY     -> COMPATIBILITY SHIM   routing/shims.json
    model @ shim                             derived here, at runtime, never committed

    routing.py resolve code-high                      # openrouter by default
    routing.py resolve code-high --provider anthropic
    routing.py table [--provider P]
    routing.py check                                  # validate the canonical files

Profile layers (routing/profiles.json and the agent's local override) may
override a class's model; the shim is looked up on the MERGED model, so an
override to another family gets that family's shim, or none.
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import sys
from typing import Any

FABRIC_ROOT = os.environ.get("AGENT_FABRIC_ROOT") or os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.realpath(__file__))))

MODEL_ID = re.compile(r"^~?[a-z0-9-]+/[a-z0-9.-]+(:[a-z]+)?(\[1m\])?$")
# A harness model reference: a tier alias (`opus`) or a full id without a
# vendor prefix (`claude-opus-5[1m]`).
HARNESS_REF = re.compile(r"^[a-z][a-z0-9.-]*(\[1m\])?$")
PRESET = re.compile(r"^@preset/[a-z0-9-]+$")
COMPOSITE = re.compile(r"^~?[a-z0-9-]+/[a-z0-9.-]+(:[a-z]+)?(\[1m\])?(@preset/[a-z0-9-]+)?$")


def _load(path: str) -> Any:
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def routing_dir(root: str | None = None) -> str:
    return os.path.join(root or FABRIC_ROOT, "routing")


def load_capabilities(root: str | None = None) -> dict[str, Any]:
    return _load(os.path.join(routing_dir(root), "capabilities.json"))


def load_shims(root: str | None = None) -> list[dict[str, Any]]:
    return _load(os.path.join(routing_dir(root), "shims.json")).get("shims") or []


def load_review_grade(root: str | None = None) -> dict[str, Any]:
    path = os.path.join(routing_dir(root), "policies", "review-grade.json")
    return _load(path) if os.path.exists(path) else {"capability": "review", "models": []}


def load_profiles(root: str | None = None) -> dict[str, Any]:
    path = os.path.join(routing_dir(root), "profiles.json")
    return _load(path) if os.path.exists(path) else {"version": 2, "defaults": {}}


def shim_for(model: str, shims: list[dict[str, Any]], harness: str = "claude-code") -> str | None:
    """The shim a model's family needs for `harness`, or None. A bare
    `@preset/...` is already a preset and gets nothing attached."""
    if not model or PRESET.match(model):
        return None
    for entry in shims:
        if entry.get("harness", "claude-code") != harness:
            continue
        if fnmatch.fnmatchcase(model, entry["family"]):
            return entry["shim"]
    return None


def composite(model: str, shim: str | None) -> str:
    """The runtime string: `model@preset/slug`, or the model alone."""
    return f"{model}{shim}" if shim else model


def deep_merge(base: dict[str, Any], over: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(over, dict):
        raise ValueError(f"a profile layer is {over!r}, not an object")
    out = dict(base)
    for k, v in over.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = v
    return out


def merged_profile(role: str | None, agent: str | None, local: dict[str, Any] | None = None,
                   root: str | None = None) -> dict[str, Any]:
    """defaults <- roles.<role> <- agents.<agent> <- local, as one profile."""
    profiles = load_profiles(root)
    merged = deep_merge({}, profiles.get("defaults") or {})
    if role:
        merged = deep_merge(merged, (profiles.get("roles") or {}).get(role) or {})
    if agent:
        merged = deep_merge(merged, (profiles.get("agents") or {}).get(agent) or {})
    if local:
        merged = deep_merge(merged, local)
    return merged


def resolve(capability: str, provider: str = "openrouter", role: str | None = None,
            agent: str | None = None, local: dict[str, Any] | None = None,
            root: str | None = None, harness: str = "claude-code") -> dict[str, Any]:
    caps = load_capabilities(root)
    if capability not in caps["classes"]:
        raise KeyError(f"unknown capability class {capability!r}; known: {sorted(caps['classes'])}")
    prov = caps["providers"].get(provider)
    if prov is None:
        raise KeyError(f"unknown provider {provider!r}; known: {sorted(caps['providers'])}")
    model = prov["models"].get(capability)
    source = f"capabilities.providers.{provider}"
    if prov["resolution"] == "model-id":
        override = (merged_profile(role, agent, local, root).get("capabilities") or {}).get(capability)
        if override:
            model, source = override, "profile"
    if not model:
        raise KeyError(f"provider {provider!r} binds no model to {capability!r}")
    if prov["resolution"] == "harness":
        return {"capability": capability, "provider": provider, "model": model, "shim": None,
                "composite": model, "resolution": "harness", "source": source}
    shim = shim_for(model, load_shims(root), harness)
    return {"capability": capability, "provider": provider, "model": model, "shim": shim,
            "composite": composite(model, shim), "resolution": "model-id", "source": source}


def resolve_session(role: str | None = None, agent: str | None = None,
                    local: dict[str, Any] | None = None, root: str | None = None,
                    harness: str = "claude-code") -> dict[str, Any]:
    """The main agent's model on the broker path, with its family shim.
    Separate from capability resolution: the session is not a class."""
    model = merged_profile(role, agent, local, root).get("session")
    if not model:
        raise KeyError("no session model: routing/profiles.json defaults must carry one")
    shim = shim_for(model, load_shims(root), harness)
    return {"model": model, "shim": shim, "composite": composite(model, shim)}


def review_grade_ok(model: str, root: str | None = None) -> bool:
    return model in (load_review_grade(root).get("models") or [])


def check(root: str | None = None) -> list[str]:
    """Consistency findings across the canonical files; empty means clean."""
    findings: list[str] = []
    caps = load_capabilities(root)
    classes = set(caps.get("classes") or {})
    for name, prov in (caps.get("providers") or {}).items():
        for klass, model in (prov.get("models") or {}).items():
            if klass not in classes:
                findings.append(f"capabilities.json: providers.{name} binds unknown class {klass!r}")
            if PRESET.match(model or "") or "@preset/" in (model or ""):
                findings.append(f"capabilities.json: providers.{name}.{klass} {model!r} carries a preset; "
                                "a preset is a shim (routing/shims.json), not a model")
            if prov.get("resolution") == "model-id" and not MODEL_ID.match(model or ""):
                findings.append(f"capabilities.json: providers.{name}.{klass} {model!r} is not a model id")
            if prov.get("resolution") == "harness" and not HARNESS_REF.match(model or ""):
                findings.append(f"capabilities.json: providers.{name}.{klass} {model!r} is not a harness model reference")
        for klass in classes:
            if klass not in (prov.get("models") or {}):
                findings.append(f"capabilities.json: providers.{name} binds no model to {klass!r}")
    for entry in load_shims(root):
        if not PRESET.match(entry.get("shim") or ""):
            findings.append(f"shims.json: {entry.get('family')!r} -> {entry.get('shim')!r} is not a preset reference")
    grade = load_review_grade(root)
    if grade.get("capability") not in classes:
        findings.append(f"review-grade.json: gates unknown capability {grade.get('capability')!r}")
    for model in grade.get("models") or []:
        if not MODEL_ID.match(model):
            findings.append(f"review-grade.json: {model!r} is not a model id")
    # The review class on every model-id provider must be review-grade.
    for name, prov in (caps.get("providers") or {}).items():
        if prov.get("resolution") == "model-id":
            model = (prov.get("models") or {}).get(grade.get("capability"))
            if model and not review_grade_ok(model, root):
                findings.append(f"capabilities.json: providers.{name}.{grade.get('capability')} {model!r} "
                                "is not in routing/policies/review-grade.json")
    # The Claude Code binding: every class is either alias-bound or declared
    # by full id, aliases are unique (one export per alias), and the harness
    # provider in capabilities.json says the same thing.
    aliases_path = os.path.join(root or FABRIC_ROOT, "runtime", "claude-code", "aliases.json")
    if os.path.exists(aliases_path):
        doc = _load(aliases_path)
        aliases = doc.get("aliases") or {}
        declared = doc.get("declared") or {}
        bound = set(aliases) | set(declared)
        if bound != classes:
            findings.append(f"runtime/claude-code/aliases.json: bound classes {sorted(bound)} != {sorted(classes)}")
        if set(aliases) & set(declared):
            findings.append("runtime/claude-code/aliases.json: a class is both alias-bound and declared")
        if len(set(aliases.values())) != len(aliases):
            findings.append("runtime/claude-code/aliases.json: two classes share one harness alias; "
                            "the launcher could not export them separately")
        for klass, alias in aliases.items():
            if alias not in (doc.get("env") or {}):
                findings.append(f"runtime/claude-code/aliases.json: alias {alias!r} has no export variable")
        native = ((caps.get("providers") or {}).get("anthropic") or {}).get("models") or {}
        for klass, ref in {**aliases, **declared}.items():
            if native.get(klass) not in (None, ref):
                findings.append(f"aliases.json binds {klass} to {ref!r} but capabilities.providers.anthropic "
                                f"says {native.get(klass)!r}")
        # A declared class's broker model must be the same model the agent
        # file names (vendor prefix aside): the request carries the declared
        # id, so a broker profile saying otherwise would be a lie.
        for name, prov in (caps.get("providers") or {}).items():
            if prov.get("resolution") != "model-id":
                continue
            for klass, ref in declared.items():
                model = (prov.get("models") or {}).get(klass) or ""
                if model.split("/", 1)[-1] != ref:
                    findings.append(f"capabilities.json: providers.{name}.{klass} {model!r} does not name the "
                                    f"declared harness id {ref!r} (aliases.json); the request names the declared id")
    return findings


def declared_classes(root: str | None = None) -> dict[str, str]:
    """Classes the Claude Code adapter binds by full model id, not alias."""
    path = os.path.join(root or FABRIC_ROOT, "runtime", "claude-code", "aliases.json")
    return (_load(path).get("declared") or {}) if os.path.exists(path) else {}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("--fabric", default=None, help="agent-fabric root (default: this checkout)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("resolve", help="resolve one capability class")
    r.add_argument("capability")
    r.add_argument("--provider", default="openrouter")
    r.add_argument("--role", default=None)
    r.add_argument("--agent", default=None)
    r.add_argument("--json", action="store_true")
    t = sub.add_parser("table", help="every class, resolved")
    t.add_argument("--provider", default="openrouter")
    t.add_argument("--role", default=None)
    t.add_argument("--agent", default=None)
    sub.add_parser("check", help="validate the canonical routing files")
    args = ap.parse_args(argv)
    root = os.path.abspath(args.fabric) if args.fabric else None

    if args.cmd == "check":
        findings = check(root)
        for f in findings:
            print(f"  {f}", file=sys.stderr)
        print("routing: clean" if not findings else f"routing: {len(findings)} finding(s)")
        return 1 if findings else 0
    if args.cmd == "resolve":
        res = resolve(args.capability, args.provider, args.role, args.agent, root=root)
        if args.json:
            print(json.dumps(res, indent=2, sort_keys=True))
        else:
            print(res["composite"])
        return 0
    caps = load_capabilities(root)
    for klass in caps["classes"]:
        res = resolve(klass, args.provider, args.role, args.agent, root=root)
        print(f"{klass:12} -> {res['model']:32} shim: {res['shim'] or '-':28} => {res['composite']}")
    if caps["providers"][args.provider]["resolution"] == "model-id":
        s = resolve_session(args.role, args.agent, root=root)
        print(f"{'session':12} -> {s['model']:32} shim: {s['shim'] or '-':28} => {s['composite']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
