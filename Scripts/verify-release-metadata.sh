#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
TEMP_PARENT=${TMPDIR:-/tmp}
TEMP_PARENT=${TEMP_PARENT%/}
TEMP_ROOT=$(mktemp -d "$TEMP_PARENT/computer-mcp-release-metadata.XXXXXX")
FIRST_OUTPUT="$TEMP_ROOT/first"
SECOND_OUTPUT="$TEMP_ROOT/second"

cleanup() {
  case "$TEMP_ROOT" in
    "$TEMP_PARENT"/computer-mcp-release-metadata.*)
      /bin/rm -rf -- "$TEMP_ROOT"
      ;;
  esac
}
trap cleanup EXIT

fail() {
  echo "Release metadata verification failed: $1" >&2
  exit 1
}

cd "$ROOT_DIR"
Scripts/verify-swift-codex-release-gate.sh
PRODUCT_VERSION=$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleShortVersionString' \
  Resources/ComputerMCPApp/Info.plist)
PRODUCT_BUILD=$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleVersion' \
  Resources/ComputerMCPApp/Info.plist)
/usr/bin/swift build
BUILD_GRAPH="$ROOT_DIR/.build/manifest.pif"
[[ -f "$BUILD_GRAPH" ]] || fail "Missing SwiftPM build graph."

for output in "$FIRST_OUTPUT" "$SECOND_OUTPUT"; do
  xcrun swift Scripts/generate-release-metadata.swift \
    --root "$ROOT_DIR" \
    --output "$output" \
    --build-description "$BUILD_GRAPH" \
    --checkout-root "$ROOT_DIR/.build/checkouts" \
    --product-version "$PRODUCT_VERSION" \
    --product-build "$PRODUCT_BUILD"
done

/usr/bin/diff -qr "$FIRST_OUTPUT" "$SECOND_OUTPUT" >/dev/null \
  || fail "Two consecutive generations were not byte-identical."

MANIFEST="$FIRST_OUTPUT/Computer-MCP-$PRODUCT_VERSION-DependencyManifest.json"
SBOM="$FIRST_OUTPUT/Computer-MCP-$PRODUCT_VERSION-SBOM.cdx.json"
NOTICES="$FIRST_OUTPUT/ThirdPartyNotices.txt"
for file in "$MANIFEST" "$SBOM" "$NOTICES"; do
  [[ -s "$file" ]] || fail "Missing or empty generated file: ${file:t}"
done

PIN_COUNT=$(
  /usr/bin/plutil -extract pins json -o - Package.resolved \
    | rg -o '"identity"' \
    | /usr/bin/wc -l \
    | /usr/bin/awk '{print $1}'
)
LINKED_COUNT=$(
  /usr/bin/plutil -extract linked_distributed json -o - "$MANIFEST" \
    | rg -o '"identity"' \
    | /usr/bin/wc -l \
    | /usr/bin/awk '{print $1}'
)
RESOLVED_ONLY_COUNT=$(
  /usr/bin/plutil -extract resolved_only json -o - "$MANIFEST" \
    | rg -o '"identity"' \
    | /usr/bin/wc -l \
    | /usr/bin/awk '{print $1}'
)
SBOM_COMPONENT_COUNT=$(
  /usr/bin/plutil -extract components json -o - "$SBOM" \
    | rg -o '"type":"library"' \
    | /usr/bin/wc -l \
    | /usr/bin/awk '{print $1}'
)

[[ "$PIN_COUNT" == "41" ]] || fail "Expected 41 locked dependencies; found $PIN_COUNT."
[[ "$LINKED_COUNT" == "13" ]] \
  || fail "Expected 13 linked-and-distributed dependencies; found $LINKED_COUNT."
[[ "$RESOLVED_ONLY_COUNT" == "28" ]] \
  || fail "Expected 28 resolved-only dependencies; found $RESOLVED_ONLY_COUNT."
[[ "$SBOM_COMPONENT_COUNT" == "$PIN_COUNT" ]] \
  || fail "SBOM component count does not match Package.resolved."
[[ $(/usr/bin/plutil -extract schema_version raw -o - "$MANIFEST") == "1" ]] \
  || fail "Dependency manifest schema_version is not 1."
[[ $(/usr/bin/plutil -extract product.version raw -o - "$MANIFEST") \
  == "$PRODUCT_VERSION" ]] || fail "Dependency manifest product version is incorrect."
[[ $(/usr/bin/plutil -extract product.build raw -o - "$MANIFEST") \
  == "$PRODUCT_BUILD" ]] || fail "Dependency manifest product build is incorrect."
[[ $(/usr/bin/plutil -extract bomFormat raw -o - "$SBOM") == "CycloneDX" ]] \
  || fail "SBOM format is not CycloneDX."
[[ $(/usr/bin/plutil -extract specVersion raw -o - "$SBOM") == "1.6" ]] \
  || fail "SBOM spec version is not 1.6."

for legal_file in LICENSE EULA.md PRIVACY.md THIRD_PARTY_NOTICES.md; do
  [[ -s "$legal_file" ]] || fail "Missing release legal file: $legal_file"
done

echo "Deterministic release metadata gate passed (13 linked, 28 resolved-only, 41 total)."
