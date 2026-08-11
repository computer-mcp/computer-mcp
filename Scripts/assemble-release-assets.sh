#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
OUTPUT_DIR=${OUTPUT_DIR:-"$ROOT_DIR/dist"}
APP_PATH="$OUTPUT_DIR/Computer MCP.app"
METADATA_DIR="$OUTPUT_DIR/ReleaseMetadata"
EXPECTED_TEAM_ID=${EXPECTED_TEAM_ID:-}
VERSION=$(/usr/libexec/PlistBuddy \
  -c "Print :CFBundleShortVersionString" \
  "$ROOT_DIR/Resources/ComputerMCPApp/Info.plist")
TAG="v$VERSION"
DMG_PATH=${DMG_PATH:-"$OUTPUT_DIR/Computer-MCP-$VERSION-universal.dmg"}
EVIDENCE_MANIFEST=${EVIDENCE_MANIFEST:-"$OUTPUT_DIR/Computer-MCP-$VERSION-EvidenceManifest.json"}
INCLUDE_EVIDENCE_MANIFEST=${INCLUDE_EVIDENCE_MANIFEST:-0}
CHECKSUM_PATH="$OUTPUT_DIR/SHA256SUMS"
TEMP_CHECKSUM=$(mktemp "$OUTPUT_DIR/.SHA256SUMS.XXXXXX")

cleanup() {
  /bin/rm -f -- "$TEMP_CHECKSUM"
}
trap cleanup EXIT

fail() {
  echo "error: $1" >&2
  exit 1
}

[[ -n "$EXPECTED_TEAM_ID" ]] || fail "EXPECTED_TEAM_ID is required."
[[ "$INCLUDE_EVIDENCE_MANIFEST" == "0" || "$INCLUDE_EVIDENCE_MANIFEST" == "1" ]] \
  || fail "INCLUDE_EVIDENCE_MANIFEST must be 0 or 1."
[[ -z $(git -C "$ROOT_DIR" status --porcelain) ]] \
  || fail "Final release asset assembly requires a clean Git worktree."
RELEASE_TAG="$TAG" "$ROOT_DIR/Scripts/verify-release-ref.sh"
"$ROOT_DIR/Scripts/verify-release-readiness.sh"

for input_path in \
  "$APP_PATH" \
  "$DMG_PATH" \
  "$METADATA_DIR/Computer-MCP-$VERSION-DependencyManifest.json" \
  "$METADATA_DIR/Computer-MCP-$VERSION-SBOM.cdx.json" \
  "$METADATA_DIR/ThirdPartyNotices.txt"
do
  [[ -e "$input_path" ]] || fail "Missing release input: $input_path"
done
if [[ "$INCLUDE_EVIDENCE_MANIFEST" == "1" ]]; then
  [[ -f "$EVIDENCE_MANIFEST" ]] || fail "Missing release input: $EVIDENCE_MANIFEST"
fi

RELEASE_MODE=1 \
  EXPECTED_TEAM_ID="$EXPECTED_TEAM_ID" \
  OUTPUT_DIR="$OUTPUT_DIR" \
  DMG_PATH="$DMG_PATH" \
  "$ROOT_DIR/Scripts/verify-distribution.sh"

