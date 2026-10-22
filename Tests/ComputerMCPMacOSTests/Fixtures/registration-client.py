#!/usr/bin/python3
"""Isolated MCP client fixture; refuses to operate outside a marked temporary home."""

import json
import os
import pathlib
import sys

home = pathlib.Path(os.environ["HOME"])
if not (home / ".registration-fixture").is_file():
    sys.exit(70)

args = sys.argv[1:]
if args == ["--version"]:
    print("registration-fixture 1.0")
    sys.exit(0)

is_codex = "CODEX_HOME" in os.environ
directory = pathlib.Path(os.environ.get("CODEX_HOME", os.environ.get("CLAUDE_CONFIG_DIR", str(home))))
file = directory / ("fixture-mcp.json" if is_codex else ".claude.json")
document = json.loads(file.read_text()) if file.exists() else {}
servers = document.setdefault("mcpServers", {})
verb = args[1]
name = args[2] if is_codex else args[4]

with (home / "fixture-calls.jsonl").open("a") as trace:
    trace.write(json.dumps({"verb": verb, "name": name, "file": str(file)}) + "\n")

if verb == "get":
    if name not in servers:
        print("No MCP server named " + name, file=sys.stderr)
        sys.exit(1)
    print(json.dumps({"name": name, "transport": servers[name]}))
    sys.exit(0)
if verb == "remove":
    servers.pop(name, None)
elif verb in ("add", "add-json"):
    if not is_codex and name in servers:
        print("already exists in user config", file=sys.stderr)
        sys.exit(1)
    if verb == "add-json":
        servers[name] = json.loads(args[5])
    else:
        command = args[args.index("--") + 1:]
        servers[name] = {"type": "stdio", "command": command[0], "args": command[1:], "env": {}}
else:
    sys.exit(2)
directory.mkdir(parents=True, exist_ok=True)
file.write_text(json.dumps(document))
