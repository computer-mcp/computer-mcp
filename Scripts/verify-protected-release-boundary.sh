#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
WORKFLOW="$ROOT_DIR/.github/workflows/release-gate.yml"
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/computer-mcp-protected-release.XXXXXX")

cleanup() {
  /bin/rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "Protected release boundary verification failed: $1" >&2
  exit 1
}

# GitHub jobs never share a filesystem. Extract the protected job so a tool
# installed by the preceding no-secret job cannot accidentally satisfy it.
/usr/bin/awk '
  /^  release:$/ { in_release = 1 }
  in_release { print }
' "$WORKFLOW" >"$TEMP_DIR/release-job.yml"
[[ -s "$TEMP_DIR/release-job.yml" ]] \
  || fail "Unable to locate the protected release job."

protected_scripts=(
  Scripts/restore-release-tag.sh
  Scripts/release-ci.sh
  Scripts/verify-release-ref.sh
  Scripts/verify-release-readiness.sh
  Scripts/build-app.sh
  Scripts/verify-localization.sh
  Scripts/package-dmg.sh
  Scripts/write-artifact-provenance.sh
  Scripts/verify-artifact-provenance.sh
  Scripts/verify-artifact-provenance-boundary.sh
  Scripts/verify-developer-id-signature-record.sh
  Scripts/verify-notarization-record.sh
  Scripts/verify-distribution.sh
  Scripts/assemble-release-assets.sh
  Scripts/write-release-checksums.sh
  Scripts/render-release-records.sh
  Scripts/generate-release-metadata.swift
)

protected_paths=()
for relative_path in $protected_scripts; do
  [[ -f "$ROOT_DIR/$relative_path" ]] \
    || fail "Missing protected release input: $relative_path"
  protected_paths+=("$ROOT_DIR/$relative_path")
done
if [[ -n ${PROTECTED_RELEASE_TEST_ADDITIONAL_PATHS:-} ]]; then
  for test_path in ${(f)PROTECTED_RELEASE_TEST_ADDITIONAL_PATHS}; do
    [[ -f "$test_path" ]] || fail "Missing boundary test input: $test_path"
    protected_paths+=("$test_path")
  done
fi

if /usr/bin/grep -En \
  '(^|[^[:alnum:]_])(rg|ripgrep)([^[:alnum:]_]|$)|(^|[[:space:]])brew[[:space:]]+(install|upgrade)([[:space:]]|$)' \
  "$TEMP_DIR/release-job.yml" \
  "${protected_paths[@]}"
then
  fail "Protected release execution must not depend on Homebrew or ripgrep."
else
  scan_status=$?
  [[ "$scan_status" == "1" ]] \
    || fail "Unable to scan the complete protected release execution path."
fi

required_commands=(
  'test -x /usr/bin/grep'
  '/usr/bin/jq --version'
  '/usr/bin/security help'
  'xcrun notarytool --version'
)
for command_text in $required_commands; do
  /usr/bin/grep -Fq "$command_text" "$TEMP_DIR/release-job.yml" \
    || fail "Protected runner preflight is missing: $command_text"
done

echo "Protected release boundary passed: no Homebrew or ripgrep dependency."
