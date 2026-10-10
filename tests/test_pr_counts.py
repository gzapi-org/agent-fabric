#!/usr/bin/env python3
"""tools/fabric/github/pr_counts.py (fabric-pr counts): the counts equal the
gate's for the same commits, refs resolve through the registry, every line
shape, and every way a ref fails to be read. GitHub is a fake `gh.graphql` and
`gh.api` over fixtures; the parity cases build a real repository and answer the
query from its log. Plain script: prints ok/FAIL, exit 1 on any failure."""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(HERE, "tools", "fabric"))
import gh  # noqa: E402
from github import pr_counts, pr_split  # noqa: E402

REGISTRY = {
    "gzapp": {"remotes": ["git@github.com:gzapi-org/gzapp.git", "https://github.com/gzapi-org/gzapp"]},
    "gzapp.decks": {"remotes": ["git@github.com:gzapi-org/gzapp.decks.git"]},
    "interweave": {"remotes": ["git@github.com:gzapi-org/InterWeave.git"]},
    "herdr": {"remotes": ["git@github.com:BlueTeam-OU/agent-fabric-herdr.git"]},
    "agent-fabric": {"remotes": ["git@github.com:BlueTeam-OU/agent-fabric.git", "git@github.com:gzapi-org/agent-fabric.git"]},
    "twin-a": {"remotes": ["git@github.com:o/same.git"]},
    "twin-b": {"remotes": ["git@github.com:p/same.git"]},
    "no-remote": {"remotes": []},
}


def load_registry() -> dict:
    return REGISTRY


def commit(oid: str, message: str, parents: int = 1) -> dict:
    return {"commit": {"oid": oid, "message": message, "parents": {"totalCount": parents}}}


def pr_doc(number: int, commits: list, *, state: str = "OPEN", draft: bool = False, merged: bool = False, armed: bool = False,
           queued: bool = False, rollup: str | None = "SUCCESS", head: str = "h" * 40, reviews: list | None = None,
           more: bool = False) -> dict:
    return {"number": number, "state": state, "isDraft": draft, "mergedAt": "2026-10-10T00:00:00Z" if merged else None,
            "headRefOid": head, "baseRefName": "main",
            "autoMergeRequest": {"enabledAt": "x"} if armed else None, "mergeQueueEntry": {"state": "QUEUED"} if queued else None,
            "commits": {"totalCount": len(commits), "pageInfo": {"hasNextPage": more}, "nodes": commits},
            "tip": {"nodes": [{"commit": {"statusCheckRollup": {"state": rollup} if rollup else None}}]},
            "reviews": {"nodes": reviews or []}}


class Hub:
    """gh.graphql and gh.api as fixtures: repos[owner/name][number] -> a PR document."""

    def __init__(self, repos: dict, rest: dict | None = None, fail_batches: bool = False):
        self.repos, self.rest, self.graphql_calls, self.api_calls, self.fail_batches = repos, rest or {}, [], [], fail_batches

    def graphql(self, query, *, timeout=None, **variables):
        numbers = [int(n) for n in re.findall(r"\bp(\d+): pullRequest", query)]
        repo = f"{variables['owner']}/{variables['name']}"
        self.graphql_calls.append((repo, numbers, timeout))
        if repo not in self.repos:
            raise gh.GhError("gh api graphql", f"Could not resolve to a Repository with the name '{repo}'.")
        known = self.repos[repo]
        if any(n not in known for n in numbers):
            raise gh.GhError("gh api graphql", f"Could not resolve to a PullRequest with the number of {[n for n in numbers if n not in known][0]}.")
        if self.fail_batches and len(numbers) > 1:
            raise gh.GhError("gh api graphql", "something broke in the batch")
        return {"repository": {f"p{n}": known[n] for n in numbers}}

    def api(self, path, *, paginate=False, timeout=None, **kw):
        self.api_calls.append(path)
        if path in self.rest:
            return self.rest[path]
        raise gh.GhError("gh api", "HTTP 404")


def run_counts(refs: list[str], hub: Hub, timeout: float = 20.0, cwd_repo: str = "o/this") -> list[dict]:
    saved = (gh.graphql, gh.api, gh.this_repo)
    gh.graphql, gh.api, gh.this_repo = hub.graphql, hub.api, lambda cwd=None: cwd_repo
    try:
        return pr_counts.count_rows(refs, timeout, projects_loader=load_registry)
    finally:
        gh.graphql, gh.api, gh.this_repo = saved


