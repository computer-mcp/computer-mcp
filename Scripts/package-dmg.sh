#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
OUTPUT_DIR=${OUTPUT_DIR:-"$ROOT_DIR/dist"}
APP_PATH="$OUTPUT_DIR/Computer MCP.app"
DMG_PATH=${DMG_PATH:-"$OUTPUT_DIR/Computer-MCP-1.0.0-universal.dmg"}
METADATA_DIR="$OUTPUT_DIR/ReleaseMetadata"
RELEASE_MODE=${RELEASE_MODE:-0}
STAGING_PARENT=$(mktemp -d "${TMPDIR:-/tmp}/computer-mcp-dmg.XXXXXX")
STAGING_DIR="$STAGING_PARENT/Computer MCP 1.0.0"
APP_NOTARY_ZIP="$OUTPUT_DIR/Computer-MCP-1.0.0-app-notary.zip"
CHECKSUM_PATH="$OUTPUT_DIR/SHA256SUMS"

cleanup() {
  /bin/rm -rf -- "$STAGING_PARENT"
  /bin/rm -f -- "$APP_NOTARY_ZIP"
}
trap cleanup EXIT

fail() {
  echo "error: $1" >&2
  exit 1
}

[[ -d "$APP_PATH" ]] || fail "Missing app bundle: $APP_PATH"
[[ -f "$METADATA_DIR/ThirdPartyNotices.txt" ]] \
  || fail "Missing generated ThirdPartyNotices.txt. Run Scripts/build-app.sh first."
/bin/mkdir -p "$STAGING_DIR"

if [[ "$RELEASE_MODE" == "1" ]]; then
  [[ -n ${SIGNING_IDENTITY:-} ]] || fail "Release mode requires SIGNING_IDENTITY."
  [[ -n ${EXPECTED_TEAM_ID:-} ]] || fail "Release mode requires EXPECTED_TEAM_ID."
  [[ -n ${NOTARY_KEYCHAIN_PROFILE:-} ]] \
    || fail "Release mode requires NOTARY_KEYCHAIN_PROFILE."
  if rg -q -i \
    'release-candidate legal draft|legal review (is|are )?required before publication' \
    "$ROOT_DIR/LICENSE" "$ROOT_DIR/EULA.md" "$ROOT_DIR/PRIVACY.md"
  then
    fail "Release mode requires approved legal files without draft markers."
  fi
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
  signature=$(/usr/bin/codesign -d --verbose=4 "$APP_PATH" 2>&1)
  [[ "$signature" == *"Authority=Developer ID Application:"* ]] \
    || fail "The App is not signed with Developer ID Application."
  [[ "$signature" == *"TeamIdentifier=$EXPECTED_TEAM_ID"* ]] \
    || fail "The App Team ID does not match EXPECTED_TEAM_ID."
  [[ "$signature" == *"Timestamp="* ]] || fail "The App has no secure timestamp."

  /usr/bin/ditto -c -k --keepParent "$APP_PATH" "$APP_NOTARY_ZIP"
  xcrun notarytool submit \
    "$APP_NOTARY_ZIP" \
    --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
    --wait
  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH"
else
  echo "Creating a development DMG; notarization is disabled." >&2
fi

/bin/cp -R "$APP_PATH" "$STAGING_DIR/"
/bin/ln -s /Applications "$STAGING_DIR/Applications"
/bin/cp "$METADATA_DIR/ThirdPartyNotices.txt" "$STAGING_DIR/ThirdPartyNotices.txt"
/bin/cp \
  "$METADATA_DIR/Computer-MCP-1.0.0-DependencyManifest.json" \
  "$STAGING_DIR/Computer-MCP-1.0.0-DependencyManifest.json"
/bin/cp \
  "$METADATA_DIR/Computer-MCP-1.0.0-SBOM.cdx.json" \
  "$STAGING_DIR/Computer-MCP-1.0.0-SBOM.cdx.json"
/bin/cp "$ROOT_DIR/LICENSE" "$STAGING_DIR/ComputerMCPSourceVisibleLicense.txt"
/bin/cp "$ROOT_DIR/EULA.md" "$STAGING_DIR/EULA.md"
/bin/cp "$ROOT_DIR/PRIVACY.md" "$STAGING_DIR/PRIVACY.md"

/usr/bin/cmp -s \
  "$APP_PATH/Contents/Resources/ThirdPartyNotices.txt" \
  "$STAGING_DIR/ThirdPartyNotices.txt" \
  || fail "App and DMG ThirdPartyNotices.txt differ."

if [[ -e "$DMG_PATH" ]]; then
  /bin/rm -f -- "$DMG_PATH"
fi
/usr/sbin/diskutil image create from \
  --format UDZO \
  "$STAGING_DIR" \
  "$DMG_PATH"

if [[ "$RELEASE_MODE" == "1" ]]; then
  xcrun notarytool submit \
    "$DMG_PATH" \
    --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
    --wait
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
fi

DMG_HASH=$(/usr/bin/shasum -a 256 "$DMG_PATH" | /usr/bin/awk '{print $1}')
/usr/bin/printf '%s  %s\n' "$DMG_HASH" "${DMG_PATH:t}" > "$CHECKSUM_PATH"

if [[ "$RELEASE_MODE" == "1" ]]; then
  [[ -s "$CHECKSUM_PATH" ]] || fail "Final SHA256SUMS was not created."
  echo "Created notarized and stapled release DMG: $DMG_PATH"
else
  echo "Created development Universal 2 DMG: $DMG_PATH"
fi
echo "Final DMG SHA256: $DMG_HASH"
