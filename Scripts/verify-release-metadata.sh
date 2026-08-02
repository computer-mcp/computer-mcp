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
/usr/bin/swift build --build-system native
BIN_DIR=$(/usr/bin/swift build --build-system native --show-bin-path)
DESCRIPTION_PATH="$BIN_DIR/description.json"
[[ -f "$DESCRIPTION_PATH" ]] || fail "Missing SwiftPM build description."

for output in "$FIRST_OUTPUT" "$SECOND_OUTPUT"; do
  xcrun swift Scripts/generate-release-metadata.swift \
    --root "$ROOT_DIR" \
    --output "$output" \
    --build-description "$DESCRIPTION_PATH" \
    --checkout-root "$ROOT_DIR/.build/checkouts"
done

/usr/bin/diff -qr "$FIRST_OUTPUT" "$SECOND_OUTPUT" >/dev/null \
  || fail "Two consecutive generations were not byte-identical."

MANIFEST="$FIRST_OUTPUT/Computer-MCP-1.0.0-DependencyManifest.json"
SBOM="$FIRST_OUTPUT/Computer-MCP-1.0.0-SBOM.cdx.json"
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
[[ $(/usr/bin/plutil -extract bomFormat raw -o - "$SBOM") == "CycloneDX" ]] \
  || fail "SBOM format is not CycloneDX."
[[ $(/usr/bin/plutil -extract specVersion raw -o - "$SBOM") == "1.6" ]] \
  || fail "SBOM spec version is not 1.6."

for legal_file in LICENSE EULA.md PRIVACY.md THIRD_PARTY_NOTICES.md; do
  [[ -s "$legal_file" ]] || fail "Missing release legal file: $legal_file"
done

echo "Deterministic release metadata gate passed (13 linked, 28 resolved-only, 41 total)."
