#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
python3 "$ROOT_DIR/Scripts/version.py" check
VERSION=$(python3 "$ROOT_DIR/Scripts/version.py" show --field version)
RELEASE_NOTES="$ROOT_DIR/Scripts/ReleaseTemplates/ReleaseNotes.md"
READINESS_REPORT="$ROOT_DIR/Scripts/ReleaseTemplates/ProductionReadinessReport.md"

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

CHANGES=$(/usr/bin/awk -v heading="## $VERSION — " '
  index($0, heading) == 1 { found = 1; next }
  found && /^## / { exit }
  found && NF { print }
' "$ROOT_DIR/CHANGELOG.md")
[[ -n "$CHANGES" ]] || fail "CHANGELOG.md has no entries for $VERSION."

/usr/bin/grep -Eq '^# Computer MCP __VERSION__ Release Notes$' "$RELEASE_NOTES" \
  || fail "Release notes title does not use the version token."
/usr/bin/grep -Eq \
  '^# Computer MCP __VERSION__ Production Readiness Report$' "$READINESS_REPORT" \
  || fail "Production readiness title does not use the version token."
/usr/bin/grep -Eq '^__CHANGES__$' "$RELEASE_NOTES" \
  || fail "Release notes template has no changelog line."

record_tokens=(
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
  __VERSION__
)
for spec in "$RELEASE_NOTES:__CHANGES__" "$READINESS_REPORT:__BUILD__"; do
  input_path=${spec%%:*}
  expected_tokens=($record_tokens ${spec##*:})
  expected_token_set=$(printf '%s\n' $expected_tokens | LC_ALL=C /usr/bin/sort)
  discovered_token_set=$(/usr/bin/grep -Eo '__[A-Z0-9_]+__' "$input_path" \
    | LC_ALL=C /usr/bin/sort -u)
  [[ "$discovered_token_set" == "$expected_token_set" ]] \
    || fail "${input_path:t} must contain exactly its release render tokens."
done

echo "Release prerequisite templates passed for $VERSION."
