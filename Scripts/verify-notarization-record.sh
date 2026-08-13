#!/bin/zsh
set -euo pipefail

fail() {
  echo "Notarization record verification failed: $1" >&2
  exit 1
}

[[ "$#" == "2" ]] \
  || fail "usage: verify-notarization-record.sh <record.json> <artifact-name>"

RECORD_PATH=$1
ARTIFACT_NAME=$2
[[ -s "$RECORD_PATH" ]] || fail "$ARTIFACT_NAME result is missing or empty."

NOTARIZATION_STATUS=$(/usr/bin/jq -er '.status | strings' "$RECORD_PATH") \
  || fail "$ARTIFACT_NAME result has no string status."
SUBMISSION_ID=$(/usr/bin/jq -er '.id | strings' "$RECORD_PATH") \
  || fail "$ARTIFACT_NAME result has no string submission ID."

[[ "$NOTARIZATION_STATUS" == "Accepted" ]] \
  || fail "$ARTIFACT_NAME was not accepted: $NOTARIZATION_STATUS"
[[ "$SUBMISSION_ID" =~ \
  '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' ]] \
  || fail "$ARTIFACT_NAME submission ID is invalid."

/usr/bin/printf '%s\n' "$SUBMISSION_ID"
