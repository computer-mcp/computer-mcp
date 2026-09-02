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
ARTIFACT_PROVENANCE=${ARTIFACT_PROVENANCE:-"${DMG_PATH:r}-ArtifactProvenance.json"}
EVIDENCE_MANIFEST=${EVIDENCE_MANIFEST:-"$OUTPUT_DIR/Computer-MCP-$VERSION-EvidenceManifest.json"}
INCLUDE_EVIDENCE_MANIFEST=${INCLUDE_EVIDENCE_MANIFEST:-0}
CHECKSUM_PATH="$OUTPUT_DIR/SHA256SUMS"
APP_NOTARY_RECORD="$METADATA_DIR/Computer-MCP-$VERSION-AppNotary.json"
DMG_NOTARY_RECORD="$METADATA_DIR/Computer-MCP-$VERSION-DMGNotary.json"
APP_NOTARY_ASSET="$OUTPUT_DIR/Computer-MCP-$VERSION-AppNotary.json"
DMG_NOTARY_ASSET="$OUTPUT_DIR/Computer-MCP-$VERSION-DMGNotary.json"

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
  "$METADATA_DIR/ThirdPartyNotices.txt" \
  "$APP_NOTARY_RECORD" \
  "$DMG_NOTARY_RECORD" \
  "$ARTIFACT_PROVENANCE"
do
  [[ -e "$input_path" ]] || fail "Missing release input: $input_path"
done
BUILD_IDENTITY_PATH="$APP_PATH/Contents/Resources/ComputerMCPBuildIdentity.plist" \
  VERIFY_GIT_TAG=1 "$ROOT_DIR/Scripts/verify-artifact-provenance.sh" \
  "$ARTIFACT_PROVENANCE" "$DMG_PATH" release_candidate
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
/bin/cp "$APP_NOTARY_RECORD" "$APP_NOTARY_ASSET"
/bin/cp "$DMG_NOTARY_RECORD" "$DMG_NOTARY_ASSET"

RELEASE_COMMIT=$(git -C "$ROOT_DIR" rev-parse HEAD)
RELEASE_TAG_OBJECT=$(git -C "$ROOT_DIR" rev-parse "$TAG")
RELEASE_DATE=$(git -C "$ROOT_DIR" for-each-ref \
  --format='%(taggerdate:format:%Y-%m-%d)' "refs/tags/$TAG")
APP_ARCHITECTURES=$(/usr/bin/lipo -archs "$APP_PATH/Contents/MacOS/Computer MCP")
[[ " $APP_ARCHITECTURES " == *' arm64 '* \
  && " $APP_ARCHITECTURES " == *' x86_64 '* ]] \
  || fail "Release App is not Universal 2."
APP_ARCHITECTURES="arm64 x86_64"
EMBEDDED_CLI_SHA256=$(/usr/bin/shasum -a 256 \
  "$APP_PATH/Contents/Resources/computer-mcp" | /usr/bin/awk '{print $1}')
DMG_SHA256=$(/usr/bin/shasum -a 256 "$DMG_PATH" | /usr/bin/awk '{print $1}')
APP_NOTARY_SUBMISSION_ID=$(/usr/bin/jq -er '.id' "$APP_NOTARY_RECORD")
DMG_NOTARY_SUBMISSION_ID=$(/usr/bin/jq -er '.id' "$DMG_NOTARY_RECORD")
[[ $(/usr/bin/jq -er '.status' "$APP_NOTARY_RECORD") == "Accepted" ]] \
  || fail "App notarization record is not accepted."
[[ $(/usr/bin/jq -er '.status' "$DMG_NOTARY_RECORD") == "Accepted" ]] \
  || fail "DMG notarization record is not accepted."
[[ -n ${GITHUB_SERVER_URL:-} && -n ${GITHUB_REPOSITORY:-} \
  && -n ${GITHUB_RUN_ID:-} ]] \
  || fail "GitHub Actions run identity is required."
GITHUB_RUN_URL="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"

OUTPUT_DIR="$OUTPUT_DIR" \
  RELEASE_DATE="$RELEASE_DATE" \
  RELEASE_COMMIT="$RELEASE_COMMIT" \
  RELEASE_TAG="$TAG" \
  RELEASE_TAG_OBJECT="$RELEASE_TAG_OBJECT" \
  EXPECTED_TEAM_ID="$EXPECTED_TEAM_ID" \
  APP_ARCHITECTURES="$APP_ARCHITECTURES" \
  EMBEDDED_CLI_SHA256="$EMBEDDED_CLI_SHA256" \
  DMG_SHA256="$DMG_SHA256" \
  APP_NOTARY_SUBMISSION_ID="$APP_NOTARY_SUBMISSION_ID" \
  DMG_NOTARY_SUBMISSION_ID="$DMG_NOTARY_SUBMISSION_ID" \
  GITHUB_RUN_URL="$GITHUB_RUN_URL" \
  "$ROOT_DIR/Scripts/render-release-records.sh"

assets=(
  "$DMG_PATH"
  "$DEPENDENCY_MANIFEST"
  "$SBOM"
  "$NOTICES"
  "$RELEASE_NOTES"
  "$READINESS_REPORT"
  "$APP_NOTARY_ASSET"
  "$DMG_NOTARY_ASSET"
  "$ARTIFACT_PROVENANCE"
)
if [[ "$INCLUDE_EVIDENCE_MANIFEST" == "1" ]]; then
  assets+=("$EVIDENCE_MANIFEST")
fi
"$ROOT_DIR/Scripts/write-release-checksums.sh" \
  "$OUTPUT_DIR" \
  "$CHECKSUM_PATH" \
  "${assets[@]}"

echo "Final release assets assembled in $OUTPUT_DIR."
echo "Release asset count: ${#assets[@]}"
