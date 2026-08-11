#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
CONFIGURATION=${CONFIGURATION:-release}
OUTPUT_DIR=${OUTPUT_DIR:-"$ROOT_DIR/dist"}
APP_PATH="$OUTPUT_DIR/Computer MCP.app"
CONTENTS="$APP_PATH/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
INFO_PLIST="$ROOT_DIR/Resources/ComputerMCPApp/Info.plist"
LOCALIZED_INFO_ROOT="$ROOT_DIR/Resources/ComputerMCPApp"
ENTITLEMENTS="$ROOT_DIR/Resources/ComputerMCPApp/ComputerMCP.entitlements"
RELEASE_MODE=${RELEASE_MODE:-0}
REUSE_EXISTING_SLICES=${REUSE_EXISTING_SLICES:-0}
BUILD_ROOT=${BUILD_ROOT:-"$OUTPUT_DIR/Build"}
ARM64_SCRATCH="$BUILD_ROOT/arm64"
X86_64_SCRATCH="$BUILD_ROOT/x86_64"
METADATA_DIR="$OUTPUT_DIR/ReleaseMetadata"
BUILD_IDENTITY="$RESOURCES_DIR/ComputerMCPBuildIdentity.plist"

fail() {
  echo "error: $1" >&2
  exit 1
}

if [[ "$RELEASE_MODE" != "0" && "$RELEASE_MODE" != "1" ]]; then
  fail "RELEASE_MODE must be 0 or 1."
fi
if [[ "$REUSE_EXISTING_SLICES" != "0" && "$REUSE_EXISTING_SLICES" != "1" ]]; then
  fail "REUSE_EXISTING_SLICES must be 0 or 1."
fi
if [[ "$RELEASE_MODE" == "1" ]]; then
  [[ "$REUSE_EXISTING_SLICES" == "0" ]] \
    || fail "Release mode cannot reuse existing architecture slices."
  [[ -n ${SIGNING_IDENTITY:-} ]] || fail "Release mode requires SIGNING_IDENTITY."
  [[ "$SIGNING_IDENTITY" == Developer\ ID\ Application:* ]] \
    || fail "Release mode requires a Developer ID Application identity."
  [[ -n ${EXPECTED_TEAM_ID:-} ]] || fail "Release mode requires EXPECTED_TEAM_ID."
  [[ -n ${NOTARY_KEYCHAIN_PROFILE:-} ]] \
    || fail "Release mode requires NOTARY_KEYCHAIN_PROFILE."
  [[ -z $(git -C "$ROOT_DIR" status --porcelain) ]] \
    || fail "Release mode requires a clean Git worktree."
  if rg -q -i \
    'release-candidate legal draft|legal review (is|are )?required before publication' \
    "$ROOT_DIR/LICENSE" "$ROOT_DIR/EULA.md" "$ROOT_DIR/PRIVACY.md"
  then
    fail "Release mode requires approved legal files without draft markers."
  fi
fi

"$ROOT_DIR/Scripts/verify-localization.sh"

APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")
APP_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")
SOURCE_VERSION=$(/usr/bin/sed -n \
  's/^[[:space:]]*package static let version = "\([^"]*\)"[[:space:]]*$/\1/p' \
  "$ROOT_DIR/Sources/ComputerMCP/ComputerMCPCLI.swift")
SOURCE_BUILD=$(/usr/bin/sed -n \
  's/^[[:space:]]*package static let build = "\([^"]*\)"[[:space:]]*$/\1/p' \
  "$ROOT_DIR/Sources/ComputerMCP/ComputerMCPCLI.swift")
if [[ -z "$SOURCE_VERSION" || -z "$SOURCE_BUILD" \
  || "$SOURCE_VERSION" != "$APP_VERSION" || "$SOURCE_BUILD" != "$APP_BUILD" ]]
then
  fail "Release metadata mismatch: source=${SOURCE_VERSION:-missing} (${SOURCE_BUILD:-missing}) App=$APP_VERSION ($APP_BUILD)"
fi

SOURCE_COMMIT=${SOURCE_COMMIT:-$(git -C "$ROOT_DIR" rev-parse HEAD)}
[[ "$SOURCE_COMMIT" =~ '^[0-9a-f]{40}$' ]] || fail "Unable to resolve the source commit."

