#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
OUTPUT_DIR=${OUTPUT_DIR:-"$ROOT_DIR/dist"}
DMG_PATH=${DMG_PATH:-"$OUTPUT_DIR/Computer-MCP-1.0.0-universal.dmg"}
CURRENT_APP_PATH=${CURRENT_APP_PATH:-"$OUTPUT_DIR/Computer MCP.app"}
CHECKSUM_PATH=${CHECKSUM_PATH:-"$OUTPUT_DIR/SHA256SUMS"}
RELEASE_MODE=${RELEASE_MODE:-0}
MOUNT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/computer-mcp-mount.XXXXXX")
BUILD_INFO_FILE=$(mktemp "${TMPDIR:-/tmp}/computer-mcp-build-info.XXXXXX")

cleanup() {
  /usr/bin/hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true
  /bin/rmdir "$MOUNT_DIR" 2>/dev/null || true
  /bin/rm -f -- "$BUILD_INFO_FILE"
}
trap cleanup EXIT

fail() {
  echo "error: $1" >&2
  exit 1
}

[[ -f "$DMG_PATH" ]] || fail "Missing DMG: $DMG_PATH"
[[ -d "$CURRENT_APP_PATH" ]] || fail "Missing current app bundle: $CURRENT_APP_PATH"
[[ -f "$CHECKSUM_PATH" ]] || fail "Missing SHA256SUMS: $CHECKSUM_PATH"

EXPECTED_HASH=$(/usr/bin/awk -v name="${DMG_PATH:t}" '$2 == name { print $1 }' "$CHECKSUM_PATH")
ACTUAL_HASH=$(/usr/bin/shasum -a 256 "$DMG_PATH" | /usr/bin/awk '{print $1}')
[[ -n "$EXPECTED_HASH" && "$EXPECTED_HASH" == "$ACTUAL_HASH" ]] \
  || fail "DMG SHA-256 does not match SHA256SUMS."

/usr/bin/hdiutil attach "$DMG_PATH" -mountpoint "$MOUNT_DIR" -nobrowse -readonly -quiet
APP_PATH="$MOUNT_DIR/Computer MCP.app"
CLI_PATH="$APP_PATH/Contents/Resources/computer-mcp"
BUILD_IDENTITY="$APP_PATH/Contents/Resources/ComputerMCPBuildIdentity.plist"

[[ -x "$APP_PATH/Contents/MacOS/Computer MCP" ]] || fail "Missing App executable."
[[ -x "$CLI_PATH" ]] || fail "Missing embedded CLI."
[[ -f "$BUILD_IDENTITY" ]] || fail "Missing signed build identity."
/usr/bin/plutil -lint "$APP_PATH/Contents/Info.plist" >/dev/null
/usr/bin/plutil -lint "$BUILD_IDENTITY" >/dev/null
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

