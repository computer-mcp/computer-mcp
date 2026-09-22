#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
python3 "$ROOT_DIR/Scripts/version.py" check
VERSION=$(python3 "$ROOT_DIR/Scripts/version.py" show --field version)
EXPECTED_REPOSITORY=${EXPECTED_GITHUB_REPOSITORY:-computer-mcp/computer-mcp}

fail() {
  echo "CI release failed: $1" >&2
  exit 1
}

[[ ${GITHUB_ACTIONS:-false} == "true" ]] \
  || fail "Official releases are supported only by GitHub Actions."
[[ ${GITHUB_REPOSITORY:-} == "$EXPECTED_REPOSITORY" ]] \
  || fail "Unexpected GitHub repository: ${GITHUB_REPOSITORY:-missing}."
"$ROOT_DIR/Scripts/verify-candidate-ref.sh"
[[ -n ${SIGNING_IDENTITY:-} ]] || fail "SIGNING_IDENTITY is required."
[[ -n ${EXPECTED_TEAM_ID:-} ]] || fail "EXPECTED_TEAM_ID is required."
[[ -n ${PROVISIONING_PROFILE:-} ]] || fail "PROVISIONING_PROFILE is required."
[[ -z ${NOTARY_KEYCHAIN_PROFILE:-} ]] \
  || fail "GitHub releases use a Team API key, not a personal Keychain profile."
for variable in ASC_API_KEY_PATH ASC_API_KEY_ID ASC_API_ISSUER_ID; do
  value=${(P)variable}
  [[ -n "$value" ]] || fail "$variable is required."
done

"$ROOT_DIR/Scripts/verify-release-readiness.sh"

APP_ENVIRONMENT=production \
  RELEASE_MODE=1 \
  REUSE_EXISTING_SLICES=0 \
  SOURCE_COMMIT="$GITHUB_SHA" \
  SIGNING_IDENTITY="$SIGNING_IDENTITY" \
  EXPECTED_TEAM_ID="$EXPECTED_TEAM_ID" \
  PROVISIONING_PROFILE="$PROVISIONING_PROFILE" \
  "$ROOT_DIR/Scripts/build-app.sh"

RELEASE_MODE=1 \
  SIGNING_IDENTITY="$SIGNING_IDENTITY" \
  EXPECTED_TEAM_ID="$EXPECTED_TEAM_ID" \
  ASC_API_KEY_PATH="$ASC_API_KEY_PATH" \
  ASC_API_KEY_ID="$ASC_API_KEY_ID" \
  ASC_API_ISSUER_ID="$ASC_API_ISSUER_ID" \
  "$ROOT_DIR/Scripts/package-dmg.sh"

RELEASE_MODE=1 \
  EXPECTED_TEAM_ID="$EXPECTED_TEAM_ID" \
  "$ROOT_DIR/Scripts/verify-distribution.sh"

python3 "$ROOT_DIR/Scripts/candidate.py" bundle

echo "CI release candidate is ready: dist/Computer-MCP-$VERSION-universal.dmg"
