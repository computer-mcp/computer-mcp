#!/bin/zsh
set -euo pipefail

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

echo "App/CLI package boundary gate passed."
