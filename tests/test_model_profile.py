#!/usr/bin/env python3
"""Behavioural tests for tools/fabric/model_profile.py (bin/fabric-model).

The invariant under test: the command writes only the login's own layer
($STATE_DIR/model-profile.local.json) and the account's agent files, in
each provider's vocabulary, gated like the launcher; the repository is
never touched. Runs against the real routing files with a scratch state
directory and a scratch CLAUDE_CONFIG_DIR.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TOOL = os.path.join(ROOT, "tools", "fabric", "model_profile.py")


class Fixture:
    def __init__(self, tmp: str) -> None:
        self.state = os.path.join(tmp, "state")
        self.claude = os.path.join(tmp, "claude")
        os.makedirs(self.claude)
        self.env = {**os.environ, "AGENT_FABRIC_ROOT": ROOT, "AGENT_FABRIC_STATE_DIR": self.state,
                    "CLAUDE_CONFIG_DIR": self.claude}
        self.env.pop("AGENT_FABRIC_LAUNCH_PROVIDER", None)  # an unlaunched session, whatever the runner is
        self.login = subprocess.run([sys.executable, os.path.join(ROOT, "runtime", "identity.py")],
                                    capture_output=True, text=True, env=self.env).stdout.strip() or os.getlogin()
        self.local = os.path.join(self.state, "agents", self.login, "model-profile.local.json")

    def run(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, TOOL, *args], capture_output=True, text=True, env=self.env)

    def read(self) -> dict:
        return json.load(open(self.local, encoding="utf-8")) if os.path.exists(self.local) else {}

    def reviewer_model(self) -> str | None:
        path = os.path.join(self.claude, "agents", "code-review.md")
        if not os.path.exists(path):
            return None
        for line in open(path, encoding="utf-8"):
            if line.startswith("model: "):
                return line[len("model: "):].strip()
        return None


def test_list_shows_both_providers_with_sources(f: Fixture) -> None:
    p = f.run("list")
    assert p.returncode == 0, p.stderr
    assert "provider openrouter" in p.stdout and "provider anthropic" in p.stdout, p.stdout
    assert "(absent)" in p.stdout, "no local layer yet is said"
    assert "claude-opus-5[1m]" in p.stdout and "via the agent file" in p.stdout, p.stdout
    for word in ("haiku", "sonnet", "opus", "fable"):
        assert f" {word} " not in p.stdout and f"{word}\n" not in p.stdout, f"a tier alias leaked into the listing: {word}"
    j = json.loads(f.run("list", "--json").stdout)
    assert j["providers"]["anthropic"]["code-plan"]["model"] == "claude-fable-5-1"
    assert j["providers"]["openrouter"]["session"]["source"] == "defaults"
    assert not os.path.exists(f.local), "list writes nothing"


def test_set_writes_under_the_provider_and_nothing_else(f: Fixture) -> None:
    p = f.run("set", "--provider", "anthropic", "code-high", "claude-opus-5[1m]")
    assert p.returncode == 0, p.stderr
    assert f.read() == {"providers": {"anthropic": {"capabilities": {"code-high": "claude-opus-5[1m]"}}}}, f.read()
    assert "resolves now to claude-opus-5[1m] (from local)" in p.stdout, p.stdout
    p = f.run("set", "--provider", "openrouter", "code-low", "z-ai/glm-5.2")
    assert p.returncode == 0, p.stderr
    assert f.read()["providers"]["openrouter"] == {"capabilities": {"code-low": "z-ai/glm-5.2"}}
    p = f.run("set", "--provider", "anthropic", "session", "code-plan")
    assert p.returncode == 0 and f.read()["providers"]["anthropic"]["session"] == "code-plan", p.stderr
    j = json.loads(f.run("list", "--json").stdout)
    assert (j["providers"]["anthropic"]["session"]["model"], j["providers"]["anthropic"]["session"]["capability"]) == \
        ("claude-fable-5-1", "code-plan"), "a class-named session is that class's model"
    assert j["providers"]["openrouter"]["session"]["model"] == "deepseek/deepseek-v4-pro-0813@preset/deepseek2claude-shim", "one provider's session is not the other's"
    assert j["providers"]["openrouter"]["code-low"]["model"] == "z-ai/glm-5.2@preset/glm2claude-shim"
    assert f.local.startswith(f.state), "the write is under the state dir"
    assert not os.path.exists(os.path.join(f.state, "routing")), "nothing shaped like the repo appears in state"


def test_unset_removes_and_prunes(f: Fixture) -> None:
    f.run("set", "--provider", "anthropic", "code-high", "claude-opus-5[1m]")
    p = f.run("unset", "--provider", "anthropic", "code-high")
    assert p.returncode == 0, p.stderr
    assert f.read() == {}, f.read()
    assert "claude-opus-5 (from capabilities.providers.anthropic)" in p.stdout, p.stdout


def test_vocabulary_is_the_class_and_the_providers_model(f: Fixture) -> None:
    p = f.run("set", "--provider", "anthropic", "code-high", "z-ai/glm-5.3")
    assert p.returncode == 1 and "not a native Claude id" in p.stderr, p.stderr
    p = f.run("set", "--provider", "anthropic", "code-high", "opus")
    assert p.returncode == 1 and "not a native Claude id" in p.stderr, "a tier alias is not a model"
    p = f.run("set", "--provider", "openrouter", "code-low", "haiku")
    assert p.returncode == 1 and "not an OpenRouter model id" in p.stderr, p.stderr
    p = f.run("set", "--provider", "anthropic", "opus", "claude-opus-5")
    assert p.returncode == 1 and "not a target on anthropic" in p.stderr and "code-plan" in p.stderr, p.stderr
    p = f.run("set", "--provider", "openrouter", "review", "z-ai/glm-5.3")
    assert p.returncode == 1 and "not a target on openrouter" in p.stderr, "the old class name is gone"
    assert not os.path.exists(f.local), "a refused set writes nothing"


def test_review_is_gated_on_both_providers_and_reaches_the_file(f: Fixture) -> None:
    p = f.run("set", "--provider", "openrouter", "code-review", "z-ai/glm-5.3-flash")
    assert p.returncode == 1 and "review-grade.json" in p.stderr, p.stderr
    p = f.run("set", "--provider", "anthropic", "code-review", "claude-haiku-4-5")
    assert p.returncode == 1 and "review-grade.json" in p.stderr, p.stderr
    assert not os.path.exists(f.local)
    p = f.run("set", "--provider", "anthropic", "code-review", "claude-opus-5")
    assert p.returncode == 0, p.stderr
    assert f.reviewer_model() == "claude-opus-5", "an unlaunched session is on anthropic: the pin is installed at once"
    p = f.run("unset", "--provider", "anthropic", "code-review")
    assert p.returncode == 0 and f.reviewer_model() == "claude-opus-5[1m]", "back to the column's pin"
    # Launched on the broker, the file carries that provider's composite.
    f.env["AGENT_FABRIC_LAUNCH_PROVIDER"] = "openrouter"
    p = f.run("set", "--provider", "openrouter", "code-review", "anthropic/claude-opus-5")
    assert p.returncode == 0, p.stderr
    assert f.reviewer_model() == "anthropic/claude-opus-5", f.reviewer_model()
    p = f.run("set", "--provider", "anthropic", "code-review", "claude-opus-5")
    assert p.returncode == 0 and "next launch" in p.stdout and f.reviewer_model() == "anthropic/claude-opus-5", \
        "the other provider's pin does not touch this launch's file"


def test_a_flat_local_file_is_migrated_on_first_write(f: Fixture) -> None:
    os.makedirs(os.path.dirname(f.local))
    json.dump({"session": "anthropic/claude-opus-5", "capabilities": {"code-low": "z-ai/glm-5.2"}}, open(f.local, "w"))
    p = f.run("set", "--provider", "anthropic", "code-high", "claude-opus-5[1m]")
    assert p.returncode == 0, p.stderr
    assert f.read() == {"providers": {
        "openrouter": {"session": "anthropic/claude-opus-5", "capabilities": {"code-low": "z-ai/glm-5.2"}},
        "anthropic": {"session": "claude-opus-5", "capabilities": {"code-high": "claude-opus-5[1m]"}}}}, f.read()
    assert "moved:" in p.stdout, p.stdout


def test_a_malformed_local_file_is_refused_not_rewritten(f: Fixture) -> None:
    os.makedirs(os.path.dirname(f.local))
    open(f.local, "w").write('{"session": null}\n')
    p = f.run("set", "--provider", "anthropic", "code-high", "claude-opus-5")
    assert p.returncode == 1 and "session is None" in p.stderr, p.stderr
    assert open(f.local).read() == '{"session": null}\n', "left for the hand"
    p = f.run("list")
    assert p.returncode == 1 and "session is None" in p.stderr


def test_seed_copies_the_merged_defaults_as_pins(f: Fixture) -> None:
    p = f.run("seed", "--provider", "openrouter")
    assert p.returncode == 0, p.stderr
    got = f.read()["providers"]["openrouter"]
    assert got["session"] == "deepseek/deepseek-v4-pro-0813" and "@preset" not in json.dumps(got), "the shim is derived, never seeded"
    assert got["capabilities"] == {"code-low": "z-ai/glm-5.3-flash", "code-medium": "z-ai/glm-5.2", "code-high": "deepseek/deepseek-v4-pro-0813",
                                   "code-plan": "deepseek/deepseek-v4-pro-0813", "code-review": "deepseek/deepseek-v4-pro-0813"}, got
    assert "anthropic" not in f.read()["providers"], "only the provider asked for"
    p = f.run("seed", "--provider", "anthropic")
    assert p.returncode == 0, p.stderr
    got = f.read()["providers"]["anthropic"]
    assert got == {"session": "claude-opus-5", "capabilities": {
        "code-low": "claude-haiku-4-5-20251001", "code-medium": "claude-sonnet-5", "code-high": "claude-opus-5",
        "code-plan": "claude-fable-5-1", "code-review": "claude-opus-5[1m]"}}, got
    j = json.loads(f.run("list", "--json").stdout)
    assert j["providers"]["openrouter"]["code-low"]["source"] == "local", "a seeded value is now the agent's own"


def main() -> int:
    cases = [
        test_list_shows_both_providers_with_sources,
        test_set_writes_under_the_provider_and_nothing_else,
        test_unset_removes_and_prunes,
        test_vocabulary_is_the_class_and_the_providers_model,
        test_review_is_gated_on_both_providers_and_reaches_the_file,
        test_a_flat_local_file_is_migrated_on_first_write,
        test_a_malformed_local_file_is_refused_not_rewritten,
        test_seed_copies_the_merged_defaults_as_pins,
    ]
    failures = 0
    for case in cases:
        with tempfile.TemporaryDirectory() as tmp:
            try:
                case(Fixture(tmp))
                print(f"  ok   {case.__name__}")
            except AssertionError as exc:
                failures += 1
                print(f"  FAIL {case.__name__}: {exc}")
    print(f"\n{len(cases) - failures}/{len(cases)} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