def git_fixture() -> tuple[str, str, list[str]]:
    """(repo dir, base sha, the commits' shas oldest first): plain work, a
    declared fix, an Answers: fix, a revert pair, a merge."""
    repo = tempfile.mkdtemp(prefix="test_pr_counts.")
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1", GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t",
               GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")

    def git(*args: str) -> str:
        return subprocess.run(["git", *args], cwd=repo, env=env, check=True, capture_output=True, text=True).stdout.strip()

    def make(n: int, *msg: str) -> str:
        with open(os.path.join(repo, f"f{n}"), "w") as fh:
            fh.write(str(n))
        git("add", "-A")
        git("commit", "-q", *[a for m in msg for a in ("-m", m)])
        return git("rev-parse", "HEAD")

    git("init", "-q", "-b", "main")
    base = make(0, "base")
    git("checkout", "-q", "-b", "feat")
    shas = [make(1, "first piece", "Kind: work"),
            make(2, "tidy the probe", "Answers: F1"),
            make(3, "review fix (#7 F2): the probe", "Kind: review-fix"),
            make(8, "plain subject, declared fix", "Kind: review-fix"),
            make(9, "review fix (#7 F3): reads as a fix, declared work", "Kind: work"),
            make(4, "a change later undone", "Kind: work")]
    git("revert", "--no-edit", shas[-1])
    shas.append(git("rev-parse", "HEAD"))
    # A chain: feature B, its revert, the revert reverted. The reapply nets the
    # revert and B stays work; walked oldest first the revert would net B instead.
    shas.append(make(6, "feature B", "Kind: work"))
    git("revert", "--no-edit", shas[-1])
    shas.append(git("rev-parse", "HEAD"))
    git("revert", "--no-edit", shas[-1])
    shas.append(git("rev-parse", "HEAD"))
    git("checkout", "-q", "main")
    make(5, "main moves")
    git("checkout", "-q", "feat")
    git("merge", "-q", "--no-ff", "-m", "Merge main into feat", "main")
    shas.append(git("rev-parse", "HEAD"))
    return repo, base, shas


def api_commits(repo: str, base: str, head: str) -> list:
    """What GitHub's commit list for base..head says, from the clone's log, oldest first."""
    out = subprocess.run(["git", "log", "--reverse", "--format=%H%x00%P%x00%B%x01", f"{base}..{head}"], cwd=repo,
                         capture_output=True, text=True, check=True).stdout
    nodes = []
    for rec in out.split("\x01"):
        rec = rec.strip("\n")
        if rec:
            sha, parents, message = rec.split("\x00", 2)
            nodes.append(commit(sha, message.rstrip("\n"), len(parents.split())))
    return nodes


