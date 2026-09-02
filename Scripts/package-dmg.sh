#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
OUTPUT_DIR=${OUTPUT_DIR:-"$ROOT_DIR/dist"}
APP_PATH="$OUTPUT_DIR/Computer MCP.app"
METADATA_DIR="$OUTPUT_DIR/ReleaseMetadata"
INFO_PLIST="$ROOT_DIR/Resources/ComputerMCPApp/Info.plist"
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")
APP_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")
RELEASE_MODE=${RELEASE_MODE:-0}
SOURCE_COMMIT=${SOURCE_COMMIT:-$(git -C "$ROOT_DIR" rev-parse HEAD)}
ARTIFACT_BUILD_ID=${ARTIFACT_BUILD_ID:-"$APP_BUILD-${SOURCE_COMMIT[1,12]}"}
if [[ "$RELEASE_MODE" == "1" ]]; then
  ARTIFACT_CLASS=${ARTIFACT_CLASS:-release_candidate}
  DMG_PATH=${DMG_PATH:-"$OUTPUT_DIR/Computer-MCP-$APP_VERSION-universal.dmg"}
else
  ARTIFACT_CLASS=${ARTIFACT_CLASS:-development}
  DMG_PATH=${DMG_PATH:-"$OUTPUT_DIR/Computer-MCP-$APP_VERSION-$ARTIFACT_CLASS-$ARTIFACT_BUILD_ID-universal.dmg"}
fi
PROVENANCE_PATH=${PROVENANCE_PATH:-"${DMG_PATH:r}-ArtifactProvenance.json"}
WORKING_DMG_PATH="$DMG_PATH"
if [[ "$RELEASE_MODE" == "1" ]]; then
  WORKING_DMG_PATH="$OUTPUT_DIR/.Computer-MCP-$APP_VERSION-release-candidate-$ARTIFACT_BUILD_ID.dmg"
fi
STAGING_PARENT=$(mktemp -d "${TMPDIR:-/tmp}/computer-mcp-dmg.XXXXXX")
STAGING_DIR="$STAGING_PARENT/Computer MCP $APP_VERSION"
APP_NOTARY_ZIP="$OUTPUT_DIR/Computer-MCP-$APP_VERSION-app-notary.zip"
CHECKSUM_PATH="$OUTPUT_DIR/SHA256SUMS"
APP_NOTARY_RECORD="$METADATA_DIR/Computer-MCP-$APP_VERSION-AppNotary.json"
DMG_NOTARY_RECORD="$METADATA_DIR/Computer-MCP-$APP_VERSION-DMGNotary.json"
typeset -a NOTARY_ARGUMENTS=()

cleanup() {
  /bin/rm -rf -- "$STAGING_PARENT"
  /bin/rm -f -- "$APP_NOTARY_ZIP"
  if [[ "$WORKING_DMG_PATH" != "$DMG_PATH" ]]; then
    /bin/rm -f -- "$WORKING_DMG_PATH"
  fi
}
trap cleanup EXIT

fail() {
  echo "error: $1" >&2
  exit 1
}

configure_notary_arguments() {
  local api_value_count=0
  [[ -n ${ASC_API_KEY_PATH:-} ]] && api_value_count=$((api_value_count + 1))
  [[ -n ${ASC_API_KEY_ID:-} ]] && api_value_count=$((api_value_count + 1))
  [[ -n ${ASC_API_ISSUER_ID:-} ]] && api_value_count=$((api_value_count + 1))

  [[ "$api_value_count" == "3" ]] \
    || fail "Release mode requires ASC_API_KEY_PATH, ASC_API_KEY_ID, and ASC_API_ISSUER_ID."
  [[ -f "$ASC_API_KEY_PATH" ]] || fail "App Store Connect API key not found: $ASC_API_KEY_PATH"
  [[ $(/usr/bin/stat -f '%Lp' "$ASC_API_KEY_PATH") == 600 \
    || $(/usr/bin/stat -f '%Lp' "$ASC_API_KEY_PATH") == 400 ]] \
    || fail "ASC_API_KEY_PATH must be owner-readable only (mode 0600 or 0400)."
  [[ "$ASC_API_KEY_ID" =~ '^[[:alnum:]]{10,}$' ]] \
    || fail "ASC_API_KEY_ID has an invalid format."
  [[ "$ASC_API_ISSUER_ID" =~ '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' ]] \
    || fail "ASC_API_ISSUER_ID must be a UUID."
  NOTARY_ARGUMENTS=(
    --key "$ASC_API_KEY_PATH"
    --key-id "$ASC_API_KEY_ID"
    --issuer "$ASC_API_ISSUER_ID"
  )
}

