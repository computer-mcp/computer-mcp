#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
REPOSITORY=${RELEASE_REPOSITORY:-$ROOT_DIR}
TAG=${RELEASE_TAG:-${GITHUB_REF_NAME:-}}

fail() {
  echo "Release tag restoration failed: $1" >&2
  exit 1
}

[[ "$TAG" =~ '^v[0-9]+\.[0-9]+\.[0-9]+$' ]] \
  || fail "RELEASE_TAG must use the exact vMAJOR.MINOR.PATCH form."
git -C "$REPOSITORY" remote get-url origin >/dev/null 2>&1 \
  || fail "The repository has no origin remote."

tag_ref="refs/tags/$TAG"
head_commit=$(git -C "$REPOSITORY" rev-parse HEAD)

# actions/checkout fetches the annotated object and then, for tag-triggered
# workflows, force-updates the local tag ref to GITHUB_SHA. Fetch the exact
# remote tag ref again so signature verification sees the immutable tag object.
git -C "$REPOSITORY" fetch \
  --force \
  --no-tags \
  origin \
  "+$tag_ref:$tag_ref"

[[ $(git -C "$REPOSITORY" cat-file -t "$tag_ref" 2>/dev/null) == "tag" ]] \
  || fail "$TAG was not restored as an annotated tag object."
[[ $(git -C "$REPOSITORY" rev-parse "$tag_ref^{}") == "$head_commit" ]] \
  || fail "$TAG does not point to the checked-out commit."

echo "Restored annotated release tag $TAG from origin."
