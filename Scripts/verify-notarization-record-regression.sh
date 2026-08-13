#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
TEMP_PARENT=${TMPDIR:-/tmp}
TEMP_PARENT=${TEMP_PARENT%/}
TEMP_ROOT=$(mktemp -d "$TEMP_PARENT/computer-mcp-notary-record.XXXXXX")
VERIFIER="$ROOT_DIR/Scripts/verify-notarization-record.sh"

cleanup() {
  case "$TEMP_ROOT" in
    "$TEMP_PARENT"/computer-mcp-notary-record.*)
      /bin/rm -rf -- "$TEMP_ROOT"
      ;;
  esac
}
trap cleanup EXIT

fail() {
  echo "Notarization record regression failed: $1" >&2
  exit 1
}

ACCEPTED_ID=11111111-2222-3333-4444-555555555555
/usr/bin/printf '%s\n' \
  "{\"id\":\"$ACCEPTED_ID\",\"status\":\"Accepted\"}" \
  >"$TEMP_ROOT/accepted.json"
ACTUAL_ID=$("$VERIFIER" "$TEMP_ROOT/accepted.json" App)
[[ "$ACTUAL_ID" == "$ACCEPTED_ID" ]] \
  || fail "an accepted response did not return its submission ID."

/usr/bin/printf '%s\n' \
  '{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","status":"Rejected"}' \
  >"$TEMP_ROOT/rejected.json"
if "$VERIFIER" "$TEMP_ROOT/rejected.json" DMG \
  >"$TEMP_ROOT/stdout" 2>"$TEMP_ROOT/stderr"
then
  fail "a rejected response was accepted."
fi
/usr/bin/grep -Fq 'DMG was not accepted: Rejected' "$TEMP_ROOT/stderr" \
  || fail "a rejected response did not produce the expected diagnostic."

for fixture_name in missing-id invalid-id missing-status invalid-json; do
  case "$fixture_name" in
    missing-id)
      fixture='{"status":"Accepted"}'
      expected='result has no string submission ID.'
      ;;
    invalid-id)
      fixture='{"id":"not-a-uuid","status":"Accepted"}'
      expected='submission ID is invalid.'
      ;;
    missing-status)
      fixture='{"id":"11111111-2222-3333-4444-555555555555"}'
      expected='result has no string status.'
      ;;
    invalid-json)
      fixture='{'
      expected='result has no string status.'
      ;;
  esac
  /usr/bin/printf '%s\n' "$fixture" >"$TEMP_ROOT/$fixture_name.json"
  if "$VERIFIER" "$TEMP_ROOT/$fixture_name.json" App \
    >"$TEMP_ROOT/stdout" 2>"$TEMP_ROOT/stderr"
  then
    fail "$fixture_name was accepted."
  fi
  /usr/bin/grep -Fq "$expected" "$TEMP_ROOT/stderr" \
    || fail "$fixture_name did not produce the expected diagnostic."
done

if /usr/bin/grep -En \
  '^[[:space:]]*(local|typeset)([[:space:]]+-[^[:space:]]+)*[[:space:]]+status([=[:space:]]|$)' \
  "$ROOT_DIR/Scripts/package-dmg.sh" "$VERIFIER"
then
  fail "a protected zsh script declares the read-only status parameter."
else
  scan_result=$?
  [[ "$scan_result" == "1" ]] || fail "unable to scan protected zsh scripts."
fi

echo "Notarization record regression passed."
