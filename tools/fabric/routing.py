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
    routing.py shim <model>                           # the family shim a bare model id needs, if any
    routing.py pins                                   # classes the anthropic column pins: <class> <alias> <id>

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
# A harness model reference: a tier alias (`opus`, `fable`) — the only form
# the Agent tool's `model` field accepts.
HARNESS_REF = re.compile(r"^(haiku|sonnet|opus|fable)$")
# A native Anthropic model id, as `claude` itself names it: what the harness
# provider's column holds when the fabric decides a tier's model on the
# vanilla path rather than leaving it to the harness's own default.
NATIVE_ID = re.compile(r"^claude-[a-z0-9.-]+(\[1m\])?$")
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
        # An alias leaves the tier to the harness; a native id pins it —
        # exported as the alias's ANTHROPIC_DEFAULT_*_MODEL by the launcher.
        return {"capability": capability, "provider": provider, "model": model, "shim": None,
                "composite": model, "resolution": "harness", "source": source,
                "pinned": bool(NATIVE_ID.match(model))}
    shim = shim_for(model, load_shims(root), harness)
    return {"capability": capability, "provider": provider, "model": model, "shim": shim,
            "composite": composite(model, shim), "resolution": "model-id", "source": source}


def resolve_session(role: str | None = None, agent: str | None = None,
                    local: dict[str, Any] | None = None, root: str | None = None,
                    harness: str = "claude-code", provider: str = "openrouter") -> dict[str, Any]:
    """The main agent's model, with its family shim on the broker path.
    Separate from capability resolution: the session is not a class. The
    profile names the session as an OpenRouter id; on the anthropic
    provider (plain `claude`) the same value is spoken natively — the
    `anthropic/` prefix dropped — and a model of any other vendor cannot
    run there, so it is refused rather than mistranslated."""
    model = merged_profile(role, agent, local, root).get("session")
    if not model:
        raise KeyError("no session model: routing/profiles.json defaults must carry one")
    if provider == "anthropic":
        # A layer's session is usually a broker choice (an agent's local
        # override to GLM says nothing about what it wants on plain claude),
        # so the nearest layer naming an Anthropic model wins: local, agent,
        # role, defaults. None at all is refused, not mistranslated.
        profiles = load_profiles(root)
        layers = [("local", local or {}),
                  ("agent", (profiles.get("agents") or {}).get(agent) or {} if agent else {}),
                  ("role", (profiles.get("roles") or {}).get(role) or {} if role else {}),
                  ("defaults", profiles.get("defaults") or {})]
        for layer, body in layers:
            candidate = body.get("session")
            if isinstance(candidate, str) and candidate.startswith("anthropic/"):
                native = candidate[len("anthropic/"):]
                return {"model": native, "shim": None, "composite": native, "openrouter_id": candidate,
                        "source": layer, "skipped": model if candidate != model else None}
        raise KeyError(f"session model {model!r} is not an Anthropic model and no profile layer names one; plain claude cannot run it")
    shim = shim_for(model, load_shims(root), harness)
    return {"model": model, "shim": shim, "composite": composite(model, shim)}


def review_grade_ok(model: str, root: str | None = None) -> bool:
    """Admitted by routing/policies/review-grade.json, whose entries are
    OpenRouter ids; a native id (claude-…) is the same model spelled as
    plain claude names it, so it is compared under `anthropic/`."""
    if NATIVE_ID.match(model):
        model = "anthropic/" + model
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
            if prov.get("resolution") == "harness" and not (HARNESS_REF.match(model or "") or NATIVE_ID.match(model or "")):
                findings.append(f"capabilities.json: providers.{name}.{klass} {model!r} is neither a harness tier alias nor a native Claude id")
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
    # The review class must be review-grade wherever the fabric names its
    # model: on every model-id provider, and on the harness provider when
    # the column pins a native id (an alias is the harness's choice, ungated).
    for name, prov in (caps.get("providers") or {}).items():
        model = (prov.get("models") or {}).get(grade.get("capability"))
        if model and (prov.get("resolution") == "model-id" or NATIVE_ID.match(model)):
            if not review_grade_ok(model, root):
                findings.append(f"capabilities.json: providers.{name}.{grade.get('capability')} {model!r} "
                                "is not in routing/policies/review-grade.json")
    # The Claude Code binding: every class rides a harness tier alias (the
    # Agent tool's `model` field accepts nothing else), aliases are unique
    # (one export per alias), and the harness provider in capabilities.json
    # says the same thing.
    aliases_path = os.path.join(root or FABRIC_ROOT, "runtime", "claude-code", "aliases.json")
    if os.path.exists(aliases_path):
        doc = _load(aliases_path)
        aliases = doc.get("aliases") or {}
        if "declared" in doc:
            findings.append("runtime/claude-code/aliases.json: `declared` is retired; the Agent tool cannot "
                            "name a full model id, so every class must ride an alias")
        if set(aliases) != classes:
            findings.append(f"runtime/claude-code/aliases.json: bound classes {sorted(aliases)} != {sorted(classes)}")
        if len(set(aliases.values())) != len(aliases):
            findings.append("runtime/claude-code/aliases.json: two classes share one harness alias; "
                            "the launcher could not export them separately")
        for klass, alias in aliases.items():
            if alias not in (doc.get("env") or {}):
                findings.append(f"runtime/claude-code/aliases.json: alias {alias!r} has no export variable")
        native = ((caps.get("providers") or {}).get("anthropic") or {}).get("models") or {}
        for klass, ref in aliases.items():
            if native.get(klass) not in (None, ref) and not NATIVE_ID.match(native.get(klass) or ""):
                findings.append(f"aliases.json binds {klass} to {ref!r} but capabilities.providers.anthropic "
                                f"says {native.get(klass)!r}")
    return findings


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
    s = sub.add_parser("pins", help="classes the harness provider pins to a native id: `<class> <alias> <id>` per line")
    s = sub.add_parser("shim", help="the family shim a model id needs, or nothing")
    s.add_argument("model")
    s.add_argument("--harness", default="claude-code")
    args = ap.parse_args(argv)
    root = os.path.abspath(args.fabric) if args.fabric else None

    if args.cmd == "pins":
        # For the dispatch guard and bootstrap: which classes the anthropic
        # column pins (a native id), with the alias each class rides. One
        # line per pin, nothing when none; exit 0 either way.
        aliases = (_load(os.path.join(root or FABRIC_ROOT, "runtime", "claude-code", "aliases.json")) or {}).get("aliases") or {}
        for klass in load_capabilities(root)["classes"]:
            res = resolve(klass, "anthropic", root=root)
            if res.get("pinned"):
                print(f"{klass} {aliases.get(klass, '')} {res['model']}")
        return 0
    if args.cmd == "shim":
        # One line, the shim or nothing; exit 0 either way. A hook asks this
        # so that "which families need a shim" has one implementation. A
        # composite already names its shim and gets nothing more.
        shim = shim_for(args.model.split("@", 1)[0], load_shims(root), args.harness)
        if shim:
            print(shim)
        return 0

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
