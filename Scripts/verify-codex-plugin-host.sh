#!/bin/zsh
set -euo pipefail

if (( $# != 1 )) || [[ "$1" != /* || ! -f "$1" || ! -x "$1" ]]; then
  print -u2 -- "Usage: $0 /absolute/path/to/codex-mcp-adapter"
  exit 64
fi
ROOT_DIR=${0:A:h:h}
if [[ ! -f "${1:A:h:h}/computer-mcp-plugin.toml" ]]; then
  print -u2 -- "Supply the adapter under a packaged plugin's bin directory."
  exit 64
fi
cd "$ROOT_DIR"
# Only this test process receives the explicitly supplied independent artifact.
export COMPUTER_MCP_TEST_CODEX_PLUGIN="$1"
/usr/bin/swift test --force-resolved-versions --no-parallel \
  --filter 'CodexPluginHostIntegrationTests|CodexPluginBoundServicesTests|CodexPluginConnectionTests|RealCodexPluginAcceptanceTests'

if [[ "${COMPUTER_MCP_REAL_CODEX_ACCEPTANCE:-0}" == "1" ]]; then
  gateway_executable=${COMPUTER_MCP_TEST_GATEWAY_EXECUTABLE:-}
  if [[ -z "$gateway_executable" ]]; then
    gateway_executable="$(/usr/bin/swift build --show-bin-path)/computer-mcp"
  fi
  /usr/bin/python3 "$ROOT_DIR/Scripts/verify-codex-gateway-flow.py" \
    "$gateway_executable" "$1" "$COMPUTER_MCP_REAL_CODEX_EXECUTABLE" \
    "$ROOT_DIR/Tests/ComputerMCPTests/Fixtures/NativeCodex/ModelServer.py"
fi
