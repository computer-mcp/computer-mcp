#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
VERIFIER="$ROOT_DIR/Scripts/verify-developer-id-signature-record.sh"
EXPECTED_TEAM_ID=A7JC3DY3PU
EXPECTED_IDENTIFIER=com.showxu.computer-mcp.dmg
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/computer-mcp-signature-record.XXXXXX")

cleanup() {
  /bin/rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "Developer ID signature record regression failed: $1" >&2
  exit 1
}

ACCEPTED_RECORD='Authority=Developer ID Application: Example Developer (A7JC3DY3PU)
Authority=Developer ID Certification Authority
Authority=Apple Root CA
Timestamp=Aug 14, 2026 at 12:00:00
TeamIdentifier=A7JC3DY3PU
Identifier=com.showxu.computer-mcp.dmg'
print -r -- "$ACCEPTED_RECORD" \
  | "$VERIFIER" "$EXPECTED_TEAM_ID" DMG "$EXPECTED_IDENTIFIER" >/dev/null \
  || fail "a valid Developer ID signature record was rejected."

for fixture_name in missing-authority wrong-authority wrong-team missing-timestamp duplicate-timestamp missing-identifier wrong-identifier; do
  case "$fixture_name" in
    missing-authority)
      fixture=${ACCEPTED_RECORD//$'Authority=Developer ID Application: Example Developer (A7JC3DY3PU)\n'/}
      expected='must have exactly one Developer ID Application authority.'
      ;;
    wrong-authority)
      fixture=${ACCEPTED_RECORD/Developer ID Application/Apple Development}
      expected='must have exactly one Developer ID Application authority.'
      ;;
    wrong-team)
      fixture=${ACCEPTED_RECORD//A7JC3DY3PU/BBBBBBBBBB}
      expected='Team ID does not match EXPECTED_TEAM_ID.'
      ;;
    missing-timestamp)
      fixture=${ACCEPTED_RECORD//$'Timestamp=Aug 14, 2026 at 12:00:00\n'/}
      expected='must have exactly one secure timestamp.'
      ;;
    duplicate-timestamp)
      fixture="$ACCEPTED_RECORD"$'\nTimestamp=Aug 14, 2026 at 12:00:01'
      expected='must have exactly one secure timestamp.'
      ;;
    missing-identifier)
      fixture=${ACCEPTED_RECORD//$'\nIdentifier=com.showxu.computer-mcp.dmg'/}
      expected='signing identifier does not match EXPECTED_IDENTIFIER.'
      ;;
    wrong-identifier)
      fixture=${ACCEPTED_RECORD/com.showxu.computer-mcp.dmg/com.showxu.wrong.dmg}
      expected='signing identifier does not match EXPECTED_IDENTIFIER.'
      ;;
  esac
  if print -r -- "$fixture" \
    | "$VERIFIER" "$EXPECTED_TEAM_ID" DMG "$EXPECTED_IDENTIFIER" \
      >/dev/null 2>"$TEMP_DIR/stderr"
  then
    fail "$fixture_name was accepted."
  fi
  /usr/bin/grep -Fq "$expected" "$TEMP_DIR/stderr" \
    || fail "$fixture_name did not produce the expected diagnostic."
done

if print -r -- "$ACCEPTED_RECORD" \
  | "$VERIFIER" invalid DMG "$EXPECTED_IDENTIFIER" >/dev/null 2>&1
then
  fail "an invalid Team ID was accepted."
fi

if print -r -- "$ACCEPTED_RECORD" \
  | "$VERIFIER" "$EXPECTED_TEAM_ID" DMG 'invalid identifier' >/dev/null 2>&1
then
  fail "an invalid signing identifier was accepted."
fi

echo "Developer ID signature record regression passed."
