#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
INFO_PLIST="$ROOT_DIR/Resources/ComputerMCPApp/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")
SOURCE_VERSION=$(/usr/bin/sed -n \
  's/^[[:space:]]*package static let version = "\([^"]*\)"[[:space:]]*$/\1/p' \
  "$ROOT_DIR/Sources/ComputerMCP/ComputerMCPCLI.swift")
TAG=${RELEASE_TAG:-${GITHUB_REF_NAME:-"v$VERSION"}}
RELEASE_BRANCH=${RELEASE_BRANCH:-master}
REQUIRE_REMOTE_BRANCH=${REQUIRE_REMOTE_BRANCH:-0}

fail() {
  echo "Release ref verification failed: $1" >&2
  exit 1
}

[[ "$REQUIRE_REMOTE_BRANCH" == "0" || "$REQUIRE_REMOTE_BRANCH" == "1" ]] \
  || fail "REQUIRE_REMOTE_BRANCH must be 0 or 1."
[[ "$VERSION" == "$SOURCE_VERSION" ]] \
  || fail "App and CLI versions differ: App=$VERSION CLI=${SOURCE_VERSION:-missing}."
[[ "$TAG" =~ '^v[0-9]+\.[0-9]+\.[0-9]+$' ]] \
  || fail "Tag must use the exact vMAJOR.MINOR.PATCH form."
[[ "$TAG" == "v$VERSION" ]] || fail "$TAG does not match product version $VERSION."
[[ $(git -C "$ROOT_DIR" cat-file -t "$TAG" 2>/dev/null) == "tag" ]] \
  || fail "$TAG is not an annotated tag."
[[ $(git -C "$ROOT_DIR" rev-parse "$TAG^{}") == $(git -C "$ROOT_DIR" rev-parse HEAD) ]] \
  || fail "$TAG does not point to HEAD."
git -C "$ROOT_DIR" \
  -c gpg.format=ssh \
  -c gpg.ssh.allowedSignersFile="$ROOT_DIR/.github/signing-allowed-signers" \
  verify-tag "$TAG"

if [[ "$REQUIRE_REMOTE_BRANCH" == "1" ]]; then
  remote_ref="refs/remotes/origin/$RELEASE_BRANCH"
  git -C "$ROOT_DIR" show-ref --verify --quiet "$remote_ref" \
    || fail "Missing $remote_ref; fetch the release branch before verification."
  git -C "$ROOT_DIR" merge-base --is-ancestor HEAD "$remote_ref" \
    || fail "$TAG is not reachable from origin/$RELEASE_BRANCH."
fi

rg -q "^## $VERSION — [0-9]{4}-[0-9]{2}-[0-9]{2}$" "$ROOT_DIR/CHANGELOG.md" \
  || fail "CHANGELOG.md has no dated $VERSION section."
UNRELEASED_CONTENT=$(/usr/bin/awk '
  /^## Unreleased$/ { in_unreleased = 1; next }
  in_unreleased && /^## / { exit }
  in_unreleased && NF { print }
' "$ROOT_DIR/CHANGELOG.md")
[[ -z "$UNRELEASED_CONTENT" ]] || fail "CHANGELOG.md Unreleased must be empty."

if [[ ${GITHUB_ACTIONS:-false} == "true" ]]; then
  [[ ${GITHUB_REF_TYPE:-} == "tag" ]] || fail "GitHub release must run from a tag ref."
  [[ ${GITHUB_REF_NAME:-} == "$TAG" ]] || fail "GitHub ref name does not match $TAG."
  [[ ${GITHUB_SHA:-} == $(git -C "$ROOT_DIR" rev-parse HEAD) ]] \
    || fail "GITHUB_SHA does not match HEAD."
fi

if [[ "$REQUIRE_REMOTE_BRANCH" == "1" ]]; then
  echo "Release ref verification passed: $TAG on origin/$RELEASE_BRANCH."
else
  echo "Release ref verification passed: $TAG."
fi
