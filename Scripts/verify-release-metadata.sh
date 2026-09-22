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
python3 Scripts/version.py check
PRODUCT_VERSION=$(python3 Scripts/version.py show --field version)
PRODUCT_BUILD=$(python3 Scripts/version.py show --field build)
/usr/bin/swift build
BUILD_BIN_DIR=$(/usr/bin/swift build --show-bin-path)
if [[ -f "$ROOT_DIR/.build/manifest.pif" ]]; then
  BUILD_GRAPH="$ROOT_DIR/.build/manifest.pif"
elif [[ -f "$BUILD_BIN_DIR/description.json" ]]; then
  BUILD_GRAPH="$BUILD_BIN_DIR/description.json"
else
  fail "Missing SwiftPM build graph for the default build engine."
fi

for output in "$FIRST_OUTPUT" "$SECOND_OUTPUT"; do
  xcrun swift Scripts/generate-release-metadata.swift \
    --root "$ROOT_DIR" \
    --output "$output" \
    --build-graph "$BUILD_GRAPH" \
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

PIN_COUNT=$(jq '.pins | length' Package.resolved)
LINKED_COUNT=$(jq '.linked_distributed | length' "$MANIFEST")
RESOLVED_ONLY_COUNT=$(jq '.resolved_only | length' "$MANIFEST")
SBOM_COMPONENT_COUNT=$(jq '[.components[] | select(.type == "library")] | length' "$SBOM")

(( LINKED_COUNT > 0 )) || fail "No linked dependencies were classified."
(( LINKED_COUNT + RESOLVED_ONLY_COUNT == PIN_COUNT )) \
  || fail "Linked and resolved-only classifications do not partition Package.resolved."
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

echo "Deterministic release metadata gate passed ($LINKED_COUNT linked, $RESOLVED_ONLY_COUNT resolved-only, $PIN_COUNT total)."