SWIFT_EXECUTABLE=${SWIFT_EXECUTABLE:-"$(xcrun --find swift)"}
SWIFT_BUILD_SYSTEM=${SWIFT_BUILD_SYSTEM:-native}
SWIFT_BUILD_ARGUMENTS=(
  --build-system "$SWIFT_BUILD_SYSTEM"
  --package-path "$ROOT_DIR"
  --configuration "$CONFIGURATION"
  --only-use-versions-from-resolved-file
)

"$SWIFT_EXECUTABLE" --version
"$SWIFT_EXECUTABLE" package \
  --package-path "$ROOT_DIR" \
  --only-use-versions-from-resolved-file \
  resolve

prepare_slice_scratch() {
  local scratch=$1
  /bin/mkdir -p "$scratch"
  for shared_directory in checkouts repositories; do
    local shared_path="$ROOT_DIR/.build/$shared_directory"
    local slice_path="$scratch/$shared_directory"
    [[ -d "$shared_path" ]] || fail "Missing resolved SwiftPM $shared_directory directory."
    if [[ ! -e "$slice_path" ]]; then
      /bin/ln -s "$shared_path" "$slice_path"
    fi
  done
}

prepare_slice_scratch "$ARM64_SCRATCH"
prepare_slice_scratch "$X86_64_SCRATCH"

build_slice() {
  local triple=$1
  local scratch=$2
  "$SWIFT_EXECUTABLE" build \
    "${SWIFT_BUILD_ARGUMENTS[@]}" \
    --scratch-path "$scratch" \
    --triple "$triple"
}

if [[ "$REUSE_EXISTING_SLICES" == "0" ]]; then
  build_slice "arm64-apple-macosx14.0" "$ARM64_SCRATCH"
  build_slice "x86_64-apple-macosx14.0" "$X86_64_SCRATCH"
fi

ARM64_BIN_DIR=$("$SWIFT_EXECUTABLE" build \
  "${SWIFT_BUILD_ARGUMENTS[@]}" \
  --scratch-path "$ARM64_SCRATCH" \
  --triple "arm64-apple-macosx14.0" \
  --show-bin-path)
X86_64_BIN_DIR=$("$SWIFT_EXECUTABLE" build \
  "${SWIFT_BUILD_ARGUMENTS[@]}" \
  --scratch-path "$X86_64_SCRATCH" \
  --triple "x86_64-apple-macosx14.0" \
  --show-bin-path)

for binary in \
  "$ARM64_BIN_DIR/ComputerMCPApp" \
  "$ARM64_BIN_DIR/computer-mcp" \
  "$X86_64_BIN_DIR/ComputerMCPApp" \
  "$X86_64_BIN_DIR/computer-mcp"
do
  [[ -x "$binary" ]] || fail "Missing architecture slice: $binary"
done

if [[ -e "$APP_PATH" ]]; then
  /bin/rm -rf -- "$APP_PATH"
fi
/bin/mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$METADATA_DIR"
/usr/bin/lipo -create \
  "$ARM64_BIN_DIR/ComputerMCPApp" \
  "$X86_64_BIN_DIR/ComputerMCPApp" \
  -output "$MACOS_DIR/Computer MCP"
/usr/bin/lipo -create \
  "$ARM64_BIN_DIR/computer-mcp" \
  "$X86_64_BIN_DIR/computer-mcp" \
  -output "$RESOURCES_DIR/computer-mcp"
/bin/cp "$INFO_PLIST" "$CONTENTS/Info.plist"
/bin/chmod 755 "$MACOS_DIR/Computer MCP" "$RESOURCES_DIR/computer-mcp"

APP_RESOURCE_BUNDLE=$(/usr/bin/find "$ARM64_BIN_DIR" -maxdepth 1 -type d \
  -name '*ComputerMCPApp*.bundle' -print -quit)
[[ -n "$APP_RESOURCE_BUNDLE" && -d "$APP_RESOURCE_BUNDLE" ]] \
  || fail "Missing ComputerMCPApp SwiftPM resource bundle."
