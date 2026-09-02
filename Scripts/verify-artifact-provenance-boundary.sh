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

line_for() {
  local file=$1
  local text=$2
  local line
  line=$(/usr/bin/grep -Fn "$text" "$file" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)
  [[ -n "$line" ]] || fail "missing ordered boundary: $text"
  print -r -- "$line"
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

draft_line=$(line_for "$WORKFLOW" 'gh release create "$GITHUB_REF_NAME" \')
download_line=$(line_for "$WORKFLOW" 'gh release download "$GITHUB_REF_NAME" \')
compare_line=$(line_for "$WORKFLOW" 'cmp -s "dist/$dmg_name" "$download_dir/$dmg_name" || {')
receipt_line=$(line_for "$WORKFLOW" 'Scripts/write-artifact-provenance.sh \')
verify_line=$(line_for "$WORKFLOW" 'VERIFY_GIT_TAG=1 Scripts/verify-artifact-provenance.sh \')
identity_line=$(line_for "$WORKFLOW" 'BUILD_IDENTITY_PATH="dist/Computer MCP.app/Contents/Resources/ComputerMCPBuildIdentity.plist" \')
upload_line=$(line_for "$WORKFLOW" 'gh release upload "$GITHUB_REF_NAME" "$published_receipt"')
publish_line=$(line_for "$WORKFLOW" 'gh release edit "$GITHUB_REF_NAME" --draft=false')

[[ "$draft_line" -lt "$download_line" \
  && "$download_line" -lt "$compare_line" \
  && "$compare_line" -lt "$receipt_line" \
  && "$receipt_line" -lt "$verify_line" \
  && "$identity_line" -lt "$verify_line" \
  && "$verify_line" -lt "$upload_line" \
  && "$upload_line" -lt "$publish_line" ]] \
  || fail "GitHub release must remain draft until uploaded bytes and the published receipt verify."

echo "Artifact provenance boundary passed."
