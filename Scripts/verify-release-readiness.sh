#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
VERSION=$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleShortVersionString' \
  "$ROOT_DIR/Resources/ComputerMCPApp/Info.plist")
RELEASE_NOTES="$ROOT_DIR/Documentation/Reference/ReleaseNotes-$VERSION.md"
READINESS_REPORT="$ROOT_DIR/Documentation/Reference/ProductionReadinessReport-$VERSION.md"

fail() {
  echo "Release readiness verification failed: $1" >&2
  exit 1
}

for input_path in \
  "$ROOT_DIR/LICENSE" \
  "$ROOT_DIR/EULA.md" \
  "$ROOT_DIR/PRIVACY.md" \
  "$RELEASE_NOTES" \
  "$READINESS_REPORT"
do
  [[ -s "$input_path" ]] || fail "Missing or empty release input: $input_path"
done

if /usr/bin/grep -Eiq \
  'release-candidate legal draft|legal review (is|are )?required before publication' \
  "$ROOT_DIR/LICENSE" "$ROOT_DIR/EULA.md" "$ROOT_DIR/PRIVACY.md"
then
  fail "Legal files still contain draft or review-required markers."
fi
if /usr/bin/grep -Eiq \
  '(^|[^[:alnum:]_])Pending([^[:alnum:]_]|$)|intentionally blank|NOT READY' \
  "$RELEASE_NOTES" "$READINESS_REPORT"
then
  fail "Release record templates still contain obsolete pending markers."
fi
if /usr/bin/grep -Eiq \
  'public [0-9]+\.[0-9]+\.[0-9]+ release is still pending' \
  "$ROOT_DIR/README.md" "$ROOT_DIR/README.zh-CN.md"
then
  fail "Root README files still describe the release as pending."
fi

/usr/bin/grep -Eq "^# Computer MCP $VERSION Release Notes$" "$RELEASE_NOTES" \
  || fail "Release notes title does not match $VERSION."
/usr/bin/grep -Eq \
  "^# Computer MCP $VERSION Production Readiness Report$" "$READINESS_REPORT" \
  || fail "Production readiness title does not match $VERSION."

expected_tokens=(
  __APPLE_TEAM_ID__
  __APP_ARCHITECTURES__
  __APP_NOTARY_SUBMISSION_ID__
  __DMG_NOTARY_SUBMISSION_ID__
  __DMG_SHA256__
  __EMBEDDED_CLI_SHA256__
  __GITHUB_RUN_URL__
  __RELEASE_COMMIT__
  __RELEASE_DATE__
  __RELEASE_TAG__
  __RELEASE_TAG_OBJECT__
)
expected_token_set=$(printf '%s\n' $expected_tokens | LC_ALL=C /usr/bin/sort)
for input_path in "$RELEASE_NOTES" "$READINESS_REPORT"; do
  for token in $expected_tokens; do
    /usr/bin/grep -Fq "$token" "$input_path" \
      || fail "${input_path:t} is missing required render token $token."
  done
  discovered_token_set=$(/usr/bin/grep -Eo '__[A-Z0-9_]+__' "$input_path" \
    | LC_ALL=C /usr/bin/sort -u)
  [[ "$discovered_token_set" == "$expected_token_set" ]] \
    || fail "${input_path:t} contains an unexpected release render token."
done

echo "Release prerequisite templates passed for $VERSION."
