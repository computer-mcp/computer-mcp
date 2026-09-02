#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
OUTPUT_DIR=${OUTPUT_DIR:-"$ROOT_DIR/dist"}
PRODUCT_VERSION=$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleShortVersionString' \
  "$ROOT_DIR/Resources/ComputerMCPApp/Info.plist")
RELEASE_MODE=${RELEASE_MODE:-0}
DMG_PATH=${DMG_PATH:-}
CURRENT_APP_PATH=${CURRENT_APP_PATH:-"$OUTPUT_DIR/Computer MCP.app"}
CHECKSUM_PATH=${CHECKSUM_PATH:-"$OUTPUT_DIR/SHA256SUMS"}
MOUNT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/computer-mcp-mount.XXXXXX")
BUILD_INFO_FILE=$(mktemp "${TMPDIR:-/tmp}/computer-mcp-build-info.XXXXXX")
SIGNED_ENTITLEMENTS=$(mktemp "${TMPDIR:-/tmp}/computer-mcp-entitlements.XXXXXX")
DECODED_PROFILE=$(mktemp "${TMPDIR:-/tmp}/computer-mcp-profile.XXXXXX")
MOUNT_DEVICE=""

cleanup() {
  if [[ -n "$MOUNT_DEVICE" ]]; then
    /usr/sbin/diskutil eject "$MOUNT_DEVICE" >/dev/null 2>&1 || true
  fi
  /bin/rmdir "$MOUNT_DIR" 2>/dev/null || true
  /bin/rm -f -- "$BUILD_INFO_FILE" "$SIGNED_ENTITLEMENTS" "$DECODED_PROFILE"
}
trap cleanup EXIT

fail() {
  echo "error: $1" >&2
  exit 1
}

