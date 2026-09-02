#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
ASSEMBLER=${1:-"$ROOT_DIR/Scripts/assemble-release-assets.sh"}

fail() {
  echo "Release asset boundary verification failed: $1" >&2
  exit 1
}

[[ -f "$ASSEMBLER" ]] || fail "release asset assembler is missing."

line_for() {
  local needle=$1
  local count
  local line
  count=$(/usr/bin/grep -Fxc "$needle" "$ASSEMBLER" || true)
  [[ "$count" == "1" ]] || fail "expected exactly one line: $needle"
  line=$(/usr/bin/grep -Fnx "$needle" "$ASSEMBLER" | /usr/bin/cut -d: -f1)
  print -r -- "$line"
}

APP_COPY_LINE=$(line_for '/bin/cp "$APP_NOTARY_RECORD" "$APP_NOTARY_ASSET"')
DMG_COPY_LINE=$(line_for '/bin/cp "$DMG_NOTARY_RECORD" "$DMG_NOTARY_ASSET"')
ASSET_ARRAY_LINE=$(line_for 'assets=(')
APP_ASSET_LINE=$(line_for '  "$APP_NOTARY_ASSET"')
DMG_ASSET_LINE=$(line_for '  "$DMG_NOTARY_ASSET"')
CHECKSUM_LINE=$(line_for '"$ROOT_DIR/Scripts/write-release-checksums.sh" \')
PROVENANCE_VERIFY_LINE=$(line_for '  VERIFY_GIT_TAG=1 "$ROOT_DIR/Scripts/verify-artifact-provenance.sh" \')
PROVENANCE_ASSET_COUNT=$(/usr/bin/grep -Fxc '  "$ARTIFACT_PROVENANCE"' "$ASSEMBLER" || true)
[[ "$PROVENANCE_ASSET_COUNT" == "2" ]] \
  || fail "artifact provenance must be both a verified input and a checksummed upload asset."

[[ "$APP_COPY_LINE" -lt "$ASSET_ARRAY_LINE" \
  && "$DMG_COPY_LINE" -lt "$ASSET_ARRAY_LINE" \
  && "$ASSET_ARRAY_LINE" -lt "$APP_ASSET_LINE" \
  && "$ASSET_ARRAY_LINE" -lt "$DMG_ASSET_LINE" \
  && "$APP_ASSET_LINE" -lt "$CHECKSUM_LINE" \
  && "$DMG_ASSET_LINE" -lt "$CHECKSUM_LINE" \
  && "$PROVENANCE_VERIFY_LINE" -lt "$CHECKSUM_LINE" ]] \
  || fail "notarization receipts must be copied into the upload root before checksum assembly."

echo "Release asset boundary passed."
