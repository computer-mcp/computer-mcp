#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
cd "$ROOT_DIR"

RG=(rg -n --hidden \
  --glob '!.git/**' \
  --glob '!.build/**' \
  --glob '!**/.build/**' \
  --glob '!dist/**' \
  --glob '!AGENTS.md' \
  --glob '!Scripts/verify-naming.sh')
PATHS=(.)

fail_if_match() {
  local description=$1
  local pattern=$2
  if "${RG[@]}" "$pattern" $PATHS; then
    echo "Naming verification failed: $description" >&2
    exit 1
  fi
}

fail_if_match "retired Validation Suite names" \
  'ManualAcceptance|computer-mcp-manual|manual-cases|CMCP-E2E|computer-mcp-e2e'
fail_if_match "retired configuration or MCP aliases" \
  'tunnel_exposed|gateway\+reexport|cli\.run|config\.migrate|COMPUTER_MCP_HTTP_TOKEN|client_request_id|external_consumer_request_id'
fail_if_match "unsupported public schema labels" \
  'schema[_ -]?v[23]|schema_version[[:space:]]*=[[:space:]]*[23]'
fail_if_match "retired release-stage identifiers" \
  'ProductionGateway|ProductionDatabase|ProductionGatewayDefaults|ProductionMCPClientSession|ProductControlPlane|ProductControlSocketService|ManagedTunnelProfile|CloudflareTunnelProfile|LocalGatewayStdioSocketBridge|productionTools'
fail_if_match "ambiguous OpenAI Tunnel identifiers" \
  '\bChatGPTTunnel|\bTunnelSupervisor\b|\bTunnelLauncher\b|\bTunnelLifecycleState\b|\bTunnelStatus\b|\bTunnelDoctorReport\b|\bTunnelLogPage\b|\bTunnelAPIKeyCheckpoint\b|desired-running-tunnels'
fail_if_match "retired script names" \
  'check-public-repository|check-swift-codex-release-gate|smoke-install-dmg'
fail_if_match "retired public quality labels" \
  '(?i)\bbackend\b|\blegacy\b|\bmanual\b|\bsmoke\b'
fail_if_match "noncanonical Foundation JSON key conversion" \
  'convertToSnakeCase|convertFromSnakeCase'

echo "Naming verification passed."
