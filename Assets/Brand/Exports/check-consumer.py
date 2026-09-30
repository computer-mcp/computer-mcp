#!/usr/bin/env python3
"""Verify a repository's locked Computer MCP brand delivery without a source checkout."""

import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "brand.lock.json"
if not LOCK.exists():
    LOCK = ROOT / "public/brand/brand.lock.json"
record = json.loads(LOCK.read_text())
assert record["schema_version"] == 1, "Unsupported brand lock"
assert record["source"] == "https://github.com/computer-mcp/computer-mcp", "Unexpected brand authority"
for name, expected in record["files"].items():
    path = ROOT / name
    assert path.resolve().is_relative_to(ROOT), f"Invalid delivery path: {name}"
    assert hashlib.sha256(path.read_bytes()).hexdigest() == expected, f"Brand delivery drift: {name}"
if record["consumer"] == "computer-mcp.github.io":
    text = (ROOT / "index.html").read_text()
    for promise in record["promise"].values():
        assert promise in text, "Website promise differs from the imported brand"
    assert 'brand/social-en.png' in text, "Website sharing artwork differs"
else:
    manual = ROOT / ("profile/README.md" if record["consumer"] == ".github" else "README.md")
    text = manual.read_text()
    assert record["name"] in text, "Master name missing from public entry point"
    assert record["promise"]["en"] in text, "Master promise missing from public entry point"
    header = "brand/header.svg" if record["consumer"] == ".github" else "Documentation/Brand/header.svg"
    assert header in text, "Family header missing from public entry point"
print(f"Locked Computer MCP brand verified for {record['consumer']}")
