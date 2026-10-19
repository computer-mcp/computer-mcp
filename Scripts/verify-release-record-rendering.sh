#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
TEMP_PARENT=${TMPDIR:-/tmp}
TEMP_PARENT=${TEMP_PARENT%/}
TEMP_ROOT=$(mktemp -d "$TEMP_PARENT/computer-mcp-release-records.XXXXXX")

cleanup() {
  case "$TEMP_ROOT" in
    "$TEMP_PARENT"/computer-mcp-release-records.*)
      /bin/rm -rf -- "$TEMP_ROOT"
      ;;
  esac
}
trap cleanup EXIT

VERSION=$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleShortVersionString' \
  "$ROOT_DIR/Resources/ComputerMCPApp/Info.plist")
FIXTURE_ROOT="$TEMP_ROOT/source"
for source in \
  Version.json \
  Resources/ComputerMCPApp/Info.plist \
  Sources/ComputerMCPCore/ComputerMCPCLI.swift \
  Scripts/version.py \
  Scripts/render-release-records.sh \
  Scripts/ReleaseTemplates/ReleaseNotes.md \
  Scripts/ReleaseTemplates/ProductionReadinessReport.md
do
  /bin/mkdir -p "$FIXTURE_ROOT/${source:h}"
  /bin/cp "$ROOT_DIR/$source" "$FIXTURE_ROOT/$source"
done

render_records() {
  OUTPUT_DIR="$TEMP_ROOT" \
    RELEASE_DATE=2026-01-02 \
    RELEASE_COMMIT=1111111111111111111111111111111111111111 \
    RELEASE_TAG="v$VERSION" \
    RELEASE_TAG_OBJECT=2222222222222222222222222222222222222222 \
    EXPECTED_TEAM_ID=A7JC3DY3PU \
    APP_ARCHITECTURES='arm64 x86_64' \
    EMBEDDED_CLI_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    DMG_SHA256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    APP_NOTARY_SUBMISSION_ID=11111111-2222-3333-4444-555555555555 \
    DMG_NOTARY_SUBMISSION_ID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee \
    GITHUB_RUN_URL=https://github.com/computer-mcp/computer-mcp/actions/runs/123456 \
    "$FIXTURE_ROOT/Scripts/render-release-records.sh"
}

/usr/bin/printf '# Changelog\n\n## Unreleased\n' >"$FIXTURE_ROOT/CHANGELOG.md"
if render_records >"$TEMP_ROOT/stdout" 2>"$TEMP_ROOT/stderr"; then
  echo "Release record rendering accepted a changelog without release entries." >&2
  exit 1
fi
/usr/bin/grep -Fq "CHANGELOG.md has no entries for $VERSION." "$TEMP_ROOT/stderr"
first_change='- Validate synthetic release records.'
/usr/bin/printf '\n## %s — 2026-01-02\n\n%s\n' "$VERSION" "$first_change" \
  >>"$FIXTURE_ROOT/CHANGELOG.md"
render_records >/dev/null
RELEASE_NOTES="$TEMP_ROOT/Computer-MCP-$VERSION-ReleaseNotes.md"
READINESS_REPORT="$TEMP_ROOT/Computer-MCP-$VERSION-ProductionReadiness.md"
for output in "$RELEASE_NOTES" "$READINESS_REPORT"; do
  [[ -s "$output" ]]
  ! /usr/bin/grep -Eq \
    '__[A-Z0-9_]+__|(^|[^[:alnum:]_])Pending([^[:alnum:]_]|$)|intentionally blank|NOT READY' \
    "$output"
  /usr/bin/grep -Fq \
    '11111111-2222-3333-4444-555555555555' "$output"
  /usr/bin/grep -Fq \
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$output"
done
/usr/bin/grep -Fxq -- "$first_change" "$RELEASE_NOTES"

echo "Synthetic release record rendering passed for v$VERSION."
