#!/bin/zsh
set -euo pipefail

RIPGREP_EXECUTABLE=${RIPGREP_EXECUTABLE:-rg}
if ! command -v "$RIPGREP_EXECUTABLE" >/dev/null 2>&1; then
  echo "Verification failed: ripgrep is unavailable. Set RIPGREP_EXECUTABLE to an existing installation." >&2
  exit 127
fi
"$RIPGREP_EXECUTABLE" --version >/dev/null

# A failed inspection is not the same as a successful search with no matches.
rg() {
  local result=0
  command "$RIPGREP_EXECUTABLE" "$@" || result=$?
  if (( result > 1 )); then
    echo "Verification failed: ripgrep could not complete the inspection (exit $result)." >&2
    exit "$result"
  fi
  return "$result"
}

ROOT_DIR=${0:A:h:h}
cd "$ROOT_DIR"

PRODUCTS=$(/usr/bin/swift package dump-package | jq -c '[.products[].name] | sort')
if [[ "$PRODUCTS" != '["ComputerMCPApp","computer-mcp"]' ]]; then
  echo "Package boundary gate failed: only the App and CLI executable products are allowed." >&2
  exit 1
fi

if rg -n '^\s*public\b' Sources/ComputerMCP --glob '*.swift'; then
  echo "Package boundary gate failed: ComputerMCP implementation declarations must not be public." >&2
  exit 1
fi

if rg -n '^(@testable )?import ComputerMCP$' Tools/Validation; then
  echo "Package boundary gate failed: Validation imports the production implementation module." >&2
  exit 1
fi

if rg -n '\.package\(\s*path:\s*"\.\./\.\."' Tools/Validation/Package.swift; then
  echo "Package boundary gate failed: Validation still depends on the root package by path." >&2
  exit 1
fi

if rg -n 'swift-codex|CodexAppServer(Client|Protocol|Runtime)|CodexExec|CodexMCP' Package.swift; then
  echo "Package boundary gate failed: domain execution dependencies belong to independent plugins." >&2
  exit 1
fi

echo "App/CLI package boundary gate passed."
