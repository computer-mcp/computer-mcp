#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/computer-mcp-dmg-signing.XXXXXX")
VERIFIER="$ROOT_DIR/Scripts/verify-dmg-signing-boundary.sh"
SOURCE="$ROOT_DIR/Scripts/package-dmg.sh"

cleanup() {
  /bin/rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "DMG signing boundary regression failed: $1" >&2
  exit 1
}

"$VERIFIER" "$SOURCE" >/dev/null \
  || fail "the production package script did not pass its signing boundary."

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

remove_and_reject missing-sign \
  '/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp --identifier "$DMG_SIGNING_IDENTIFIER" "$WORKING_DMG_PATH"'
remove_and_reject missing-timestamp ' --timestamp --identifier "$DMG_SIGNING_IDENTIFIER"'
remove_and_reject missing-identifier ' --identifier "$DMG_SIGNING_IDENTIFIER"'
remove_and_reject missing-record \
  'print -r -- "$DMG_SIGNATURE" | "$ROOT_DIR/Scripts/verify-developer-id-signature-record.sh"'

/usr/bin/awk '
  /codesign --force --sign "\$SIGNING_IDENTITY" --timestamp --identifier "\$DMG_SIGNING_IDENTIFIER" "\$WORKING_DMG_PATH"/ {
    sign_line = $0
    next
  }
  { print }
  /submit_for_notarization "\$WORKING_DMG_PATH"/ { print sign_line }
' "$SOURCE" >"$TEMP_DIR/wrong-order.sh"
if "$VERIFIER" "$TEMP_DIR/wrong-order.sh" >"$TEMP_DIR/stdout" 2>"$TEMP_DIR/stderr"; then
  fail "a DMG signed after notarization was accepted."
fi
/usr/bin/grep -Fq 'DMG must be created, Developer ID signed, verified, and only then notarized.' \
  "$TEMP_DIR/stderr" || fail "wrong ordering did not produce the expected diagnostic."

echo "DMG signing boundary regression passed."
