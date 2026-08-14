#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
PACKAGE_SCRIPT=${1:-"$ROOT_DIR/Scripts/package-dmg.sh"}

fail() {
  echo "DMG signing boundary verification failed: $1" >&2
  exit 1
}

[[ -f "$PACKAGE_SCRIPT" ]] || fail "package script is missing."

line_for() {
  local needle=$1
  local count
  local line
  count=$(/usr/bin/grep -Fxc "$needle" "$PACKAGE_SCRIPT" || true)
  [[ "$count" == "1" ]] || fail "expected exactly one line: $needle"
  line=$(/usr/bin/grep -Fnx "$needle" "$PACKAGE_SCRIPT" | /usr/bin/cut -d: -f1)
  print -r -- "$line"
}

CREATE_LINE=$(line_for '/usr/sbin/diskutil image create from \')
SIGN_LINE=$(line_for '  /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp --identifier "$DMG_SIGNING_IDENTIFIER" "$DMG_PATH"')
VERIFY_LINE=$(line_for '  /usr/bin/codesign --verify --strict --verbose=2 "$DMG_PATH"')
RECORD_LINE=$(line_for '  print -r -- "$DMG_SIGNATURE" | "$ROOT_DIR/Scripts/verify-developer-id-signature-record.sh" "$EXPECTED_TEAM_ID" "DMG" "$DMG_SIGNING_IDENTIFIER"')
SUBMIT_LINE=$(line_for '  submit_for_notarization "$DMG_PATH" "$DMG_NOTARY_RECORD" "DMG"')

[[ "$CREATE_LINE" -lt "$SIGN_LINE" \
  && "$SIGN_LINE" -lt "$VERIFY_LINE" \
  && "$VERIFY_LINE" -lt "$RECORD_LINE" \
  && "$RECORD_LINE" -lt "$SUBMIT_LINE" ]] \
  || fail "DMG must be created, Developer ID signed, verified, and only then notarized."

echo "DMG signing boundary passed."
