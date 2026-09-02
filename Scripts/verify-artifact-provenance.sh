#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
RECEIPT_PATH=${1:-}
ARTIFACT_PATH=${2:-}
EXPECTED_CLASS=${3:-}

fail() {
  echo "Artifact provenance verification failed: $1" >&2
  exit 1
}

[[ -f "$RECEIPT_PATH" && ! -L "$RECEIPT_PATH" ]] \
  || fail "receipt must be a regular non-symlink file."
[[ -f "$ARTIFACT_PATH" && ! -L "$ARTIFACT_PATH" ]] \
  || fail "artifact must be a regular non-symlink file."
/usr/bin/jq -e \
  '.schema_version == 1
   and (.artifact.name | type == "string")
   and (.artifact.class | type == "string")
   and (.artifact.creation_phase | type == "string")
   and (.artifact.sha256 | test("^[0-9a-f]{64}$"))
   and (.artifact.size_bytes | type == "number")
   and (.source.commit | test("^[0-9a-f]{40}$"))
   and (.source.build_identity | type == "string")
   and (.source.build_identity_sha256 | test("^[0-9a-f]{64}$"))
   and (.published_asset.byte_identical | type == "boolean")' \
  "$RECEIPT_PATH" >/dev/null \
  || fail "receipt schema or required identity fields are invalid."

artifact_name=${ARTIFACT_PATH:t}
actual_sha256=$(/usr/bin/shasum -a 256 "$ARTIFACT_PATH" | /usr/bin/awk '{print $1}')
actual_size=$(/usr/bin/stat -f '%z' "$ARTIFACT_PATH")
receipt_name=$(/usr/bin/jq -er '.artifact.name' "$RECEIPT_PATH")
receipt_class=$(/usr/bin/jq -er '.artifact.class' "$RECEIPT_PATH")
receipt_sha256=$(/usr/bin/jq -er '.artifact.sha256' "$RECEIPT_PATH")
receipt_size=$(/usr/bin/jq -er '.artifact.size_bytes' "$RECEIPT_PATH")
source_commit=$(/usr/bin/jq -er '.source.commit' "$RECEIPT_PATH")
build_identity_sha256=$(/usr/bin/jq -er '.source.build_identity_sha256' "$RECEIPT_PATH")
release_tag=$(/usr/bin/jq -r '.release.tag // empty' "$RECEIPT_PATH")
release_commit=$(/usr/bin/jq -r '.release.commit // empty' "$RECEIPT_PATH")

[[ "$receipt_name" == "$artifact_name" ]] || fail "artifact filename binding differs."
[[ "$receipt_class" == "$EXPECTED_CLASS" ]] || fail "artifact class differs."
[[ "$receipt_sha256" == "$actual_sha256" ]] || fail "artifact checksum differs."
[[ "$receipt_size" == "$actual_size" ]] || fail "artifact size differs."
[[ -n ${BUILD_IDENTITY_PATH:-} \
  && -f "$BUILD_IDENTITY_PATH" \
  && ! -L "$BUILD_IDENTITY_PATH" ]] \
  || fail "BUILD_IDENTITY_PATH must identify the regular signed build identity."
actual_build_identity_sha256=$(/usr/bin/shasum -a 256 "$BUILD_IDENTITY_PATH" \
  | /usr/bin/awk '{print $1}')
[[ "$build_identity_sha256" == "$actual_build_identity_sha256" ]] \
  || fail "signed build identity checksum differs."
identity_source_commit=$(/usr/bin/plutil -extract source_commit raw -o - "$BUILD_IDENTITY_PATH") \
  || fail "signed build identity has no source commit."
[[ "$identity_source_commit" == "$source_commit" ]] \
  || fail "signed build identity source commit differs."

case "$receipt_class" in
  development)
    [[ "$artifact_name" == *-development-* ]] \
      || fail "development artifact has a final-release-looking name."
    [[ -z "$release_tag" && -z "$release_commit" ]] \
      || fail "development artifact unexpectedly binds a release."
    ;;
  validation)
    [[ "$artifact_name" == *-validation-* ]] \
      || fail "validation artifact has a final-release-looking name."
    [[ -z "$release_tag" && -z "$release_commit" ]] \
      || fail "validation artifact unexpectedly binds a release."
    ;;
  release_candidate|exact_published_release)
    [[ "$release_tag" == v* && "$release_commit" == "$source_commit" ]] \
      || fail "release tag and commit binding is invalid."
    [[ $(/usr/bin/jq -r '.notarization.app.state' "$RECEIPT_PATH") == accepted \
      && $(/usr/bin/jq -r '.notarization.dmg.state' "$RECEIPT_PATH") == accepted ]] \
      || fail "release notarization is not accepted."
    [[ -n $(/usr/bin/jq -r '.notarization.app.submission_id // empty' "$RECEIPT_PATH") \
      && -n $(/usr/bin/jq -r '.notarization.dmg.submission_id // empty' "$RECEIPT_PATH") ]] \
      || fail "release notarization submission IDs are missing."
    [[ $(/usr/bin/jq -r '.stapling.app' "$RECEIPT_PATH") == validated \
      && $(/usr/bin/jq -r '.stapling.dmg' "$RECEIPT_PATH") == validated ]] \
      || fail "release staples are not validated."
    if [[ ${VERIFY_GIT_TAG:-0} == 1 ]]; then
      [[ $(git -C "$ROOT_DIR" rev-parse "$release_tag^{}") == "$source_commit" ]] \
        || fail "signed release tag does not resolve to the receipt commit."
    fi
    ;;
  *)
    fail "unknown artifact class."
    ;;
esac

if [[ "$receipt_class" == exact_published_release ]]; then
  [[ $(/usr/bin/jq -r '.published_asset.byte_identical' "$RECEIPT_PATH") == true ]] \
    || fail "published byte identity was not proven."
  [[ $(/usr/bin/jq -r '.published_asset.sha256' "$RECEIPT_PATH") == "$actual_sha256" ]] \
    || fail "published asset checksum differs."
fi

echo "Artifact provenance verification passed: $artifact_name ($receipt_class)"
