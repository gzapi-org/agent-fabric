#!/usr/bin/env python3
"""runtime/mcp/websearch-locale/install.py — the MCP entry for the locale
search tool in a login's Claude Code user configuration.

    install.py <claude.json> set <server.mjs> <locale.json> [--dry-run]
    install.py <claude.json> remove [--dry-run]

`set` writes (or leaves, when identical) mcpServers["websearch-locale"]
as a stdio server running <server.mjs> with WEBSEARCH_LOCALE_FILE set to
<locale.json>; `remove` deletes an entry that runs this fabric's server —
recognised by the path in its args — and never one the login wrote
itself. Prints one line in the installer's shape (+ = -) and exits 0.
The file is Claude Code's own: every other key is kept as read.
"""
from __future__ import annotations

import json
import os
import sys

NAME = "websearch-locale"
MARKER = "runtime/mcp/websearch-locale/server.mjs"


def load(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return {}
    return data if isinstance(data, dict) else {}


def save(path: str, data: dict) -> None:
    tmp = f"{path}.agent-fabric.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def ours(entry: object) -> bool:
    return isinstance(entry, dict) and any(MARKER in str(a) for a in entry.get("args", []))


def main(argv: list[str]) -> int:
    dry = "--dry-run" in argv
    argv = [a for a in argv if a != "--dry-run"]
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    path, op = argv[0], argv[1]
    data = load(path)
    servers = data.get("mcpServers") if isinstance(data.get("mcpServers"), dict) else {}
    current = servers.get(NAME)
    if op == "set":
        server, locale = argv[2], argv[3]
        want = {"type": "stdio", "command": "node", "args": [server], "env": {"WEBSEARCH_LOCALE_FILE": locale}}
        if current == want:
            print(f"  =  {path} mcpServers.{NAME}")
            return 0
        if current is not None and not ours(current):
            print(f"  !  {path} mcpServers.{NAME} is not this fabric's; left as is")
            return 0
        if dry:
            print(f"  +  {path} mcpServers.{NAME} (would write)")
            return 0
        servers[NAME] = want
        data["mcpServers"] = servers
        save(path, data)
        print(f"  +  {path} mcpServers.{NAME}")
        return 0
    if op == "remove":
        if current is None or not ours(current):
            return 0
        if dry:
            print(f"  -  {path} mcpServers.{NAME} (would remove: not a language-culture login with a locale)")
            return 0
        del servers[NAME]
        data["mcpServers"] = servers
        save(path, data)
        print(f"  -  {path} mcpServers.{NAME} (removed: not a language-culture login with a locale)")
        return 0
    print(f"install.py: unknown op {op}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
