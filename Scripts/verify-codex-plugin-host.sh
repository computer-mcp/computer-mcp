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
exec /usr/bin/swift test --force-resolved-versions --no-parallel \
  --filter 'CodexPluginHostIntegrationTests|CodexPluginBoundServicesTests|CodexPluginConnectionTests|RealCodexPluginAcceptanceTests'