/usr/bin/ditto "$APP_RESOURCE_BUNDLE" "$RESOURCES_DIR/${APP_RESOURCE_BUNDLE:t}"
LOCALIZATION_BUNDLE="$RESOURCES_DIR/${APP_RESOURCE_BUNDLE:t}"
xcrun xcstringstool compile \
  "$ROOT_DIR/Sources/ComputerMCPApp/Resources/Localizable.xcstrings" \
  --output-directory "$LOCALIZATION_BUNDLE" \
  --serialization-format binary
/bin/rm -f -- "$LOCALIZATION_BUNDLE/Localizable.xcstrings"

for locale in en zh-Hans; do
  localized_info="$LOCALIZED_INFO_ROOT/$locale.lproj/InfoPlist.strings"
  [[ -f "$localized_info" ]] || fail "Missing $locale InfoPlist.strings."
  /bin/mkdir -p "$RESOURCES_DIR/$locale.lproj"
  /bin/cp "$localized_info" "$RESOURCES_DIR/$locale.lproj/InfoPlist.strings"
  /usr/bin/plutil -lint "$RESOURCES_DIR/$locale.lproj/InfoPlist.strings" >/dev/null
done

for locale in en zh-Hans; do
  [[ -f "$LOCALIZATION_BUNDLE/$locale.lproj/Localizable.strings" ]] \
    || fail "Missing compiled $locale Localizable.strings in the App resource bundle."
  /bin/cp "$LOCALIZATION_BUNDLE/$locale.lproj/Localizable.strings" \
    "$RESOURCES_DIR/$locale.lproj/Localizable.strings"
done

