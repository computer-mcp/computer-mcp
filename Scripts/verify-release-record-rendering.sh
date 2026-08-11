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
  "$ROOT_DIR/Scripts/render-release-records.sh" >/dev/null
RELEASE_NOTES="$TEMP_ROOT/Computer-MCP-$VERSION-ReleaseNotes.md"
READINESS_REPORT="$TEMP_ROOT/Computer-MCP-$VERSION-ProductionReadiness.md"
for output in "$RELEASE_NOTES" "$READINESS_REPORT"; do
  [[ -s "$output" ]]
  ! rg -q '__[A-Z0-9_]+__|\bPending\b|intentionally blank|NOT READY' "$output"
  rg -q --fixed-strings \
    '11111111-2222-3333-4444-555555555555' "$output"
  rg -q --fixed-strings \
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$output"
done

echo "Synthetic release record rendering passed for v$VERSION."
