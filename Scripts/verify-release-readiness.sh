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

if rg -q -i \
  'release-candidate legal draft|legal review (is|are )?required before publication' \
  "$ROOT_DIR/LICENSE" "$ROOT_DIR/EULA.md" "$ROOT_DIR/PRIVACY.md"
then
  fail "Legal files still contain draft or review-required markers."
fi
if rg -q -i \
  'Status:[[:space:]]*\*\*(NOT READY|release candidate)|\bPending\b|intentionally blank' \
  "$RELEASE_NOTES" "$READINESS_REPORT"
then
  fail "Release notes or readiness report still contain pending markers."
fi
if rg -q -i \
  'public [0-9]+\.[0-9]+\.[0-9]+ release is still pending' \
  "$ROOT_DIR/README.md" "$ROOT_DIR/README.zh-CN.md"
then
  fail "Root README files still describe the release as pending."
fi

rg -q "^# Computer MCP $VERSION Release Notes$" "$RELEASE_NOTES" \
  || fail "Release notes title does not match $VERSION."
rg -q "^# Computer MCP $VERSION Production Readiness Report$" "$READINESS_REPORT" \
  || fail "Production readiness title does not match $VERSION."

echo "Release readiness verification passed for $VERSION."