verify_universal_binary() {
  local binary=$1
  local architectures
  local -a architecture_list
  architectures=$(/usr/bin/lipo -archs "$binary")
  architecture_list=(${=architectures})
  [[ " $architectures " == *" arm64 "* ]] \
    || fail "Missing arm64 slice: $binary ($architectures)"
  [[ " $architectures " == *" x86_64 "* ]] \
    || fail "Missing x86_64 slice: $binary ($architectures)"
  [[ ${#architecture_list[@]} -eq 2 ]] \
    || fail "Unexpected architecture slice: $binary ($architectures)"
}

verify_universal_binary "$MACOS_DIR/Computer MCP"
verify_universal_binary "$RESOURCES_DIR/computer-mcp"

DESCRIPTION_PATH="$ARM64_BIN_DIR/description.json"
[[ -f "$DESCRIPTION_PATH" ]] || fail "Missing SwiftPM build description: $DESCRIPTION_PATH"
xcrun swift "$ROOT_DIR/Scripts/generate-release-metadata.swift" \
  --root "$ROOT_DIR" \
  --output "$METADATA_DIR" \
  --build-description "$DESCRIPTION_PATH" \
  --checkout-root "$ARM64_SCRATCH/checkouts"

/bin/cp "$METADATA_DIR/ThirdPartyNotices.txt" "$RESOURCES_DIR/ThirdPartyNotices.txt"
/bin/cp "$ROOT_DIR/LICENSE" "$RESOURCES_DIR/ComputerMCPSourceVisibleLicense.txt"
/bin/cp "$ROOT_DIR/EULA.md" "$RESOURCES_DIR/EULA.md"
/bin/cp "$ROOT_DIR/PRIVACY.md" "$RESOURCES_DIR/PRIVACY.md"
/usr/bin/plutil -lint "$CONTENTS/Info.plist" >/dev/null

sign_binary() {
  local path=$1
  local entitlements=${2:-}
  if [[ -n ${SIGNING_IDENTITY:-} ]]; then
    local arguments=(
      --force
      --options runtime
      --timestamp
    )
    if [[ -n "$entitlements" ]]; then
      arguments+=(--entitlements "$entitlements")
    fi
    arguments+=(--sign "$SIGNING_IDENTITY" "$path")
    /usr/bin/codesign "${arguments[@]}"
  else
    local arguments=(--force --options runtime)
    if [[ -n "$entitlements" ]]; then
      arguments+=(--entitlements "$entitlements")
    fi
    arguments+=(--sign - "$path")
    /usr/bin/codesign "${arguments[@]}"
  fi
}

sign_binary "$RESOURCES_DIR/computer-mcp"
CLI_HASH=$(/usr/bin/shasum -a 256 "$RESOURCES_DIR/computer-mcp" | /usr/bin/awk '{print $1}')
ACTUAL_TEAM_ID=$(/usr/bin/codesign -d --verbose=4 "$RESOURCES_DIR/computer-mcp" 2>&1 \
  | /usr/bin/sed -n 's/^TeamIdentifier=//p')
if [[ -z "$ACTUAL_TEAM_ID" || "$ACTUAL_TEAM_ID" == "not set" ]]; then
  ACTUAL_TEAM_ID="adhoc"
fi
if [[ "$RELEASE_MODE" == "1" && "$ACTUAL_TEAM_ID" != "$EXPECTED_TEAM_ID" ]]; then
  fail "Embedded CLI Team ID mismatch: expected=$EXPECTED_TEAM_ID actual=$ACTUAL_TEAM_ID"
fi

/usr/bin/plutil -create xml1 "$BUILD_IDENTITY"
/usr/bin/plutil -insert schema_version -integer 1 "$BUILD_IDENTITY"
/usr/bin/plutil -insert version -string "$APP_VERSION" "$BUILD_IDENTITY"
/usr/bin/plutil -insert build -string "$APP_BUILD" "$BUILD_IDENTITY"
/usr/bin/plutil -insert source_commit -string "$SOURCE_COMMIT" "$BUILD_IDENTITY"
/usr/bin/plutil -insert team_identifier -string "$ACTUAL_TEAM_ID" "$BUILD_IDENTITY"
/usr/bin/plutil -insert embedded_cli_sha256 -string "$CLI_HASH" "$BUILD_IDENTITY"
/usr/bin/plutil -insert architectures -json '["arm64","x86_64"]' "$BUILD_IDENTITY"

/usr/libexec/PlistBuddy -c "Add :ComputerMCPEmbeddedCLIHash string $CLI_HASH" \
  "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Add :ComputerMCPSourceCommit string $SOURCE_COMMIT" \
  "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Add :ComputerMCPTeamIdentifier string $ACTUAL_TEAM_ID" \
  "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Add :ComputerMCPArchitectures string arm64,x86_64" \
  "$CONTENTS/Info.plist"

sign_binary "$APP_PATH" "$ENTITLEMENTS"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

APP_TEAM_ID=$(/usr/bin/codesign -d --verbose=4 "$APP_PATH" 2>&1 \
  | /usr/bin/sed -n 's/^TeamIdentifier=//p')
if [[ -z "$APP_TEAM_ID" || "$APP_TEAM_ID" == "not set" ]]; then
  APP_TEAM_ID="adhoc"
fi
[[ "$APP_TEAM_ID" == "$ACTUAL_TEAM_ID" ]] \
  || fail "App and embedded CLI Team IDs differ: App=$APP_TEAM_ID CLI=$ACTUAL_TEAM_ID"

while IFS= read -r -d '' executable; do
  if /usr/bin/file "$executable" | /usr/bin/grep -q 'Mach-O'; then
    verify_universal_binary "$executable"
  fi
done < <(/usr/bin/find "$APP_PATH" -type f -perm -111 -print0)

if [[ "$RELEASE_MODE" == "1" ]]; then
  for signed_path in "$RESOURCES_DIR/computer-mcp" "$APP_PATH"; do
    signature=$(/usr/bin/codesign -d --verbose=4 "$signed_path" 2>&1)
    [[ "$signature" == *"Authority=Developer ID Application:"* ]] \
      || fail "Missing Developer ID Application authority: $signed_path"
    [[ "$signature" == *"TeamIdentifier=$EXPECTED_TEAM_ID"* ]] \
      || fail "Missing expected Team ID: $signed_path"
    [[ "$signature" == *"Timestamp="* ]] \
      || fail "Missing secure timestamp: $signed_path"
  done
  echo "Built Developer ID signed Universal 2 app: $APP_PATH"
else
  echo "Built development Universal 2 app: $APP_PATH"
  echo "Set RELEASE_MODE=1 with Developer ID and notarization variables for release."
fi

echo "Source commit: $SOURCE_COMMIT"
echo "Team identifier: $APP_TEAM_ID"
echo "Embedded CLI SHA256: $CLI_HASH"
