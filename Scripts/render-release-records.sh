#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
OUTPUT_DIR=${OUTPUT_DIR:-"$ROOT_DIR/dist"}
VERSION=$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleShortVersionString' \
  "$ROOT_DIR/Resources/ComputerMCPApp/Info.plist")
RELEASE_NOTES_TEMPLATE="$ROOT_DIR/Documentation/Reference/ReleaseNotes-$VERSION.md"
READINESS_TEMPLATE="$ROOT_DIR/Documentation/Reference/ProductionReadinessReport-$VERSION.md"
RELEASE_NOTES="$OUTPUT_DIR/Computer-MCP-$VERSION-ReleaseNotes.md"
READINESS_REPORT="$OUTPUT_DIR/Computer-MCP-$VERSION-ProductionReadiness.md"

fail() {
  echo "Release record rendering failed: $1" >&2
  exit 1
}

required_variables=(
  RELEASE_DATE
  RELEASE_COMMIT
  RELEASE_TAG
  RELEASE_TAG_OBJECT
  EXPECTED_TEAM_ID
  APP_ARCHITECTURES
  EMBEDDED_CLI_SHA256
  DMG_SHA256
  APP_NOTARY_SUBMISSION_ID
  DMG_NOTARY_SUBMISSION_ID
  GITHUB_RUN_URL
)
for variable in $required_variables; do
  value=${(P)variable:-}
  [[ -n "$value" ]] || fail "$variable is required."
done

[[ "$RELEASE_DATE" =~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' ]] \
  || fail "RELEASE_DATE must use YYYY-MM-DD."
[[ "$RELEASE_COMMIT" =~ '^[0-9a-f]{40,64}$' ]] \
  || fail "RELEASE_COMMIT is not a Git object ID."
[[ "$RELEASE_TAG" == "v$VERSION" ]] \
  || fail "RELEASE_TAG does not match product version $VERSION."
[[ "$RELEASE_TAG_OBJECT" =~ '^[0-9a-f]{40,64}$' ]] \
  || fail "RELEASE_TAG_OBJECT is not a Git object ID."
[[ "$EXPECTED_TEAM_ID" =~ '^[A-Z0-9]{10}$' ]] \
  || fail "EXPECTED_TEAM_ID has an invalid format."
[[ " $APP_ARCHITECTURES " == *' arm64 '* \
  && " $APP_ARCHITECTURES " == *' x86_64 '* ]] \
  || fail "APP_ARCHITECTURES must contain arm64 and x86_64."
[[ "$EMBEDDED_CLI_SHA256" =~ '^[0-9a-f]{64}$' ]] \
  || fail "EMBEDDED_CLI_SHA256 is not SHA-256."
[[ "$DMG_SHA256" =~ '^[0-9a-f]{64}$' ]] \
  || fail "DMG_SHA256 is not SHA-256."
for submission_id in "$APP_NOTARY_SUBMISSION_ID" "$DMG_NOTARY_SUBMISSION_ID"; do
  [[ "$submission_id" =~ \
    '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' ]] \
    || fail "Notarization submission ID is not a UUID."
done
[[ "$GITHUB_RUN_URL" == https://github.com/*/actions/runs/* ]] \
  || fail "GITHUB_RUN_URL is not a GitHub Actions run URL."

for template in "$RELEASE_NOTES_TEMPLATE" "$READINESS_TEMPLATE"; do
  [[ -s "$template" ]] || fail "Missing release record template: $template"
done
/bin/mkdir -p "$OUTPUT_DIR"
/bin/cp "$RELEASE_NOTES_TEMPLATE" "$RELEASE_NOTES"
/bin/cp "$READINESS_TEMPLATE" "$READINESS_REPORT"

replace_token() {
  local record_path=$1
  local token=$2
  local value=$3
  local temporary
  temporary=$(mktemp "$OUTPUT_DIR/.release-record.XXXXXX")
  /usr/bin/awk -v token="$token" -v value="$value" \
    '{ gsub(token, value); print }' "$record_path" >"$temporary"
  /bin/mv -f "$temporary" "$record_path"
}

tokens=(
  __RELEASE_DATE__
  __RELEASE_COMMIT__
  __RELEASE_TAG__
  __RELEASE_TAG_OBJECT__
  __APPLE_TEAM_ID__
  __APP_ARCHITECTURES__
  __EMBEDDED_CLI_SHA256__
  __DMG_SHA256__
  __APP_NOTARY_SUBMISSION_ID__
  __DMG_NOTARY_SUBMISSION_ID__
  __GITHUB_RUN_URL__
)
values=(
  "$RELEASE_DATE"
  "$RELEASE_COMMIT"
  "$RELEASE_TAG"
  "$RELEASE_TAG_OBJECT"
  "$EXPECTED_TEAM_ID"
  "$APP_ARCHITECTURES"
  "$EMBEDDED_CLI_SHA256"
  "$DMG_SHA256"
  "$APP_NOTARY_SUBMISSION_ID"
  "$DMG_NOTARY_SUBMISSION_ID"
  "$GITHUB_RUN_URL"
)

for record_path in "$RELEASE_NOTES" "$READINESS_REPORT"; do
  for index in {1..${#tokens}}; do
    token=${tokens[$index]}
    value=${values[$index]}
    rg -q --fixed-strings "$token" "$record_path" \
      || fail "Template ${record_path:t} is missing $token."
    replace_token "$record_path" "$token" "$value"
  done
  if rg -q '__[A-Z0-9_]+__|\bPending\b|intentionally blank|NOT READY' "$record_path"; then
    fail "Rendered release record still contains an unfinished marker: ${record_path:t}"
  fi
done

rg -q "^# Computer MCP $VERSION Release Notes$" "$RELEASE_NOTES" \
  || fail "Rendered release notes title does not match $VERSION."
rg -q "^# Computer MCP $VERSION Production Readiness Report$" "$READINESS_REPORT" \
  || fail "Rendered readiness title does not match $VERSION."

echo "Rendered release records for $RELEASE_TAG."
