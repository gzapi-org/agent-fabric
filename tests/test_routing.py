#!/usr/bin/env python3
"""Behavioural tests for tools/fabric/routing.py.

The invariant under test: capability -> model and model -> shim are two
independent dimensions, and the composite `model@preset/slug` is derived —
never read from a canonical file. Cases run against the real routing files
and against throwaway copies with one model changed.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "tools", "fabric"))
import routing  # noqa: E402

GLM_SHIM = "@preset/glm2claude-shim"


def scratch_root(tmp: str) -> str:
    """A copy of the real routing files and aliases, to be edited freely."""
    root = os.path.join(tmp, "fabric")
    shutil.copytree(os.path.join(ROOT, "routing"), os.path.join(root, "routing"))
    os.makedirs(os.path.join(root, "runtime", "claude-code"))
    shutil.copy2(os.path.join(ROOT, "runtime", "claude-code", "aliases.json"),
                 os.path.join(root, "runtime", "claude-code", "aliases.json"))
    return root


def set_model(root: str, provider: str, klass: str, model: str) -> None:
    path = os.path.join(root, "routing", "capabilities.json")
    d = json.load(open(path, encoding="utf-8"))
    d["providers"][provider]["models"][klass] = model
    json.dump(d, open(path, "w", encoding="utf-8"))


def test_current_glm_policy() -> None:
    expected = {
        "code-low": ("z-ai/glm-5.3-flash", GLM_SHIM, "z-ai/glm-5.3-flash@preset/glm2claude-shim"),
        "code-medium": ("z-ai/glm-5.2", GLM_SHIM, "z-ai/glm-5.2@preset/glm2claude-shim"),
        "code-high": ("z-ai/glm-5.3", GLM_SHIM, "z-ai/glm-5.3@preset/glm2claude-shim"),
        "review": ("z-ai/glm-5.3", GLM_SHIM, "z-ai/glm-5.3@preset/glm2claude-shim"),
    }
    for klass, (model, shim, comp) in expected.items():
        res = routing.resolve(klass, "openrouter")
        assert (res["model"], res["shim"], res["composite"]) == (model, shim, comp), res


def test_native_path_is_aliases_except_the_review_pin() -> None:
    """On plain claude a coding class is a tier alias the harness binds; the
    review class is pinned to a native id (architect-cto, 2026-09-15), so a
    vanilla review is never on a tier the fabric has not named. No shim."""
    got = {k: routing.resolve(k, "anthropic") for k in ("code-low", "code-medium", "code-high", "review")}
    assert {k: v["composite"] for k, v in got.items()} == {
        "code-low": "haiku", "code-medium": "sonnet", "code-high": "opus", "review": "claude-opus-5[1m]"}, got
    assert [k for k, v in got.items() if v["pinned"]] == ["review"], got
    assert all(v["shim"] is None for v in got.values()), "no shim on the native path"
    assert routing.review_grade_ok("claude-opus-5[1m]"), "the native spelling is graded under anthropic/"
    assert not routing.review_grade_ok("claude-haiku-4-5")
    s = routing.resolve_session(provider="anthropic")
    assert (s["model"], s["composite"], s["openrouter_id"], s["source"], s["skipped"]) == \
        ("claude-sonnet-5", "claude-sonnet-5", "anthropic/claude-sonnet-5", "defaults", None), s
    # A broker-only local override (GLM) says nothing about plain claude: the
    # nearest layer naming an Anthropic model wins, and the skip is reported.
    s = routing.resolve_session(local={"session": "z-ai/glm-5.3"}, provider="anthropic")
    assert (s["model"], s["source"], s["skipped"]) == ("claude-sonnet-5", "defaults", "z-ai/glm-5.3"), s
    s = routing.resolve_session(local={"session": "anthropic/claude-opus-5[1m]"}, provider="anthropic")
    assert (s["model"], s["source"]) == ("claude-opus-5[1m]", "local"), s


def test_a_layer_is_per_provider() -> None:
    """One layer names each provider's choices in that provider's
    vocabulary; the merge is per provider, per key, nearest layer wins.
    The flat session/capabilities are the OpenRouter form (and an
    anthropic/ session serves plain claude too), so an old local file
    reads exactly as before."""
    local = {"providers": {"openrouter": {"session": "z-ai/glm-5.3", "capabilities": {"code-low": "z-ai/glm-5.2"}},
                           "anthropic": {"session": "opus", "aliases": {"opus": "claude-opus-5[1m]"},
                                         "capabilities": {"review": "claude-opus-5"}}}}
    s = routing.resolve_session(local=local, provider="openrouter")
    assert (s["model"], s["source"]) == ("z-ai/glm-5.3", "local"), s
    s = routing.resolve_session(local=local, provider="anthropic")
    assert (s["model"], s["source"], s["skipped"], s["openrouter_id"]) == ("opus", "local", None, None), s
    assert routing.resolve("code-low", "openrouter", local=local)["model"] == "z-ai/glm-5.2"
    assert routing.resolve("code-low", "anthropic", local=local)["model"] == "haiku", "the broker override stays on the broker"
    hi = routing.resolve("code-high", "anthropic", local=local)
    assert (hi["model"], hi["pinned"], hi["source"], hi["alias"]) == ("claude-opus-5[1m]", True, "local", "opus"), \
        "a coding class on plain claude is pinned by binding the alias it rides"
    assert routing.resolve("code-high", "openrouter", local=local)["model"] == "z-ai/glm-5.3", "the alias binding stays on plain claude"
    rv = routing.resolve("review", "anthropic", local=local)
    assert (rv["model"], rv["source"]) == ("claude-opus-5", "local"), rv
    exports = routing.alias_exports(local=local)
    assert set(exports) == {"opus"} and exports["opus"]["model"] == "claude-opus-5[1m]", exports
    assert routing.alias_exports() == {}, "nothing bound by default: every tier is the harness's"
    # A flat layer over a per-provider one: the nearest layer wins per key.
    both = {"providers": {"anthropic": {"session": "opus"}}, "session": "anthropic/claude-sonnet-5"}
    assert routing.resolve_session(local=both, provider="anthropic")["model"] == "opus", \
        "providers.anthropic.session outranks what the flat anthropic/ session implies"
    assert routing.resolve_session(local=both, provider="openrouter")["model"] == "anthropic/claude-sonnet-5"


def test_a_layer_is_validated_in_its_provider_vocabulary() -> None:
    def refused(layer, needle):
        try:
            routing.normalize_layer(layer, "local")
        except ValueError as exc:
            assert needle in str(exc), f"{needle!r} not in {exc}"
            return
        raise AssertionError(f"{layer} was accepted")
    refused({"session": None}, "session is None")
    refused({"providers": {"anthropic": {"session": "z-ai/glm-5.3"}}}, "neither a harness tier alias")
    refused({"providers": {"anthropic": {"aliases": {"opus": "opus"}}}}, "not a native Claude id")
    refused({"providers": {"anthropic": {"aliases": {"turbo": "claude-x"}}}}, "not a tier alias")
    refused({"providers": {"anthropic": {"capabilities": {"code-high": "claude-opus-5"}}}}, "bind the alias instead")
    refused({"providers": {"openrouter": {"aliases": {"opus": "claude-opus-5"}}}}, "binds classes, not tier aliases")
    refused({"providers": {"vertex": {}}}, "unknown provider")
    refused({"capabilities": {"code-low": "z-ai/glm-5.3@preset/glm2claude-shim"}}, "not a model id")
    assert routing.normalize_layer({}) == {"openrouter": {"capabilities": {}}, "anthropic": {"aliases": {}, "capabilities": {}}}


def test_composite_is_derived_not_stored() -> None:
    for name in ("capabilities.json", "profiles.json", "shims.json"):
        text = open(os.path.join(ROOT, "routing", name), encoding="utf-8").read()
        assert "@preset/glm2claude-shim" not in text or name == "shims.json", \
            f"{name} carries a composite; the shim belongs only in shims.json"
    text = open(os.path.join(ROOT, "routing", "capabilities.json"), encoding="utf-8").read()
    assert "glm-5.3@" not in text


def test_a_non_glm_model_gets_no_shim(tmp: str) -> None:
    root = scratch_root(tmp)
    set_model(root, "openrouter", "code-high", "anthropic/claude-sonnet-5")
    res = routing.resolve("code-high", "openrouter", root=root)
    assert res["shim"] is None and res["composite"] == "anthropic/claude-sonnet-5", res
    set_model(root, "openrouter", "code-low", "meta-llama/llama-4-maverick")
    res = routing.resolve("code-low", "openrouter", root=root)
    assert res["shim"] is None and res["composite"] == "meta-llama/llama-4-maverick", res
    # The untouched class still gets its family shim: the two dimensions are independent.
    res = routing.resolve("code-medium", "openrouter", root=root)
    assert res["composite"] == "z-ai/glm-5.2@preset/glm2claude-shim", res
    # And the real files are untouched.
    assert routing.resolve("code-high", "openrouter")["composite"] == "z-ai/glm-5.3@preset/glm2claude-shim"


def test_shim_follows_the_family_of_the_merged_model(tmp: str) -> None:
    root = scratch_root(tmp)
    local = {"capabilities": {"code-low": "z-ai/glm-5.2", "code-high": "openai/gpt-5"}}
    assert routing.resolve("code-low", "openrouter", local=local, root=root)["composite"] == "z-ai/glm-5.2@preset/glm2claude-shim"
    assert routing.resolve("code-high", "openrouter", local=local, root=root)["composite"] == "openai/gpt-5"


def test_shim_subcommand_answers_for_a_bare_id_and_stays_quiet_otherwise(tmp: str) -> None:
    """A hook asks `routing.py shim <model>` rather than matching families
    itself: a bare id of a shimmed family prints the shim; a composite,
    a foreign family and a bare preset print nothing; every case exits 0."""
    cli = os.path.join(ROOT, "tools", "fabric", "routing.py")

    def ask(model: str) -> str:
        out = subprocess.run([sys.executable, cli, "shim", model], capture_output=True, text=True, check=True)
        return out.stdout.strip()

    assert ask("z-ai/glm-5.3") == GLM_SHIM
    assert ask("z-ai/glm-5.3" + GLM_SHIM) == GLM_SHIM      # composite: same family, same answer
    assert ask("anthropic/claude-opus-5") == ""
    assert ask("@preset/reviewer") == ""
    assert ask("not-a-model") == ""


def test_a_bare_preset_gets_nothing_attached() -> None:
    assert routing.shim_for("@preset/reviewer", routing.load_shims()) is None
    assert routing.composite("@preset/reviewer", None) == "@preset/reviewer"


def test_only_live_tested_families_have_a_shim() -> None:
    shims = routing.load_shims()
    assert [s["family"] for s in shims] == ["z-ai/glm-*", "deepseek/deepseek-v4*"], "no speculative families"
    for s in shims:
        assert s["tested"].startswith("2026-"), f"{s['family']}: a shim is added only with a live check"
    assert routing.shim_for("deepseek/deepseek-v4-pro-0813", shims) == "@preset/deepseek2claude-shim"
    assert routing.shim_for("deepseek/deepseek-v3", shims) is None, "v3 was never checked"


def test_review_grade_gate_is_on_review_only(tmp: str) -> None:
    assert routing.review_grade_ok("anthropic/claude-opus-5")
    assert routing.review_grade_ok("anthropic/claude-opus-5[1m]")
    assert routing.review_grade_ok("z-ai/glm-5.3"), "admitted by architect-cto 2026-09-13"
    assert not routing.review_grade_ok("z-ai/glm-5.3-flash")
    assert not routing.review_grade_ok("z-ai/glm-5.2")
    root = scratch_root(tmp)
    set_model(root, "openrouter", "review", "z-ai/glm-5.3-flash")
    findings = routing.check(root)
    assert any("review" in f and "review-grade" in f for f in findings), findings
    root2 = scratch_root(tmp + "/b") if os.path.isdir(tmp + "/b") else scratch_root(os.path.join(tmp, "b"))
    set_model(root2, "openrouter", "code-high", "z-ai/glm-5.3-flash")
    assert routing.check(root2) == [], "a coding class is not review-gated"


def test_check_refuses_a_preset_as_a_model(tmp: str) -> None:
    root = scratch_root(tmp)
    set_model(root, "openrouter", "code-low", "@preset/glm2claude-shim")
    findings = routing.check(root)
    assert any("preset" in f for f in findings), findings


def test_every_class_rides_its_own_alias(tmp: str) -> None:
    """The Agent tool accepts only tier aliases, so nothing may be `declared`
    by full id, the review class must ride an alias of its own (fable), and
    the harness provider must say the same."""
    aliases = json.load(open(os.path.join(ROOT, "runtime", "claude-code", "aliases.json")))
    assert "declared" not in aliases
    assert aliases["aliases"]["review"] == "fable"
    assert aliases["aliases"]["code-high"] == "opus", "review and code-high must not share an export"
    root = scratch_root(tmp)
    path = os.path.join(root, "runtime", "claude-code", "aliases.json")
    d = json.load(open(path))
    d["declared"] = {"review": d["aliases"].pop("review")}
    json.dump(d, open(path, "w"))
    findings = routing.check(root)
    assert any("declared" in f and "retired" in f for f in findings), findings
    # The harness column may pin a native id — graded like any review model —
    # but never a foreign vendor's id or a composite.
    root2 = scratch_root(os.path.join(tmp, "b"))
    set_model(root2, "anthropic", "review", "claude-haiku-4-5")
    findings = routing.check(root2)
    assert any("review" in f and "review-grade" in f for f in findings), findings
    root3 = scratch_root(os.path.join(tmp, "c"))
    set_model(root3, "anthropic", "review", "z-ai/glm-5.3")
    findings = routing.check(root3)
    assert any("neither a harness tier alias nor a native Claude id" in f for f in findings), findings


def test_real_files_are_clean() -> None:
    assert routing.check() == []
    proc = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "fabric", "routing.py"), "check"],
                          capture_output=True, text=True)
    assert proc.returncode == 0, proc.stdout + proc.stderr


def main() -> int:
    cases = [
        test_current_glm_policy,
        test_native_path_is_aliases_except_the_review_pin,
        test_composite_is_derived_not_stored,
        test_a_non_glm_model_gets_no_shim,
        test_shim_follows_the_family_of_the_merged_model,
        test_a_bare_preset_gets_nothing_attached,
        test_shim_subcommand_answers_for_a_bare_id_and_stays_quiet_otherwise,
        test_only_live_tested_families_have_a_shim,
        test_a_layer_is_per_provider,
        test_a_layer_is_validated_in_its_provider_vocabulary,
        test_review_grade_gate_is_on_review_only,
        test_check_refuses_a_preset_as_a_model,
        test_every_class_rides_its_own_alias,
        test_real_files_are_clean,
    ]
    failures = 0
    for case in cases:
        with tempfile.TemporaryDirectory() as tmp:
            try:
                case(tmp) if case.__code__.co_argcount else case()
                print(f"  ok   {case.__name__}")
            except AssertionError as exc:
                failures += 1
                print(f"  FAIL {case.__name__}: {exc}")
    print(f"\n{len(cases) - failures}/{len(cases)} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