if [[ "$INCLUDE_EVIDENCE_MANIFEST" == "1" ]]; then
  VALIDATION_BIN_DIR=$(/usr/bin/swift build \
    --package-path "$ROOT_DIR/Tools/Validation" \
    --build-system native \
    --show-bin-path)
  VALIDATION_CLI="$VALIDATION_BIN_DIR/computer-mcp-validate"
  [[ -x "$VALIDATION_CLI" ]] || fail "Validation CLI is unavailable."
  "$VALIDATION_CLI" report verify-release-manifest --manifest "$EVIDENCE_MANIFEST"

  MANIFEST_COMMIT=$(/usr/bin/jq -r '.release.commit' "$EVIDENCE_MANIFEST")
  MANIFEST_TAG=$(/usr/bin/jq -r '.release.tag' "$EVIDENCE_MANIFEST")
  MANIFEST_TEAM=$(/usr/bin/jq -r '.release.team_id' "$EVIDENCE_MANIFEST")
  MANIFEST_APP_HASH=$(/usr/bin/jq -r '.release.app_executable_sha256' "$EVIDENCE_MANIFEST")
  MANIFEST_CLI_HASH=$(/usr/bin/jq -r '.release.embedded_cli_sha256' "$EVIDENCE_MANIFEST")
  MANIFEST_DMG_HASH=$(/usr/bin/jq -r '.release.dmg_sha256' "$EVIDENCE_MANIFEST")
  [[ "$MANIFEST_COMMIT" == $(git -C "$ROOT_DIR" rev-parse HEAD) ]] \
    || fail "Evidence Manifest commit does not match HEAD."
  [[ "$MANIFEST_TAG" == "$TAG" ]] || fail "Evidence Manifest tag does not match $TAG."
  [[ "$MANIFEST_TEAM" == "$EXPECTED_TEAM_ID" ]] \
    || fail "Evidence Manifest Team ID does not match EXPECTED_TEAM_ID."
  [[ "$MANIFEST_APP_HASH" == $(/usr/bin/shasum -a 256 \
    "$APP_PATH/Contents/MacOS/Computer MCP" | /usr/bin/awk '{print $1}') ]] \
    || fail "Evidence Manifest App digest does not match."
  [[ "$MANIFEST_CLI_HASH" == $(/usr/bin/shasum -a 256 \
    "$APP_PATH/Contents/Resources/computer-mcp" | /usr/bin/awk '{print $1}') ]] \
    || fail "Evidence Manifest embedded CLI digest does not match."
  [[ "$MANIFEST_DMG_HASH" == $(/usr/bin/shasum -a 256 "$DMG_PATH" \
    | /usr/bin/awk '{print $1}') ]] \
    || fail "Evidence Manifest DMG digest does not match."
fi

DEPENDENCY_MANIFEST="$OUTPUT_DIR/Computer-MCP-$VERSION-DependencyManifest.json"
SBOM="$OUTPUT_DIR/Computer-MCP-$VERSION-SBOM.cdx.json"
NOTICES="$OUTPUT_DIR/ThirdPartyNotices.txt"
RELEASE_NOTES="$OUTPUT_DIR/Computer-MCP-$VERSION-ReleaseNotes.md"
READINESS_REPORT="$OUTPUT_DIR/Computer-MCP-$VERSION-ProductionReadiness.md"
/bin/cp "$METADATA_DIR/Computer-MCP-$VERSION-DependencyManifest.json" \
  "$DEPENDENCY_MANIFEST"
/bin/cp "$METADATA_DIR/Computer-MCP-$VERSION-SBOM.cdx.json" "$SBOM"
/bin/cp "$METADATA_DIR/ThirdPartyNotices.txt" "$NOTICES"
/bin/cp "$ROOT_DIR/Documentation/Reference/ReleaseNotes-$VERSION.md" "$RELEASE_NOTES"
/bin/cp "$ROOT_DIR/Documentation/Reference/ProductionReadinessReport-$VERSION.md" \
  "$READINESS_REPORT"

assets=(
  "$DMG_PATH"
  "$DEPENDENCY_MANIFEST"
  "$SBOM"
  "$NOTICES"
  "$RELEASE_NOTES"
  "$READINESS_REPORT"
)
if [[ "$INCLUDE_EVIDENCE_MANIFEST" == "1" ]]; then
  assets+=("$EVIDENCE_MANIFEST")
fi
: >"$TEMP_CHECKSUM"
for asset in ${(on)assets}; do
  digest=$(/usr/bin/shasum -a 256 "$asset" | /usr/bin/awk '{print $1}')
  /usr/bin/printf '%s  %s\n' "$digest" "${asset:t}" >>"$TEMP_CHECKSUM"
done
/bin/mv -f "$TEMP_CHECKSUM" "$CHECKSUM_PATH"
(
  cd "$OUTPUT_DIR"
  /usr/bin/shasum -a 256 -c "${CHECKSUM_PATH:t}"
)

echo "Final release assets assembled in $OUTPUT_DIR."
echo "Release asset count: ${#assets[@]}"