verify_universal_binary() {
  local binary=$1
  local architectures
  local -a architecture_list
  architectures=$(/usr/bin/lipo -archs "$binary")
  architecture_list=(${=architectures})
  [[ " $architectures " == *" arm64 "* ]] || fail "Missing arm64 slice: $binary"
  [[ " $architectures " == *" x86_64 "* ]] || fail "Missing x86_64 slice: $binary"
  [[ ${#architecture_list[@]} -eq 2 ]] || fail "Unexpected slice in $binary: $architectures"
}

while IFS= read -r -d '' executable; do
  if /usr/bin/file "$executable" | /usr/bin/grep -q 'Mach-O'; then
    verify_universal_binary "$executable"
  fi
done < <(/usr/bin/find "$APP_PATH" -type f -perm -111 -print0)

APP_VERSION=$(/usr/libexec/PlistBuddy \
  -c "Print :CFBundleShortVersionString" \
  "$APP_PATH/Contents/Info.plist")
APP_BUILD=$(/usr/libexec/PlistBuddy \
  -c "Print :CFBundleVersion" \
  "$APP_PATH/Contents/Info.plist")
CLI_VERSION=$("$CLI_PATH" --version | /usr/bin/tr -d '[:space:]')
EXPECTED_CLI_VERSION="${APP_VERSION}(${APP_BUILD})"
[[ "$CLI_VERSION" == "$EXPECTED_CLI_VERSION" ]] \
  || fail "Version mismatch: App=${APP_VERSION} (${APP_BUILD}) CLI=$CLI_VERSION"

EXPECTED_CLI_HASH=$(/usr/libexec/PlistBuddy \
  -c "Print :ComputerMCPEmbeddedCLIHash" \
  "$APP_PATH/Contents/Info.plist")
ACTUAL_CLI_HASH=$(/usr/bin/shasum -a 256 "$CLI_PATH" | /usr/bin/awk '{print $1}')
[[ "$ACTUAL_CLI_HASH" == "$EXPECTED_CLI_HASH" ]] || fail "Embedded CLI hash mismatch."

IDENTITY_VERSION=$(/usr/bin/plutil -extract version raw -o - "$BUILD_IDENTITY")
IDENTITY_BUILD=$(/usr/bin/plutil -extract build raw -o - "$BUILD_IDENTITY")
IDENTITY_COMMIT=$(/usr/bin/plutil -extract source_commit raw -o - "$BUILD_IDENTITY")
IDENTITY_TEAM=$(/usr/bin/plutil -extract team_identifier raw -o - "$BUILD_IDENTITY")
IDENTITY_HASH=$(/usr/bin/plutil -extract embedded_cli_sha256 raw -o - "$BUILD_IDENTITY")
[[ "$IDENTITY_VERSION" == "$APP_VERSION" && "$IDENTITY_BUILD" == "$APP_BUILD" ]] \
  || fail "Build identity version does not match the App."
[[ "$IDENTITY_HASH" == "$ACTUAL_CLI_HASH" ]] \
  || fail "Build identity CLI hash does not match the embedded CLI."
[[ "$IDENTITY_COMMIT" =~ '^[0-9a-f]{40}$' ]] || fail "Build identity commit is invalid."

INFO_COMMIT=$(/usr/libexec/PlistBuddy -c "Print :ComputerMCPSourceCommit" \
  "$APP_PATH/Contents/Info.plist")
INFO_TEAM=$(/usr/libexec/PlistBuddy -c "Print :ComputerMCPTeamIdentifier" \
  "$APP_PATH/Contents/Info.plist")
[[ "$INFO_COMMIT" == "$IDENTITY_COMMIT" ]] || fail "App and CLI commit identity differ."
[[ "$INFO_TEAM" == "$IDENTITY_TEAM" ]] || fail "App and CLI Team identity differ."

"$CLI_PATH" build-info > "$BUILD_INFO_FILE"
BUILD_INFO_COMMIT=$(/usr/bin/plutil -extract source_commit raw -o - "$BUILD_INFO_FILE")
BUILD_INFO_TEAM=$(/usr/bin/plutil -extract team_identifier raw -o - "$BUILD_INFO_FILE")
BUILD_INFO_MATCH=$(/usr/bin/plutil -extract embedded_cli_digest_matches raw -o - \
  "$BUILD_INFO_FILE")
[[ "$BUILD_INFO_COMMIT" == "$IDENTITY_COMMIT" ]] \
  || fail "CLI build-info does not display the source commit."
[[ "$BUILD_INFO_TEAM" == "$IDENTITY_TEAM" ]] \
  || fail "CLI build-info does not display the Team ID."
[[ "$BUILD_INFO_MATCH" == "true" ]] \
  || fail "CLI build-info does not verify its own digest."

for file in \
  ThirdPartyNotices.txt \
  Computer-MCP-1.0.0-DependencyManifest.json \
  Computer-MCP-1.0.0-SBOM.cdx.json \
  ComputerMCPSourceVisibleLicense.txt \
  EULA.md \
  PRIVACY.md
do
  [[ -f "$MOUNT_DIR/$file" ]] || fail "Missing DMG legal/release file: $file"
done
/usr/bin/cmp -s \
  "$MOUNT_DIR/ThirdPartyNotices.txt" \
  "$APP_PATH/Contents/Resources/ThirdPartyNotices.txt" \
  || fail "App and DMG ThirdPartyNotices.txt are not byte-identical."

for relative_path in \
  "Contents/Info.plist" \
  "Contents/MacOS/Computer MCP" \
  "Contents/Resources/computer-mcp" \
  "Contents/Resources/ComputerMCPBuildIdentity.plist" \
  "Contents/Resources/ThirdPartyNotices.txt" \
  "Contents/_CodeSignature/CodeResources"
do
  /usr/bin/cmp -s \
    "$CURRENT_APP_PATH/$relative_path" \
    "$APP_PATH/$relative_path" \
    || fail "DMG does not contain the current App: $relative_path differs."
done

if [[ "$RELEASE_MODE" == "1" ]]; then
  [[ -n ${EXPECTED_TEAM_ID:-} ]] || fail "Release verification requires EXPECTED_TEAM_ID."
  for signed_path in "$CLI_PATH" "$APP_PATH"; do
    signature=$(/usr/bin/codesign -d --verbose=4 "$signed_path" 2>&1)
    [[ "$signature" == *"Authority=Developer ID Application:"* ]] \
      || fail "Missing Developer ID authority: $signed_path"
    [[ "$signature" == *"TeamIdentifier=$EXPECTED_TEAM_ID"* ]] \
      || fail "Unexpected Team ID: $signed_path"
    [[ "$signature" == *"Timestamp="* ]] || fail "Missing timestamp: $signed_path"
  done
  [[ "$IDENTITY_TEAM" == "$EXPECTED_TEAM_ID" ]] \
    || fail "Signed identity resource has the wrong Team ID."
  xcrun stapler validate "$APP_PATH"
  xcrun stapler validate "$DMG_PATH"
  /usr/sbin/spctl --assess --type execute --verbose=2 "$APP_PATH"
  /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 \
    "$DMG_PATH"
fi

echo "Distribution verification passed: $DMG_PATH"
echo "Source commit: $IDENTITY_COMMIT"
echo "Team identifier: $IDENTITY_TEAM"
echo "DMG SHA256: $ACTUAL_HASH"
