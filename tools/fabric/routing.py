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

    routing.py pins [--provider P] [--me]             # the file-pinned classes (the review class): <class> <alias> <model>

Profile layers (routing/profiles.json and the agent's local override) may
override a class's model and name the session's; the shim is looked up on
the MERGED model, so an override to another family gets that family's
shim, or none.

A LAYER IS PER PROVIDER. The two launch paths speak different vocabularies
(an OpenRouter id on the broker; a tier alias or a native `claude-…` id on
plain claude), so a layer names each provider's choices under
`providers.<provider>.{session, capabilities}`. The flat `session` and
`capabilities` a layer may also carry are the OpenRouter form — and a flat
`session` of `anthropic/<id>` serves plain claude too, as `<id>`. The
merge is per provider, per key, nearest layer wins:
defaults <- roles.<role> <- agents.<login> <- the agent's local override
($STATE_DIR/model-profile.local.json, written by bin/fabric-model).
"""
from __future__ import annotations

import argparse
import fnmatch
import importlib.util
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
    return _load(path) if os.path.exists(path) else {"capability": "code-review", "models": []}


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


PROVIDERS = ("openrouter", "anthropic")
LAYERS = ("defaults", "role", "agent", "local")
LOCAL_OVERRIDE = "model-profile.local.json"


def load_aliases(root: str | None = None) -> dict[str, Any]:
    return _load(os.path.join(root or FABRIC_ROOT, "runtime", "claude-code", "aliases.json"))


def file_pinned(root: str | None = None) -> list[str]:
    """Classes whose model reaches their agent file instead of a tier
    export (runtime/claude-code/aliases.json `file_pinned`): the review
    class, so that it never follows the class sharing its alias."""
    return list(load_aliases(root).get("file_pinned") or [])


def _model_id(value: Any, where: str) -> str:
    if not isinstance(value, str) or not MODEL_ID.fullmatch(value):
        raise ValueError(f"{where} is {value!r}, not a model id ({MODEL_ID.pattern})")
    return value


def _native_id(value: Any, where: str) -> str:
    if not isinstance(value, str) or not NATIVE_ID.fullmatch(value):
        raise ValueError(f"{where} is {value!r}, not a native Claude id (claude-…)")
    return value


def _object(value: Any, where: str) -> dict[str, Any]:
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise ValueError(f"{where} is {value!r}, not an object")
    return value


def normalize_layer(layer: Any, where: str = "", root: str | None = None) -> dict[str, dict[str, Any]]:
    """One layer, as one object per provider, every value validated in that
    provider's vocabulary; a malformed value is a ValueError naming the
    field (the committed file is schema-checked, the local override is
    not, and a null there once reached `--model` as the string "None").

      openrouter: {session: <model id | class>, capabilities: {<class>: <model id>}}
      anthropic:  {session: <native id | class>, capabilities: {<class>: <native id>}}

    The vocabulary is the capability class and the provider's own model
    id; a harness tier alias is never named here — which alias a class
    rides is the Claude Code adapter's (runtime/claude-code/aliases.json).
    A session may name a class, meaning that class's model on the
    provider. The flat `session` and `capabilities` are the OpenRouter
    form; a flat `session` of `anthropic/<id>` also names `<id>` for
    plain claude unless `providers.anthropic.session` says otherwise."""
    prefix = where + "." if where else ""
    layer = _object(layer, where or "the profile layer")
    classes = set(load_capabilities(root)["classes"])

    def session(provider: str, value: Any, field: str) -> str:
        if isinstance(value, str) and value in classes:
            return value
        return (_model_id if provider == "openrouter" else _native_id)(value, field) if provider == "openrouter" \
            else _native_or_class(value, field)

    def _native_or_class(value: Any, field: str) -> str:
        if not isinstance(value, str) or not NATIVE_ID.fullmatch(value):
            raise ValueError(f"{field} is {value!r}, neither a capability class ({', '.join(sorted(classes))}) "
                             "nor a native Claude id (claude-…)")
        return value

    def klass(name: str, field: str) -> str:
        if name not in classes:
            raise ValueError(f"{field}: {name!r} is not a capability class ({', '.join(sorted(classes))})")
        return name

    out: dict[str, dict[str, Any]] = {p: {"capabilities": {}} for p in PROVIDERS}
    if "session" in layer:
        value = session("openrouter", layer["session"], prefix + "session")
        out["openrouter"]["session"] = value
        if value.startswith("anthropic/"):
            out["anthropic"]["session"] = value[len("anthropic/"):]
        elif value in classes:
            out["anthropic"]["session"] = value
    for name, model in _object(layer.get("capabilities"), prefix + "capabilities").items():
        out["openrouter"]["capabilities"][klass(name, prefix + "capabilities")] = _model_id(model, f"{prefix}capabilities.{name}")
    for provider, body in _object(layer.get("providers"), prefix + "providers").items():
        p = f"{prefix}providers.{provider}"
        if provider not in PROVIDERS:
            raise ValueError(f"{p}: unknown provider; known: {', '.join(PROVIDERS)}")
        body = _object(body, p)
        for key in body:
            if key not in ("session", "capabilities"):
                raise ValueError(f"{p}.{key}: not a field of a provider layer (session, capabilities); "
                                 "a class is set under capabilities, a tier alias is never named")
        if "session" in body:
            out[provider]["session"] = session(provider, body["session"], p + ".session")
        check = _model_id if provider == "openrouter" else _native_id
        for name, model in _object(body.get("capabilities"), p + ".capabilities").items():
            out[provider]["capabilities"][klass(name, p + ".capabilities")] = check(model, f"{p}.capabilities.{name}")
    return out


def layers(role: str | None, agent: str | None, local: dict[str, Any] | None = None,
           root: str | None = None) -> list[tuple[str, dict[str, Any]]]:
    """The four layers, bottom first, raw."""
    profiles = load_profiles(root)
    return [("defaults", profiles.get("defaults") or {}),
            ("role", ((profiles.get("roles") or {}).get(role) or {}) if role else {}),
            ("agent", ((profiles.get("agents") or {}).get(agent) or {}) if agent else {}),
            ("local", local or {})]


def merged_provider(provider: str, role: str | None = None, agent: str | None = None,
                    local: dict[str, Any] | None = None, root: str | None = None) -> dict[str, Any]:
    """One provider's merged choices with their provenance, each value as
    {"model", "source"}: {"session": … | None, "capabilities": {class: …}}.
    Per key, the nearest layer naming it wins. A malformed layer raises
    ValueError (normalize_layer)."""
    if provider not in PROVIDERS:
        raise KeyError(f"unknown provider {provider!r}; known: {list(PROVIDERS)}")
    out: dict[str, Any] = {"session": None, "capabilities": {}}
    for name, body in layers(role, agent, local, root):
        norm = normalize_layer(body, name, root)[provider]
        if "session" in norm:
            out["session"] = {"model": norm["session"], "source": name}
        for klass, model in norm["capabilities"].items():
            out["capabilities"][klass] = {"model": model, "source": name}
    return out


def local_override_path(agent: str | None = None) -> str:
    """$STATE_DIR/model-profile.local.json for the agent — the login's own
    layer, gitignored, written by bin/fabric-model. Identity comes from
    runtime/identity.py, the one resolver."""
    spec = importlib.util.spec_from_file_location(
        "fabric_identity", os.path.join(FABRIC_ROOT, "runtime", "identity.py"))
    identity = importlib.util.module_from_spec(spec); spec.loader.exec_module(identity)
    return os.path.join(identity.agent_state_dir(agent), LOCAL_OVERRIDE)


def load_local(agent: str | None = None, path: str | None = None) -> dict[str, Any]:
    """The agent's local layer, {} when absent. Validated where it is
    merged (normalize_layer names the field), not here."""
    path = path or local_override_path(agent)
    if not os.path.exists(path):
        return {}
    local = _load(path)
    if not isinstance(local, dict):
        raise ValueError(f"{path} is {type(local).__name__}, not an object")
    return local


def resolve(capability: str, provider: str = "openrouter", role: str | None = None,
            agent: str | None = None, local: dict[str, Any] | None = None,
            root: str | None = None, harness: str = "claude-code") -> dict[str, Any]:
    """One class on one provider: {model, shim, composite, source, alias,
    pinned, via}. `alias` is the tier the class rides (the adapter's);
    `via` says how the model reaches the class — "export" (the alias's
    ANTHROPIC_DEFAULT_*_MODEL), "file" (its agent file), or "harness"
    (nothing pinned: the harness's own model of that tier)."""
    caps = load_capabilities(root)
    if capability not in caps["classes"]:
        raise KeyError(f"unknown capability class {capability!r}; known: {sorted(caps['classes'])}")
    prov = caps["providers"].get(provider)
    if prov is None:
        raise KeyError(f"unknown provider {provider!r}; known: {sorted(caps['providers'])}")
    model = prov["models"].get(capability)
    source = f"capabilities.providers.{provider}"
    override = merged_provider(provider, role, agent, local, root)["capabilities"].get(capability)
    if override:
        model, source = override["model"], override["source"]
    alias = (load_aliases(root).get("aliases") or {}).get(capability)
    in_file = capability in file_pinned(root)
    if prov["resolution"] == "harness":
        if not model:
            # Nothing pinned: the harness's own model of the tier — spelled
            # as the alias, which is what plain claude takes.
            if not alias:
                raise KeyError(f"provider {provider!r} pins no model to {capability!r} and it rides no alias")
            return {"capability": capability, "provider": provider, "model": alias, "shim": None,
                    "composite": alias, "resolution": "harness", "source": "harness",
                    "alias": alias, "pinned": False, "via": "harness"}
        return {"capability": capability, "provider": provider, "model": model, "shim": None,
                "composite": model, "resolution": "harness", "source": source,
                "alias": alias, "pinned": True, "via": "file" if in_file else "export"}
    if not model:
        raise KeyError(f"provider {provider!r} binds no model to {capability!r}")
    shim = shim_for(model, load_shims(root), harness)
    return {"capability": capability, "provider": provider, "model": model, "shim": shim,
            "composite": composite(model, shim), "resolution": "model-id", "source": source,
            "alias": alias, "pinned": True, "via": "file" if in_file else "export"}


def exports(provider: str = "openrouter", role: str | None = None, agent: str | None = None,
            local: dict[str, Any] | None = None, root: str | None = None) -> dict[str, dict[str, Any]]:
    """What the launcher exports, {ALIAS_ENV_VAR: {"model", "class", "source"}}:
    every class whose model reaches it through its alias's export — on the
    broker every non-file class; on plain claude the pinned ones. Two
    classes riding one alias cannot both export: only a file-pinned class
    may share (check() enforces it), so this raises if it ever happens."""
    aliases = load_aliases(root)
    out: dict[str, dict[str, Any]] = {}
    for klass, alias in (aliases.get("aliases") or {}).items():
        res = resolve(klass, provider, role, agent, local, root)
        if res["via"] != "export":
            continue
        var = aliases["env"][alias]
        if var in out and out[var]["model"] != res["composite"]:
            raise KeyError(f"{klass} and {out[var]['class']} both ride {alias} and would export different models")
        out[var] = {"model": res["composite"], "class": klass, "source": res["source"], "alias": alias}
    return out


def resolve_session(role: str | None = None, agent: str | None = None,
                    local: dict[str, Any] | None = None, root: str | None = None,
                    harness: str = "claude-code", provider: str = "openrouter") -> dict[str, Any]:
    """The main agent's model, with its family shim on the broker path.
    Separate from capability resolution: the session is not a class, but
    a layer may name one, meaning that class's model on the provider.
    Each provider's session comes from the nearest layer naming one for
    it — on plain claude that is `providers.anthropic.session` or a flat
    `session` of `anthropic/<id>` (or a class); a broker-only layer (GLM)
    says nothing about plain claude and is skipped, and the skip is
    reported. A model of another vendor cannot run there, so none at all
    is refused rather than mistranslated."""
    merged = merged_provider(provider, role, agent, local, root)
    entry = merged["session"]
    broker = merged_provider("openrouter", role, agent, local, root)["session"] if provider == "anthropic" else None
    if not entry:
        if broker:
            raise KeyError(f"session model {broker['model']!r} is not an Anthropic model and no profile layer "
                           "names one; plain claude cannot run it (set providers.anthropic.session: a class "
                           "or a native id)")
        raise KeyError("no session model: routing/profiles.json defaults must carry one for every provider")
    model, klass = entry["model"], None
    if model in load_capabilities(root)["classes"]:
        model, klass = resolve(model, provider, role, agent, local, root)["composite"], model
    if provider == "anthropic":
        skipped = broker["model"] if broker and LAYERS.index(broker["source"]) > LAYERS.index(entry["source"]) else None
        return {"model": model, "shim": None, "composite": model, "capability": klass,
                "openrouter_id": "anthropic/" + model if NATIVE_ID.match(model) else None,
                "source": entry["source"], "skipped": skipped}
    if klass:
        return {"model": model.split("@", 1)[0], "shim": shim_for(model.split("@", 1)[0], load_shims(root), harness),
                "composite": model, "capability": klass, "source": entry["source"]}
    shim = shim_for(model, load_shims(root), harness)
    return {"model": model, "shim": shim, "composite": composite(model, shim), "capability": None,
            "source": entry["source"]}


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
            if prov.get("resolution") == "harness" and model is not None and not NATIVE_ID.match(model):
                findings.append(f"capabilities.json: providers.{name}.{klass} {model!r} is neither null (the harness's "
                                "tier) nor a native Claude id; a tier alias is the adapter's, never named here")
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
        pinned = set(doc.get("file_pinned") or [])
        for klass in pinned:
            if klass not in classes:
                findings.append(f"runtime/claude-code/aliases.json: file_pinned names unknown class {klass!r}")
        for alias in set(aliases.values()):
            exporters = [k for k, a in aliases.items() if a == alias and k not in pinned]
            if len(exporters) > 1:
                findings.append(f"runtime/claude-code/aliases.json: {' and '.join(exporters)} share the {alias} alias "
                                "and both export; one alias carries one export — the class that must not follow "
                                "the other goes through its agent file (file_pinned)")
        for klass, alias in aliases.items():
            if alias not in (doc.get("env") or {}):
                findings.append(f"runtime/claude-code/aliases.json: alias {alias!r} has no export variable")
        if grade.get("capability") in classes and grade.get("capability") not in pinned:
            findings.append(f"runtime/claude-code/aliases.json: the gated class {grade.get('capability')!r} is not "
                            "file_pinned; through an export it would follow whatever shares its alias")
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
    s = sub.add_parser("pins", help="the file-pinned classes' models on a provider (the review class): `<class> <alias> <model>`")
    s.add_argument("--provider", default="anthropic")
    s.add_argument("--role", default=None)
    s.add_argument("--agent", default=None)
    s.add_argument("--local", default=None, help="a model-profile.local.json to merge as the local layer")
    s.add_argument("--me", action="store_true",
                   help="this login's role binding and local override (runtime/identity.py)")
    s = sub.add_parser("shim", help="the family shim a model id needs, or nothing")
    s.add_argument("model")
    s.add_argument("--harness", default="claude-code")
    args = ap.parse_args(argv)
    root = os.path.abspath(args.fabric) if args.fabric else None

    if args.cmd == "pins":
        # For the dispatch guard and the agent-file installer: the classes
        # whose model goes through their agent file (file_pinned — the
        # review class, which must never follow the class sharing its
        # alias), resolved on the given provider, with the alias each
        # rides. Nothing when the merged model is the harness's; exit 0
        # either way. Every other class is an alias export (`exports`).
        role, agent, local = args.role, args.agent, None
        if args.me:
            spec = importlib.util.spec_from_file_location(
                "fabric_identity", os.path.join(root or FABRIC_ROOT, "runtime", "identity.py"))
            identity = importlib.util.module_from_spec(spec); spec.loader.exec_module(identity)
            agent = agent or identity.current_agent()
            role = role or identity.read_binding(agent).get("role")
        if args.local or args.me:
            local = load_local(agent, args.local)
        for klass in file_pinned(root):
            res = resolve(klass, args.provider, role, agent, local, root=root)
            if res["via"] == "file":
                print(f"{klass} {res.get('alias') or ''} {res['composite']}")
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
    s = resolve_session(args.role, args.agent, root=root, provider=args.provider)
    print(f"{'session':12} -> {s['model']:32} shim: {s['shim'] or '-':28} => {s['composite']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