submit_for_notarization() {
  local artifact_path=$1
  local record_path=$2
  local artifact_name=$3
  local submission_id

  xcrun notarytool submit \
    "$artifact_path" \
    "${NOTARY_ARGUMENTS[@]}" \
    --wait \
    --output-format json >"$record_path"
  submission_id=$("$ROOT_DIR/Scripts/verify-notarization-record.sh" \
    "$record_path" "$artifact_name")
  chmod 600 "$record_path"
  echo "$artifact_name notarization accepted: $submission_id"
}

[[ -d "$APP_PATH" ]] || fail "Missing app bundle: $APP_PATH"
[[ "$SOURCE_COMMIT" =~ '^[0-9a-f]{40}$' ]] \
  || fail "SOURCE_COMMIT must be a full lowercase Git commit."
[[ "$ARTIFACT_BUILD_ID" =~ '^[A-Za-z0-9._-]{1,200}$' ]] \
  || fail "ARTIFACT_BUILD_ID is missing or unsafe."
if [[ "$RELEASE_MODE" == "1" ]]; then
  [[ "$ARTIFACT_CLASS" == "release_candidate" ]] \
    || fail "Release packaging must create the release_candidate artifact class."
  [[ "${DMG_PATH:t}" == "Computer-MCP-$APP_VERSION-universal.dmg" ]] \
    || fail "Release candidate output must use the exact final asset filename."
else
  [[ "$ARTIFACT_CLASS" == "development" || "$ARTIFACT_CLASS" == "validation" ]] \
    || fail "Local packaging supports only development or validation artifact classes."
  [[ "${DMG_PATH:t}" == *"-$ARTIFACT_CLASS-"* ]] \
    || fail "Local artifact filename must identify its $ARTIFACT_CLASS class."
fi
[[ ! -e "$DMG_PATH" && ! -e "$PROVENANCE_PATH" ]] \
  || fail "Refusing to overwrite an existing artifact or provenance receipt."
[[ -f "$METADATA_DIR/ThirdPartyNotices.txt" ]] \
  || fail "Missing generated ThirdPartyNotices.txt. Run Scripts/build-app.sh first."
APP_ENVIRONMENT=$(/usr/bin/plutil -extract ComputerMCPEnvironment raw -o - \
  "$APP_PATH/Contents/Info.plist" 2>/dev/null) \
  || fail "The App does not declare a distribution environment."
APP_BUNDLE_ID=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - \
  "$APP_PATH/Contents/Info.plist")
DMG_SIGNING_IDENTIFIER="$APP_BUNDLE_ID.dmg"
BUILT_APP_VERSION=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - \
  "$APP_PATH/Contents/Info.plist")
BUILT_APP_BUILD=$(/usr/bin/plutil -extract CFBundleVersion raw -o - \
  "$APP_PATH/Contents/Info.plist")
BUILD_IDENTITY_PATH="$APP_PATH/Contents/Resources/ComputerMCPBuildIdentity.plist"
[[ -f "$BUILD_IDENTITY_PATH" ]] || fail "The App is missing its signed build identity."
BUILT_SOURCE_COMMIT=$(/usr/bin/plutil -extract source_commit raw -o - "$BUILD_IDENTITY_PATH")
[[ "$APP_ENVIRONMENT" == "production" ]] \
  || fail "DMG packaging requires the production App environment."
