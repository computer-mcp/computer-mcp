#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/computer-mcp-release-asset-boundary.XXXXXX")
VERIFIER="$ROOT_DIR/Scripts/verify-release-asset-boundary.sh"
SOURCE="$ROOT_DIR/Scripts/assemble-release-assets.sh"

cleanup() {
  /bin/rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "Release asset boundary regression failed: $1" >&2
  exit 1
}

"$VERIFIER" "$SOURCE" >/dev/null \
  || fail "the production asset assembler did not pass its layout boundary."

remove_and_reject() {
  local fixture_name=$1
  local needle=$2
  local fixture="$TEMP_DIR/$fixture_name.sh"
  /usr/bin/awk -v needle="$needle" 'index($0, needle) == 0 { print }' \
    "$SOURCE" >"$fixture"
  if "$VERIFIER" "$fixture" >"$TEMP_DIR/stdout" 2>"$TEMP_DIR/stderr"; then
    fail "$fixture_name was accepted."
  fi
}

remove_and_reject missing-app-receipt-copy \
  '/bin/cp "$APP_NOTARY_RECORD" "$APP_NOTARY_ASSET"'
remove_and_reject missing-dmg-receipt-copy \
  '/bin/cp "$DMG_NOTARY_RECORD" "$DMG_NOTARY_ASSET"'
remove_and_reject missing-app-receipt-asset '  "$APP_NOTARY_ASSET"'
remove_and_reject missing-dmg-receipt-asset '  "$DMG_NOTARY_ASSET"'
remove_and_reject missing-checksum-assembler \
  '"$ROOT_DIR/Scripts/write-release-checksums.sh"'

echo "Release asset boundary regression passed."
