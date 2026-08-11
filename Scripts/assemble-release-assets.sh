#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
OUTPUT_DIR=${OUTPUT_DIR:-"$ROOT_DIR/dist"}
APP_PATH="$OUTPUT_DIR/Computer MCP.app"
DMG_PATH=${DMG_PATH:-"$OUTPUT_DIR/Computer-MCP-1.0.0-universal.dmg"}
METADATA_DIR="$OUTPUT_DIR/ReleaseMetadata"
EVIDENCE_MANIFEST=${EVIDENCE_MANIFEST:-"$OUTPUT_DIR/Computer-MCP-1.0.0-EvidenceManifest.json"}
EXPECTED_TEAM_ID=${EXPECTED_TEAM_ID:-}
VERSION=$(/usr/libexec/PlistBuddy \
  -c "Print :CFBundleShortVersionString" \
  "$ROOT_DIR/Resources/ComputerMCPApp/Info.plist")
TAG="v$VERSION"
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
[[ -z $(git -C "$ROOT_DIR" status --porcelain) ]] \
  || fail "Final release asset assembly requires a clean Git worktree."
[[ $(git -C "$ROOT_DIR" cat-file -t "$TAG" 2>/dev/null) == "tag" ]] \
  || fail "$TAG is not an annotated tag."
[[ $(git -C "$ROOT_DIR" rev-parse "$TAG^{}") == $(git -C "$ROOT_DIR" rev-parse HEAD) ]] \
  || fail "$TAG does not point to the current release commit."
git -C "$ROOT_DIR" \
  -c gpg.format=ssh \
  -c gpg.ssh.allowedSignersFile="$ROOT_DIR/.github/signing-allowed-signers" \
  verify-tag "$TAG"

if rg -q -i \
  'release-candidate legal draft|legal review (is|are )?required before publication' \
  "$ROOT_DIR/LICENSE" "$ROOT_DIR/EULA.md" "$ROOT_DIR/PRIVACY.md"
then
  fail "Release legal files still contain draft markers."
fi
if rg -q -i \
  'Status:[[:space:]]*\*\*(NOT READY|release candidate)|\bPending\b|intentionally blank' \
  "$ROOT_DIR/Documentation/Reference/ProductionReadinessReport-1.0.0.md" \
  "$ROOT_DIR/Documentation/Reference/ReleaseNotes-1.0.0.md"
then
  fail "Release notes or readiness report still contain pending markers."
fi

for path in \
  "$APP_PATH" \
  "$DMG_PATH" \
  "$EVIDENCE_MANIFEST" \
  "$METADATA_DIR/Computer-MCP-1.0.0-DependencyManifest.json" \
  "$METADATA_DIR/Computer-MCP-1.0.0-SBOM.cdx.json" \
  "$METADATA_DIR/ThirdPartyNotices.txt"
do
  [[ -e "$path" ]] || fail "Missing release input: $path"
done

RELEASE_MODE=1 \
  EXPECTED_TEAM_ID="$EXPECTED_TEAM_ID" \
  OUTPUT_DIR="$OUTPUT_DIR" \
  DMG_PATH="$DMG_PATH" \
  "$ROOT_DIR/Scripts/verify-distribution.sh"

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

DEPENDENCY_MANIFEST="$OUTPUT_DIR/Computer-MCP-1.0.0-DependencyManifest.json"
SBOM="$OUTPUT_DIR/Computer-MCP-1.0.0-SBOM.cdx.json"
NOTICES="$OUTPUT_DIR/ThirdPartyNotices.txt"
RELEASE_NOTES="$OUTPUT_DIR/Computer-MCP-1.0.0-ReleaseNotes.md"
READINESS_REPORT="$OUTPUT_DIR/Computer-MCP-1.0.0-ProductionReadiness.md"
/bin/cp "$METADATA_DIR/Computer-MCP-1.0.0-DependencyManifest.json" \
  "$DEPENDENCY_MANIFEST"
/bin/cp "$METADATA_DIR/Computer-MCP-1.0.0-SBOM.cdx.json" "$SBOM"
/bin/cp "$METADATA_DIR/ThirdPartyNotices.txt" "$NOTICES"
/bin/cp "$ROOT_DIR/Documentation/Reference/ReleaseNotes-1.0.0.md" "$RELEASE_NOTES"
/bin/cp "$ROOT_DIR/Documentation/Reference/ProductionReadinessReport-1.0.0.md" \
  "$READINESS_REPORT"

assets=(
  "$DMG_PATH"
  "$DEPENDENCY_MANIFEST"
  "$SBOM"
  "$NOTICES"
  "$RELEASE_NOTES"
  "$READINESS_REPORT"
  "$EVIDENCE_MANIFEST"
)
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