[[ "$APP_BUNDLE_ID" == "com.showxu.computer-mcp" ]] \
  || fail "DMG packaging requires the production Bundle ID."
[[ "$BUILT_APP_VERSION" == "$APP_VERSION" && "$BUILT_APP_BUILD" == "$APP_BUILD" ]] \
  || fail "The built App version does not match the repository release metadata."
[[ "$BUILT_SOURCE_COMMIT" == "$SOURCE_COMMIT" ]] \
  || fail "The built App source commit differs from SOURCE_COMMIT."
/bin/mkdir -p "$STAGING_DIR"

if [[ "$RELEASE_MODE" == "1" ]]; then
  [[ ${GITHUB_ACTIONS:-false} == "true" ]] \
    || fail "Official release packaging is supported only by GitHub Actions."
  [[ ${GITHUB_REF_TYPE:-} == "tag" ]] \
    || fail "Official release packaging requires a GitHub tag ref."
  [[ -n ${SIGNING_IDENTITY:-} ]] || fail "Release mode requires SIGNING_IDENTITY."
  [[ -n ${EXPECTED_TEAM_ID:-} ]] || fail "Release mode requires EXPECTED_TEAM_ID."
  configure_notary_arguments
  if /usr/bin/grep -Eiq \
    'release-candidate legal draft|legal review (is|are )?required before publication' \
    "$ROOT_DIR/LICENSE" "$ROOT_DIR/EULA.md" "$ROOT_DIR/PRIVACY.md"
  then
    fail "Release mode requires approved legal files without draft markers."
  fi
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
  signature=$(/usr/bin/codesign -d --verbose=4 "$APP_PATH" 2>&1)
  print -r -- "$signature" \
    | "$ROOT_DIR/Scripts/verify-developer-id-signature-record.sh" \
      "$EXPECTED_TEAM_ID" "App"

  /bin/mkdir -p "$METADATA_DIR"
  /usr/bin/ditto -c -k --keepParent "$APP_PATH" "$APP_NOTARY_ZIP"
  submit_for_notarization "$APP_NOTARY_ZIP" "$APP_NOTARY_RECORD" "App"
  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH"
else
  echo "Creating a development DMG; notarization is disabled." >&2
fi

/usr/bin/ditto "$APP_PATH" "$STAGING_DIR/Computer MCP.app"
/bin/ln -s /Applications "$STAGING_DIR/Applications"
/bin/cp "$METADATA_DIR/ThirdPartyNotices.txt" "$STAGING_DIR/ThirdPartyNotices.txt"
/bin/cp \
  "$METADATA_DIR/Computer-MCP-$APP_VERSION-DependencyManifest.json" \
  "$STAGING_DIR/Computer-MCP-$APP_VERSION-DependencyManifest.json"
/bin/cp \
  "$METADATA_DIR/Computer-MCP-$APP_VERSION-SBOM.cdx.json" \
  "$STAGING_DIR/Computer-MCP-$APP_VERSION-SBOM.cdx.json"
/bin/cp "$ROOT_DIR/LICENSE" "$STAGING_DIR/ComputerMCPSourceVisibleLicense.txt"
/bin/cp "$ROOT_DIR/EULA.md" "$STAGING_DIR/EULA.md"
/bin/cp "$ROOT_DIR/PRIVACY.md" "$STAGING_DIR/PRIVACY.md"

/usr/bin/cmp -s \
  "$APP_PATH/Contents/Resources/ThirdPartyNotices.txt" \
  "$STAGING_DIR/ThirdPartyNotices.txt" \
  || fail "App and DMG ThirdPartyNotices.txt differ."

/usr/sbin/diskutil image create from \
  --format UDZO \
  "$STAGING_DIR" \
  "$WORKING_DMG_PATH"

