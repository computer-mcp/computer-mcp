#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
TEMP_ROOT=$(mktemp -d)
trap 'find "$TEMP_ROOT" -depth -delete' EXIT

REMOTE="$TEMP_ROOT/remote.git"
SOURCE="$TEMP_ROOT/source"
CHECKOUT="$TEMP_ROOT/checkout"
TAG=v9.8.7

git init --quiet --bare "$REMOTE"
git init --quiet "$SOURCE"
git -C "$SOURCE" config user.name "Release Test"
git -C "$SOURCE" config user.email "release-test@example.invalid"
git -C "$SOURCE" commit --quiet --allow-empty -m "release fixture"
git -C "$SOURCE" tag -a "$TAG" -m "annotated release fixture"
git -C "$SOURCE" remote add origin "$REMOTE"
git -C "$SOURCE" push --quiet origin HEAD:refs/heads/master "refs/tags/$TAG"

git init --quiet "$CHECKOUT"
git -C "$CHECKOUT" remote add origin "$REMOTE"
git -C "$CHECKOUT" fetch --quiet origin \
  '+refs/heads/*:refs/remotes/origin/*' \
  '+refs/tags/*:refs/tags/*'

expected_tag_object=$(git -C "$CHECKOUT" rev-parse "refs/tags/$TAG")
release_commit=$(git -C "$CHECKOUT" rev-parse "refs/tags/$TAG^{}")
git -C "$CHECKOUT" checkout --quiet --detach "$release_commit"

# Reproduce actions/checkout's tag-event fetch, which overwrites the fetched
# annotated tag ref with the event's peeled commit SHA.
git -C "$CHECKOUT" update-ref "refs/tags/$TAG" "$release_commit"
[[ $(git -C "$CHECKOUT" cat-file -t "refs/tags/$TAG") == "commit" ]]

RELEASE_REPOSITORY="$CHECKOUT" \
  RELEASE_TAG="$TAG" \
  "$ROOT_DIR/Scripts/restore-release-tag.sh"

[[ $(git -C "$CHECKOUT" cat-file -t "refs/tags/$TAG") == "tag" ]]
[[ $(git -C "$CHECKOUT" rev-parse "refs/tags/$TAG") == "$expected_tag_object" ]]
[[ $(git -C "$CHECKOUT" rev-parse "refs/tags/$TAG^{}") == "$release_commit" ]]

echo "Release tag restoration regression passed."
