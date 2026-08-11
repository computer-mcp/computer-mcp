#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
SWIFT_EXECUTABLE=${SWIFT_EXECUTABLE:-/usr/bin/swift}
SWIFT_BUILD_SYSTEM=${SWIFT_BUILD_SYSTEM:-native}

BIN_DIR=$(
  "$SWIFT_EXECUTABLE" build \
    --package-path "$ROOT_DIR" \
    --build-system "$SWIFT_BUILD_SYSTEM" \
    --show-bin-path
)
CLI="$BIN_DIR/computer-mcp"

fail() {
  echo "Example verification failed: $1" >&2
  exit 1
}

[[ -x "$CLI" ]] || fail "computer-mcp executable is unavailable."

configs=("$ROOT_DIR"/Examples/computer-mcp*.toml(N))
(( ${#configs[@]} > 0 )) || fail "no Computer MCP TOML examples were found."

for config in $configs; do
  "$CLI" config validate --config "$config" >/dev/null
done

echo "Example verification passed: ${#configs[@]} standalone configurations."
