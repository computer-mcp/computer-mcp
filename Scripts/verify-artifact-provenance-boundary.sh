#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
PACKAGE_SCRIPT="$ROOT_DIR/Scripts/package-dmg.sh"
ASSEMBLER="$ROOT_DIR/Scripts/assemble-release-assets.sh"
WORKFLOW="$ROOT_DIR/.github/workflows/release-gate.yml"

fail() {
  echo "Artifact provenance boundary verification failed: $1" >&2
  exit 1
}

require_text() {
  local file=$1
  local text=$2
  /usr/bin/grep -Fq "$text" "$file" || fail "missing required boundary: $text"
}

require_text "$PACKAGE_SCRIPT" 'ARTIFACT_CLASS=${ARTIFACT_CLASS:-development}'
require_text "$PACKAGE_SCRIPT" 'Computer-MCP-$APP_VERSION-$ARTIFACT_CLASS-$ARTIFACT_BUILD_ID-universal.dmg'
require_text "$PACKAGE_SCRIPT" 'WORKING_DMG_PATH="$OUTPUT_DIR/.Computer-MCP-$APP_VERSION-release-candidate-$ARTIFACT_BUILD_ID.dmg"'
require_text "$PACKAGE_SCRIPT" '/bin/mv -- "$WORKING_DMG_PATH" "$DMG_PATH"'
require_text "$PACKAGE_SCRIPT" '"$ROOT_DIR/Scripts/write-artifact-provenance.sh" \'
require_text "$PACKAGE_SCRIPT" 'BUILD_IDENTITY_PATH="$BUILD_IDENTITY_PATH" \'
require_text "$PACKAGE_SCRIPT" '"$ROOT_DIR/Scripts/verify-artifact-provenance.sh" \'
require_text "$ASSEMBLER" 'BUILD_IDENTITY_PATH="$APP_PATH/Contents/Resources/ComputerMCPBuildIdentity.plist" \'
require_text "$ASSEMBLER" 'VERIFY_GIT_TAG=1 "$ROOT_DIR/Scripts/verify-artifact-provenance.sh" \'

if /usr/bin/grep -Eq 'gh release (create|edit|upload)|git tag|draft[=:][[:space:]]*false' "$WORKFLOW"; then
  fail "Candidate construction must stop at an immutable artifact before installed acceptance and tagging."
fi
require_text "$WORKFLOW" 'workflow_dispatch:'
require_text "$WORKFLOW" "github.ref == 'refs/heads/master'"
require_text "$WORKFLOW" 'run: Scripts/verify-candidate-ref.sh'
require_text "$WORKFLOW" 'name: computer-mcp-candidate-${{ github.run_id }}-${{ github.run_attempt }}'
require_text "$WORKFLOW" 'environment: production'

echo "Artifact provenance boundary passed."
