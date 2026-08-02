#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
PACKAGE="$ROOT_DIR/Package.swift"
RESOLVED="$ROOT_DIR/Package.resolved"
PACKAGE_FLAT=$(tr '\n' ' ' < "$PACKAGE")

if print -r -- "$PACKAGE_FLAT" | rg -q '\.package\([^)]*(path:|branch:|revision:)[^)]*swift-codex'; then
  echo "GitHub release gate blocked: swift-codex is still a local path dependency." >&2
  echo "Publish swift-codex, select a fixed tag, and replace it with an exact remote dependency." >&2
  exit 1
fi

if ! print -r -- "$PACKAGE_FLAT" | rg -q '\.package\(\s*url:\s*"https://github\.com/swift-library/swift-codex\.git"\s*,\s*exact:\s*"0\.1\.1"\s*\)'; then
  echo "GitHub release gate blocked: swift-codex must be an exact remote dependency." >&2
  exit 1
fi

if ! jq -e '
  [.pins[] | select(.identity == "swift-codex")]
  | length == 1
    and .[0].location == "https://github.com/swift-library/swift-codex.git"
    and .[0].state.version == "0.1.1"
    and (.[0].state.revision | test("^[0-9a-f]{40}$"))
' "$RESOLVED" >/dev/null; then
  echo "GitHub release gate blocked: Package.resolved does not pin swift-codex 0.1.1." >&2
  exit 1
fi

echo "swift-codex release dependency gate passed."