if [[ -z "$DMG_PATH" ]]; then
  if [[ "$RELEASE_MODE" == "1" ]]; then
    DMG_PATH="$OUTPUT_DIR/Computer-MCP-$PRODUCT_VERSION-universal.dmg"
  else
    typeset -a local_artifacts=(
      "$OUTPUT_DIR"/Computer-MCP-"$PRODUCT_VERSION"-development-*-universal.dmg(N)
      "$OUTPUT_DIR"/Computer-MCP-"$PRODUCT_VERSION"-validation-*-universal.dmg(N)
    )
    [[ ${#local_artifacts[@]} == 1 ]] \
      || fail "Specify DMG_PATH when zero or multiple local development/validation artifacts exist."
    DMG_PATH=${local_artifacts[1]}
  fi
fi
PROVENANCE_PATH=${PROVENANCE_PATH:-"${DMG_PATH:r}-ArtifactProvenance.json"}

identifier_is_authorized() {
  local authorized=$1
  local requested=$2
  if [[ "$authorized" == *"*" ]]; then
    [[ "$requested" == "${authorized%\*}"* ]]
  else
    [[ "$requested" == "$authorized" ]]
  fi
}

[[ -f "$DMG_PATH" ]] || fail "Missing DMG: $DMG_PATH"
[[ -d "$CURRENT_APP_PATH" ]] || fail "Missing current app bundle: $CURRENT_APP_PATH"
[[ -f "$CHECKSUM_PATH" ]] || fail "Missing SHA256SUMS: $CHECKSUM_PATH"
[[ -f "$PROVENANCE_PATH" ]] || fail "Missing artifact provenance: $PROVENANCE_PATH"
ARTIFACT_CLASS=$(/usr/bin/jq -er '.artifact.class' "$PROVENANCE_PATH")
if [[ "$RELEASE_MODE" == "1" ]]; then
  [[ "$ARTIFACT_CLASS" == release_candidate ]] \
    || fail "Release verification requires a release_candidate provenance receipt."
else
  [[ "$ARTIFACT_CLASS" == development || "$ARTIFACT_CLASS" == validation ]] \
    || fail "Local verification requires development or validation provenance."
fi
EXPECTED_HASH=$(/usr/bin/awk -v name="${DMG_PATH:t}" '$2 == name { print $1 }' "$CHECKSUM_PATH")
ACTUAL_HASH=$(/usr/bin/shasum -a 256 "$DMG_PATH" | /usr/bin/awk '{print $1}')
[[ -n "$EXPECTED_HASH" && "$EXPECTED_HASH" == "$ACTUAL_HASH" ]] \
  || fail "DMG SHA-256 does not match SHA256SUMS."

ATTACH_PLIST=$(/usr/sbin/diskutil image --plist attach \
  --readOnly \
  --nobrowse \
  --mountPoint "$MOUNT_DIR" \
  "$DMG_PATH")
ATTACH_JSON=$(printf '%s' "$ATTACH_PLIST" | /usr/bin/plutil -convert json -o - -)
MOUNT_DEVICE=$(printf '%s' "$ATTACH_JSON" \
  | /usr/bin/jq -r '."system-entities"[0]."dev-entry" // empty')
ACTUAL_MOUNT=$(printf '%s' "$ATTACH_JSON" \
  | /usr/bin/jq -r '[."system-entities"[] | ."mount-point" // empty][0]')
VOLUME_NAME=$(printf '%s' "$ATTACH_JSON" \
  | /usr/bin/jq -r '[."system-entities"[] | ."volume-name" // empty][0]')
[[ -n "$MOUNT_DEVICE" ]] || fail "diskutil did not return an attached image device."
[[ ${ACTUAL_MOUNT:A} == ${MOUNT_DIR:A} ]] || fail "DMG mounted at an unexpected path."
[[ "$VOLUME_NAME" == "Computer MCP $PRODUCT_VERSION" ]] \
  || fail "DMG volume name is incorrect."
APP_PATH="$MOUNT_DIR/Computer MCP.app"
CLI_PATH="$APP_PATH/Contents/Resources/computer-mcp"
BUILD_IDENTITY="$APP_PATH/Contents/Resources/ComputerMCPBuildIdentity.plist"

[[ -x "$APP_PATH/Contents/MacOS/Computer MCP" ]] || fail "Missing App executable."
[[ -x "$CLI_PATH" ]] || fail "Missing embedded CLI."
[[ -f "$BUILD_IDENTITY" ]] || fail "Missing signed build identity."
BUILD_IDENTITY_PATH="$BUILD_IDENTITY" \
  "$ROOT_DIR/Scripts/verify-artifact-provenance.sh" \
    "$PROVENANCE_PATH" "$DMG_PATH" "$ARTIFACT_CLASS"
APP_RESOURCE_BUNDLE=$(/usr/bin/find "$APP_PATH/Contents/Resources" -maxdepth 1 \
  -type d -name '*ComputerMCPApp*.bundle' -print -quit)
[[ -n "$APP_RESOURCE_BUNDLE" ]] || fail "Missing ComputerMCPApp localization bundle."
for locale in en zh-Hans; do
  [[ -f "$APP_RESOURCE_BUNDLE/$locale.lproj/Localizable.strings" ]] \
    || fail "Missing $locale Localizable.strings."
  [[ -f "$APP_PATH/Contents/Resources/$locale.lproj/Localizable.strings" ]] \
    || fail "Missing main-bundle $locale Localizable.strings."
  [[ -f "$APP_PATH/Contents/Resources/$locale.lproj/InfoPlist.strings" ]] \
    || fail "Missing $locale InfoPlist.strings."
done
/usr/bin/plutil -lint "$APP_PATH/Contents/Info.plist" >/dev/null
/usr/bin/plutil -lint "$BUILD_IDENTITY" >/dev/null
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

APP_ENVIRONMENT=$(/usr/bin/plutil -extract ComputerMCPEnvironment raw -o - \
  "$APP_PATH/Contents/Info.plist" 2>/dev/null) \
  || fail "The App does not declare a distribution environment."
APP_BUNDLE_ID=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - \
  "$APP_PATH/Contents/Info.plist")
[[ "$APP_ENVIRONMENT" == "production" ]] \
  || fail "The distribution must contain the production App environment."
[[ "$APP_BUNDLE_ID" == "com.showxu.computer-mcp" ]] \
  || fail "The distribution has the wrong production Bundle ID."
DMG_SIGNING_IDENTIFIER="$APP_BUNDLE_ID.dmg"

APP_SIGNATURE=$(/usr/bin/codesign -d --verbose=4 "$APP_PATH" 2>&1)
APP_TEAM=$(print -r -- "$APP_SIGNATURE" | /usr/bin/sed -n 's/^TeamIdentifier=//p')
if [[ -z "$APP_TEAM" || "$APP_TEAM" == "not set" ]]; then
  APP_TEAM="adhoc"
fi
INFO_TEAM=$(/usr/bin/plutil -extract ComputerMCPTeamIdentifier raw -o - \
  "$APP_PATH/Contents/Info.plist")
[[ "$INFO_TEAM" == "$APP_TEAM" ]] \
  || fail "Info.plist and code signature Team identifiers differ."

if [[ "$APP_TEAM" != "adhoc" ]]; then
  EMBEDDED_PROFILE="$APP_PATH/Contents/embedded.provisionprofile"
  [[ -f "$EMBEDDED_PROFILE" ]] \
    || fail "A provisioned App is missing embedded.provisionprofile."
  /usr/bin/codesign -d --entitlements :- "$APP_PATH" >"$SIGNED_ENTITLEMENTS" 2>/dev/null
  EXPECTED_APPLICATION_IDENTIFIER="$APP_TEAM.$APP_BUNDLE_ID"
  SIGNED_APPLICATION_IDENTIFIER=$(/usr/bin/plutil \
    -extract 'com\.apple\.application-identifier' raw -o - "$SIGNED_ENTITLEMENTS")
  SIGNED_GROUPS=$(/usr/bin/plutil -extract keychain-access-groups json -o - \
    "$SIGNED_ENTITLEMENTS")
  [[ "$SIGNED_APPLICATION_IDENTIFIER" == "$EXPECTED_APPLICATION_IDENTIFIER" ]] \
    || fail "The signed application identifier is incorrect."
  [[ $(print -r -- "$SIGNED_GROUPS" | /usr/bin/jq 'length') == "1" ]] \
    || fail "The App must have exactly one private Keychain access group."
  [[ $(print -r -- "$SIGNED_GROUPS" | /usr/bin/jq -r '.[0]') \
    == "$EXPECTED_APPLICATION_IDENTIFIER" ]] \
    || fail "The signed private Keychain access group is incorrect."

  /usr/bin/security cms -D -i "$EMBEDDED_PROFILE" >"$DECODED_PROFILE"
  PROFILE_EXPIRATION=$(/usr/bin/plutil -extract ExpirationDate raw -o - \
    "$DECODED_PROFILE")
  PROFILE_EXPIRATION_EPOCH=$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' \
    "$PROFILE_EXPIRATION" '+%s') \
    || fail "The embedded provisioning profile expiration is invalid."
  [[ "$PROFILE_EXPIRATION_EPOCH" -gt $(/bin/date -u '+%s') ]] \
    || fail "The embedded provisioning profile has expired."
  PROFILE_TEAM=$(/usr/bin/plutil \
    -extract 'Entitlements.com\.apple\.developer\.team-identifier' raw -o - \
    "$DECODED_PROFILE")
  PROFILE_APPLICATION_IDENTIFIER=$(/usr/bin/plutil \
    -extract 'Entitlements.com\.apple\.application-identifier' raw -o - \
    "$DECODED_PROFILE")
  [[ "$PROFILE_TEAM" == "$APP_TEAM" ]] \
    || fail "The embedded provisioning profile has the wrong Team ID."
  identifier_is_authorized \
    "$PROFILE_APPLICATION_IDENTIFIER" \
    "$EXPECTED_APPLICATION_IDENTIFIER" \
    || fail "The embedded provisioning profile does not authorize the App ID."
  PROFILE_GROUP_AUTHORIZED=0
  while IFS= read -r authorized_group; do
    if identifier_is_authorized "$authorized_group" "$EXPECTED_APPLICATION_IDENTIFIER"; then
      PROFILE_GROUP_AUTHORIZED=1
      break
    fi
  done < <(
    /usr/bin/plutil -extract Entitlements.keychain-access-groups json -o - \
      "$DECODED_PROFILE" | /usr/bin/jq -r '.[]'
  )
  [[ "$PROFILE_GROUP_AUTHORIZED" == "1" ]] \
    || fail "The embedded provisioning profile does not authorize the Keychain group."
else
  [[ ! -e "$APP_PATH/Contents/embedded.provisionprofile" ]] \
    || fail "An ad-hoc App must not embed a provisioning profile."
fi

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
[[ "$APP_VERSION" == "$PRODUCT_VERSION" ]] \
  || fail "The DMG App version does not match the repository release version."
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
  "Computer-MCP-$APP_VERSION-DependencyManifest.json" \
  "Computer-MCP-$APP_VERSION-SBOM.cdx.json" \
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
if [[ -f "$CURRENT_APP_PATH/Contents/embedded.provisionprofile" \
  || -f "$APP_PATH/Contents/embedded.provisionprofile" ]]
then
  [[ -f "$CURRENT_APP_PATH/Contents/embedded.provisionprofile" \
    && -f "$APP_PATH/Contents/embedded.provisionprofile" ]] \
    || fail "Current App and DMG provisioning profile presence differs."
  /usr/bin/cmp -s \
    "$CURRENT_APP_PATH/Contents/embedded.provisionprofile" \
    "$APP_PATH/Contents/embedded.provisionprofile" \
    || fail "DMG does not contain the current provisioning profile."
fi

if [[ "$RELEASE_MODE" == "1" ]]; then
  [[ -n ${EXPECTED_TEAM_ID:-} ]] || fail "Release verification requires EXPECTED_TEAM_ID."
  for signed_path in "$CLI_PATH" "$APP_PATH"; do
    signature=$(/usr/bin/codesign -d --verbose=4 "$signed_path" 2>&1)
    print -r -- "$signature" \
      | "$ROOT_DIR/Scripts/verify-developer-id-signature-record.sh" \
        "$EXPECTED_TEAM_ID" "$signed_path"
  done
  /usr/bin/codesign --verify --strict --verbose=2 "$DMG_PATH"
  DMG_SIGNATURE=$(/usr/bin/codesign -d --verbose=4 "$DMG_PATH" 2>&1)
  print -r -- "$DMG_SIGNATURE" \
    | "$ROOT_DIR/Scripts/verify-developer-id-signature-record.sh" \
      "$EXPECTED_TEAM_ID" "DMG" "$DMG_SIGNING_IDENTIFIER"
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