if [[ "$RELEASE_MODE" == "1" ]]; then
  /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp --identifier "$DMG_SIGNING_IDENTIFIER" "$WORKING_DMG_PATH"
  /usr/bin/codesign --verify --strict --verbose=2 "$WORKING_DMG_PATH"
  DMG_SIGNATURE=$(/usr/bin/codesign -d --verbose=4 "$WORKING_DMG_PATH" 2>&1)
  print -r -- "$DMG_SIGNATURE" | "$ROOT_DIR/Scripts/verify-developer-id-signature-record.sh" "$EXPECTED_TEAM_ID" "DMG" "$DMG_SIGNING_IDENTIFIER"
  submit_for_notarization "$WORKING_DMG_PATH" "$DMG_NOTARY_RECORD" "DMG"
  xcrun stapler staple "$WORKING_DMG_PATH"
  xcrun stapler validate "$WORKING_DMG_PATH"
  /bin/mv -- "$WORKING_DMG_PATH" "$DMG_PATH"
fi

DMG_HASH=$(/usr/bin/shasum -a 256 "$DMG_PATH" | /usr/bin/awk '{print $1}')
/usr/bin/printf '%s  %s\n' "$DMG_HASH" "${DMG_PATH:t}" > "$CHECKSUM_PATH"

if [[ "$RELEASE_MODE" == "1" ]]; then
  APP_NOTARIZATION_ID=$(/usr/bin/jq -er '.id' "$APP_NOTARY_RECORD")
  DMG_NOTARIZATION_ID=$(/usr/bin/jq -er '.id' "$DMG_NOTARY_RECORD")
  SOURCE_COMMIT="$SOURCE_COMMIT" \
    RELEASE_COMMIT="$SOURCE_COMMIT" \
    RELEASE_TAG="${GITHUB_REF_NAME:-}" \
    BUILD_IDENTITY="$APP_VERSION-$APP_BUILD-$ARTIFACT_BUILD_ID" \
    BUILD_IDENTITY_PATH="$BUILD_IDENTITY_PATH" \
    CREATION_PHASE="release_candidate" \
    APP_NOTARIZATION_STATE=accepted \
    DMG_NOTARIZATION_STATE=accepted \
    APP_NOTARIZATION_ID="$APP_NOTARIZATION_ID" \
    DMG_NOTARIZATION_ID="$DMG_NOTARIZATION_ID" \
    APP_STAPLE_STATE=validated \
    DMG_STAPLE_STATE=validated \
    "$ROOT_DIR/Scripts/write-artifact-provenance.sh" \
      "$DMG_PATH" "$PROVENANCE_PATH" release_candidate
  BUILD_IDENTITY_PATH="$BUILD_IDENTITY_PATH" \
    "$ROOT_DIR/Scripts/verify-artifact-provenance.sh" \
    "$PROVENANCE_PATH" "$DMG_PATH" release_candidate
  [[ -s "$CHECKSUM_PATH" ]] || fail "Final SHA256SUMS was not created."
  echo "Created notarized and stapled release DMG: $DMG_PATH"
else
  SOURCE_COMMIT="$SOURCE_COMMIT" \
    BUILD_IDENTITY="$APP_VERSION-$APP_BUILD-$ARTIFACT_BUILD_ID" \
    BUILD_IDENTITY_PATH="$BUILD_IDENTITY_PATH" \
    CREATION_PHASE="$ARTIFACT_CLASS" \
    "$ROOT_DIR/Scripts/write-artifact-provenance.sh" \
      "$DMG_PATH" "$PROVENANCE_PATH" "$ARTIFACT_CLASS"
  BUILD_IDENTITY_PATH="$BUILD_IDENTITY_PATH" \
    "$ROOT_DIR/Scripts/verify-artifact-provenance.sh" \
    "$PROVENANCE_PATH" "$DMG_PATH" "$ARTIFACT_CLASS"
  echo "Created $ARTIFACT_CLASS Universal 2 DMG: $DMG_PATH"
fi
echo "Final DMG SHA256: $DMG_HASH"
echo "Artifact provenance: $PROVENANCE_PATH"
