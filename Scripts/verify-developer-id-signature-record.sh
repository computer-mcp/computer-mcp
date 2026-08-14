#!/bin/zsh
set -euo pipefail

EXPECTED_TEAM_ID=${1:-}
ARTIFACT_NAME=${2:-Artifact}
EXPECTED_IDENTIFIER=${3:-}
SIGNATURE_RECORD=$(/bin/cat)

fail() {
  echo "Developer ID signature verification failed: $1" >&2
  exit 1
}

[[ "$EXPECTED_TEAM_ID" =~ '^[[:alnum:]]{10}$' ]] \
  || fail "EXPECTED_TEAM_ID has an invalid format."
if [[ -n "$EXPECTED_IDENTIFIER" ]]; then
  [[ "$EXPECTED_IDENTIFIER" =~ '^[[:alnum:]][[:alnum:].-]+$' ]] \
    || fail "EXPECTED_IDENTIFIER has an invalid format."
fi
[[ -n "$SIGNATURE_RECORD" ]] || fail "$ARTIFACT_NAME has no signature record."

AUTHORITY_COUNT=$(print -r -- "$SIGNATURE_RECORD" \
  | /usr/bin/grep -Ec '^Authority=Developer ID Application:.+$' || true)
TEAM_COUNT=$(print -r -- "$SIGNATURE_RECORD" \
  | /usr/bin/grep -Fxc "TeamIdentifier=$EXPECTED_TEAM_ID" || true)
TIMESTAMP_COUNT=$(print -r -- "$SIGNATURE_RECORD" \
  | /usr/bin/grep -Ec '^Timestamp=.+$' || true)
if [[ -n "$EXPECTED_IDENTIFIER" ]]; then
  IDENTIFIER_COUNT=$(print -r -- "$SIGNATURE_RECORD" \
    | /usr/bin/grep -Fxc "Identifier=$EXPECTED_IDENTIFIER" || true)
else
  IDENTIFIER_COUNT=1
fi

[[ "$AUTHORITY_COUNT" == "1" ]] \
  || fail "$ARTIFACT_NAME must have exactly one Developer ID Application authority."
[[ "$TEAM_COUNT" == "1" ]] \
  || fail "$ARTIFACT_NAME Team ID does not match EXPECTED_TEAM_ID."
[[ "$TIMESTAMP_COUNT" == "1" ]] \
  || fail "$ARTIFACT_NAME must have exactly one secure timestamp."
[[ "$IDENTIFIER_COUNT" == "1" ]] \
  || fail "$ARTIFACT_NAME signing identifier does not match EXPECTED_IDENTIFIER."

echo "$ARTIFACT_NAME Developer ID signature record passed."