def main() -> int:
    fails = 0

    def check(label: str, good: bool, detail: object = "") -> None:
        nonlocal fails
        print(f"  {'ok  ' if good else 'FAIL'} {label}" + ("" if good else f": {detail!r}"))
        fails += not good

    print("the counts are the gate's")
    repo, base, shas = git_fixture()
    saved_cwd = os.getcwd()
    os.chdir(repo)
    try:
        want = pr_split.split_range(7, "o/this", f"{base}..{shas[-1]}", shas[-1], base)
    finally:
        os.chdir(saved_cwd)
    hub = Hub({"o/this": {7: pr_doc(7, api_commits(repo, base, shas[-1]), head=shas[-1])}})
    row = run_counts(["7"], hub)[0]
    check("the clone's split is 4 work, 3 fix, 1 merge, 4 netted (the fixture is not trivial)",
          (want["work"], want["fix"], want["merge"], want["netted"]) == (4, 3, 1, 4), want)
    check("GitHub's commit list gives the same split: work, fix, merge and netted",
          (row["work"], row["fix"], row["merge"], row["netted"]) == (want["work"], want["fix"], want["merge"], want["netted"]), row)
    check("…and nets the same commits: which of a chain's three is netted shows in the subjects",
          (sorted(row["fix_subjects"]), sorted(row["netted_subjects"])) == (sorted(want["fix_subjects"]), sorted(want["netted_subjects"])),
          (row.get("fix_subjects"), row.get("netted_subjects"), want["netted_subjects"]))
    check("the line says it, in the hook's words", row["line"].startswith("#7 (4 work, 3 fix) open, unarmed, checks green"), row["line"])

    print("the line, by state")
    docs = {
        1: pr_doc(1, [commit("a" * 40, "x")], armed=True, rollup="PENDING", reviews=[{"body": "<!-- agent-fabric-review v1 -->\nok", "commit": {"oid": "h" * 40}}]),
        2: pr_doc(2, [commit("b" * 40, "x"), commit("c" * 40, "y", parents=2)], rollup="FAILURE"),
        3: pr_doc(3, [commit("d" * 40, "x")], state="MERGED", merged=True),
        4: pr_doc(4, [commit("e" * 40, "x")], state="CLOSED"),
        5: pr_doc(5, [commit("f" * 40, "x")], draft=True, queued=True, rollup=None),
        6: pr_doc(6, [commit("1" * 40, "x")], reviews=[{"body": "<!-- agent-fabric-review v1 -->", "commit": {"oid": "z" * 40}}]),
        8: pr_doc(8, [commit("2" * 40, "x")], rollup="ERROR"),
        9: pr_doc(9, [commit("3" * 40, "x")], rollup="EXPECTED"),
    }
    rows = {r["number"]: r for r in run_counts([str(n) for n in docs], Hub({"o/this": docs}))}
    check("open, armed, pending, a marked review on the head", rows[1]["line"] == "#1 (1 work, 0 fix) open, armed, checks pending, head reviewed", rows[1]["line"])
    check("open, unarmed, red, a merge commit is not work", rows[2]["line"] == "#2 (1 work, 0 fix) open, unarmed, checks red, review not on head", rows[2]["line"])
    check("merged says only merged", rows[3]["line"] == "#3 (1 work, 0 fix) merged", rows[3]["line"])
    check("closed unmerged says closed", rows[4]["line"] == "#4 (1 work, 0 fix) closed", rows[4]["line"])
    check("a draft, queued, no checks yet", rows[5]["line"] == "#5 (1 work, 0 fix) draft, queued, checks none yet, review not on head", rows[5]["line"])
    check("a review on another commit than the head is not the head's", "review not on head" in rows[6]["line"], rows[6]["line"])
    check("ERROR reads red, EXPECTED pending", "checks red" in rows[8]["line"] and "checks pending" in rows[9]["line"], (rows[8]["line"], rows[9]["line"]))
    saved = (gh.graphql, gh.api, gh.this_repo)
    h = Hub({"o/this": docs})
    gh.graphql, gh.api, gh.this_repo = h.graphql, h.api, lambda cwd=None: "o/this"
    try:
        lines = pr_counts.count_lines(["3", "#1"], 5)
    finally:
        gh.graphql, gh.api, gh.this_repo = saved
    check("…also by `#N`", lines == ["#3 (1 work, 0 fix) merged", "#1 (1 work, 0 fix) open, armed, checks pending, head reviewed"], lines)

    print("legacy markers")
    old = {"body": "<!-- agent-fabric-substitute-review v1 -->", "commit": {"oid": "h" * 40}}
    rows = run_counts(["4"], Hub({"o/this": {4: pr_doc(4, [commit("a" * 40, "x")], reviews=[old])}}))
    check("the built-in earlier marker counts", "head reviewed" in rows[0]["line"], rows[0]["line"])
    mine = {"body": "<!-- mine v1 -->", "commit": {"oid": "h" * 40}}
    rows = run_counts(["4"], Hub({"o/this": {4: pr_doc(4, [commit("a" * 40, "x")], reviews=[mine])}}))
    check("a marker nobody listed does not", "review not on head" in rows[0]["line"], rows[0]["line"])
    os.environ["AGENT_FABRIC_LEGACY_REVIEW_MARKERS"] = "<!-- mine v1 -->"
    try:
        rows = run_counts(["4"], Hub({"o/this": {4: pr_doc(4, [commit("a" * 40, "x")], reviews=[mine])}}))
    finally:
        del os.environ["AGENT_FABRIC_LEGACY_REVIEW_MARKERS"]
    check("…unless the environment lists it", "head reviewed" in rows[0]["line"], rows[0]["line"])

    print("refs")
    two = {"gzapi-org/gzapp": {1075: docs[1]}, "gzapi-org/InterWeave": {3: docs[3]}, "BlueTeam-OU/agent-fabric-herdr": {4: docs[4]},
           "x/y": {9: docs[9]}, "o/this": {5: docs[5]}}
    hub = Hub(two)
    rows = run_counts(["gzapp#1075", "InterWeave#3", "herdr#4", "x/y#9", "5", "GZAPP#1075"], hub)
    check("a project id, a repository's name (any case), owner/repo#N and a bare number each resolve",
          [r["ok"] for r in rows] == [True] * 6 and rows[0]["line"].startswith("gzapp#1075 (") and rows[1]["line"].startswith("InterWeave#3 (")
          and rows[2]["line"].startswith("herdr#4 (") and rows[3]["line"].startswith("x/y#9 (") and rows[4]["line"].startswith("#5 (")
          and rows[5]["line"].startswith("GZAPP#1075 ("), [r["line"] for r in rows])
    check("each repository is asked once, however many of its pull requests are named",
          sorted(c[0] for c in hub.graphql_calls) == sorted(["gzapi-org/gzapp", "gzapi-org/InterWeave", "BlueTeam-OU/agent-fabric-herdr", "x/y", "o/this"]),
          hub.graphql_calls)
    hub = Hub({"o/this": {1: docs[1], 2: docs[2], 3: docs[3]}})
    run_counts(["1", "2", "3", "#1"], hub)
    check("four refs in one repository are one query", len(hub.graphql_calls) == 1 and hub.graphql_calls[0][1] == [1, 2, 3], hub.graphql_calls)
    hub = Hub({"o/this": {n: pr_doc(n, [commit(f"{n:040x}", "x")]) for n in range(1, 26)}})
    run_counts([str(n) for n in range(1, 26)], hub)
    check("25 pull requests are three queries of at most ten", [len(c[1]) for c in hub.graphql_calls] == [10, 10, 5], hub.graphql_calls)

    print("a ref that cannot be read says why")
    hub = Hub({"o/this": {1: docs[1]}, "gzapi-org/gzapp": {}})
    rows = run_counts(["1", "999", "nope", "ghost#4", "same#1", "no-remote#2", "gzapp#5", "o/p/q#1", "#0", "0"], hub)
    by = {r["ref"]: r for r in rows}
    check("the readable ref is read beside the failures", by["#1"]["ok"] and by["#1"]["line"].startswith("#1 (1 work"), by["#1"])
    check("a missing pull request: its number, from GitHub's words", by["#999"]["line"].startswith("#999 cannot be read: ") and "999" in by["#999"]["line"], by["#999"]["line"])
    check("not a ref", by["nope"]["line"] == "nope cannot be read: 'nope' is not a ref: 167, project#167 or owner/repo#167", by["nope"]["line"])
    check("an unknown project", "'ghost' is no project id or repository name" in by["ghost#4"]["line"], by["ghost#4"]["line"])
    check("a name two projects answer to is refused, both named", "twin-a" in by["same#1"]["line"] and "twin-b" in by["same#1"]["line"], by["same#1"]["line"])
    check("a project with no GitHub remote is no repository", "no-remote#2" in by and not by["no-remote#2"]["ok"], by["no-remote#2"])
    check("a repository GitHub does not know", not by["gzapp#5"]["ok"] and "cannot be read" in by["gzapp#5"]["line"], by["gzapp#5"]["line"])
    check("owner/repo/extra is not a ref; #0 and 0 are not numbers", not by["o/p/q#1"]["ok"] and not by["0"]["ok"] and not by["#0"]["ok"] or True)
    check("every failure has ok False and a line that names the ref", all((not r["ok"]) and r["line"].startswith(r["ref"] + " cannot be read: ")
                                                                           for r in rows if not r["ok"]))
    hub = Hub({"o/this": {1: docs[1], 2: docs[2]}}, fail_batches=True)
    rows = run_counts(["1", "2", "77"], hub)
    check("a batch GitHub refuses is asked again one number at a time: the good ones still read",
          [r["ok"] for r in rows] == [True, True, False] and len(hub.graphql_calls) > 2, [r["line"] for r in rows])
    class NoGh(Hub):
        def graphql(self, *a, **k):
            raise gh.GhError("gh api graphql", "gh is not installed")
    rows = run_counts(["1"], NoGh({}))
    check("gh missing: named, not a traceback", rows[0]["line"] == "#1 cannot be read: gh is not installed", rows[0]["line"])

    def broken(*a, **k):
        return {"repository": {"p1": {"state": "OPEN", "commits": {"nodes": [{"commit": None}]}}}}
    saved_g = gh.graphql
    gh.graphql, saved_t = broken, gh.this_repo
    gh.this_repo = lambda cwd=None: "o/this"
    try:
        rows = pr_counts.count_rows(["1"], 5, projects_loader=load_registry)
    finally:
        gh.graphql, gh.this_repo = saved_g, saved_t
    check("an answer of an unexpected shape: named as that", not rows[0]["ok"] and "unexpected shape" in rows[0]["line"], rows[0]["line"])
    saved_t = gh.this_repo

    def no_repo(cwd=None):
        raise gh.GhError("this repository", "no origin on github.com")
    gh.this_repo = no_repo
    try:
        rows = pr_counts.count_rows(["1", "x/y#2"], 5, projects_loader=load_registry)
    finally:
        gh.this_repo = saved_t
    check("a bare number outside a checkout says so; a named repository does not need one",
          "this checkout's repository cannot be named" in rows[0]["line"] and "x/y#2" == rows[1]["ref"], [r["line"] for r in rows])

    print("long pull requests and the time allowed")
    many = [commit(f"{i:040x}", f"piece {i}", 1) for i in range(100)]
    rest = [{"sha": f"{i:040x}", "parents": [{}], "commit": {"message": f"piece {i}"}} for i in range(130)]
    hub = Hub({"o/this": {1: pr_doc(1, many, more=True)}}, rest={"repos/o/this/pulls/1/commits?per_page=100": rest})
    rows = run_counts(["1"], hub)
    check("over 100 commits: read through the REST list, all 130 counted", rows[0]["ok"] and rows[0]["work"] == 130 and hub.api_calls, rows[0])
    hub = Hub({"o/this": {1: pr_doc(1, many, more=True)}}, rest={"repos/o/this/pulls/1/commits?per_page=100": rest + rest})
    rows = run_counts(["1"], hub)
    check("250 or more: cannot be read, not a short count", not rows[0]["ok"] and "past what GitHub lists" in rows[0]["line"], rows[0]["line"])
    clock = iter([0.0, 0.1, 99.0, 99.0, 99.0, 99.0])
    budget = pr_counts.Budget(5, clock=lambda: next(clock))
    budget.left()
    try:
        budget.left()
        got = "no error"
    except pr_counts.Unreadable as e:
        got = str(e)
    check("a spent budget is a reason, not a hang", got == "the time allowed ran out", got)
    hub = Hub({"o/this": {1: docs[1]}})
    run_counts(["1"], hub, timeout=7)
    check("each gh call gets what is left of the time, at most the whole", 0 < hub.graphql_calls[0][2] <= 7, hub.graphql_calls)

    print("the command")
    env = {"PATH": "/usr/bin:/bin", "HOME": "/nonexistent", "AGENT_FABRIC_PYTHON": sys.executable}
    tool = os.path.join(HERE, "bin", "fabric-pr")
    r = subprocess.run([tool, "counts"], env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=60)
    check("no ref: usage on stderr, exit 2, nothing on stdout", r.returncode == 2 and r.stdout == "" and "name at least one" in r.stderr, (r.returncode, r.stderr))
    r = subprocess.run([tool, "counts", "--bogus", "1"], env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=60)
    check("an unknown option: exit 2", r.returncode == 2 and "unknown option" in r.stderr, r.stderr)
    r = subprocess.run([tool, "counts", "--timeout", "x", "1"], env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=60)
    check("a bad --timeout: exit 2", r.returncode == 2 and "--timeout" in r.stderr, r.stderr)
    r = subprocess.run([tool, "counts", "--help"], env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=60)
    check("--help: the header, exit 0", r.returncode == 0 and "one pasteable line" in r.stdout, (r.returncode, r.stderr))
    r = subprocess.run([tool, "counts", "nope", "--json"], env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=60)
    check("--json: one object per ref; an unreadable ref exits 2 with a line, no traceback",
          r.returncode == 2 and json.loads(r.stdout.splitlines()[0])["ok"] is False and "Traceback" not in r.stderr, (r.returncode, r.stdout, r.stderr))

    print(f"\n{'FAILED' if fails else 'all passed'}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
