#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
ARTIFACT_PATH=${1:-}
RECEIPT_PATH=${2:-}
ARTIFACT_CLASS=${3:-}

fail() {
  echo "Artifact provenance failed: $1" >&2
  exit 1
}

[[ -f "$ARTIFACT_PATH" && ! -L "$ARTIFACT_PATH" ]] \
  || fail "artifact must be a regular non-symlink file."
[[ -n "$RECEIPT_PATH" && "${RECEIPT_PATH:h}" == "${ARTIFACT_PATH:h}" ]] \
  || fail "receipt must be written beside the artifact."
[[ -n ${SOURCE_COMMIT:-} && "$SOURCE_COMMIT" =~ '^[0-9a-f]{40}$' ]] \
  || fail "SOURCE_COMMIT must be a full lowercase Git commit."
[[ -n ${BUILD_IDENTITY:-} && "$BUILD_IDENTITY" =~ '^[A-Za-z0-9._-]{1,200}$' ]] \
  || fail "BUILD_IDENTITY is missing or unsafe."

artifact_name=${ARTIFACT_PATH:t}
artifact_sha256=$(/usr/bin/shasum -a 256 "$ARTIFACT_PATH" | /usr/bin/awk '{print $1}')
artifact_size=$(/usr/bin/stat -f '%z' "$ARTIFACT_PATH")
creation_phase=${CREATION_PHASE:-$ARTIFACT_CLASS}
release_tag=${RELEASE_TAG:-}
release_commit=${RELEASE_COMMIT:-$SOURCE_COMMIT}
app_notarization_state=${APP_NOTARIZATION_STATE:-not_requested}
dmg_notarization_state=${DMG_NOTARIZATION_STATE:-not_requested}
app_notarization_id=${APP_NOTARIZATION_ID:-}
dmg_notarization_id=${DMG_NOTARIZATION_ID:-}
app_staple_state=${APP_STAPLE_STATE:-not_applied}
dmg_staple_state=${DMG_STAPLE_STATE:-not_applied}
published_asset_sha256=${PUBLISHED_ASSET_SHA256:-}
byte_identical=${BYTE_IDENTICAL_TO_PUBLISHED_ASSET:-false}
[[ -n ${BUILD_IDENTITY_PATH:-} \
  && -f "$BUILD_IDENTITY_PATH" \
  && ! -L "$BUILD_IDENTITY_PATH" ]] \
  || fail "BUILD_IDENTITY_PATH must be a regular non-symlink file."
build_identity_sha256=$(/usr/bin/shasum -a 256 "$BUILD_IDENTITY_PATH" \
  | /usr/bin/awk '{print $1}')

case "$ARTIFACT_CLASS" in
  development)
    [[ "$artifact_name" == *-development-* ]] \
      || fail "development artifact names must contain '-development-'."
    [[ -z "$release_tag" ]] || fail "development artifacts cannot bind a release tag."
    ;;
  validation)
    [[ "$artifact_name" == *-validation-* ]] \
      || fail "validation artifact names must contain '-validation-'."
    [[ -z "$release_tag" ]] || fail "validation artifacts cannot bind a release tag."
    ;;
  release_candidate)
    [[ -n "$release_tag" && "$release_tag" == v* ]] \
      || fail "release candidates require RELEASE_TAG."
    [[ "$release_commit" == "$SOURCE_COMMIT" ]] \
      || fail "release candidate commit binding differs from SOURCE_COMMIT."
    [[ "$app_notarization_state" == accepted && "$dmg_notarization_state" == accepted ]] \
      || fail "release candidates require accepted App and DMG notarization."
    [[ "$app_staple_state" == validated && "$dmg_staple_state" == validated ]] \
      || fail "release candidates require validated App and DMG staples."
    [[ -n "$app_notarization_id" && -n "$dmg_notarization_id" ]] \
      || fail "release candidates require App and DMG notarization submission IDs."
    ;;
  exact_published_release)
    [[ -n "$release_tag" && "$release_tag" == v* ]] \
      || fail "published artifacts require RELEASE_TAG."
    [[ "$release_commit" == "$SOURCE_COMMIT" ]] \
      || fail "published artifact commit binding differs from SOURCE_COMMIT."
    [[ "$app_notarization_state" == accepted && "$dmg_notarization_state" == accepted ]] \
      || fail "published artifacts require accepted App and DMG notarization."
    [[ "$app_staple_state" == validated && "$dmg_staple_state" == validated ]] \
      || fail "published artifacts require validated App and DMG staples."
    [[ -n "$app_notarization_id" && -n "$dmg_notarization_id" ]] \
      || fail "published artifacts require App and DMG notarization submission IDs."
    [[ "$published_asset_sha256" == "$artifact_sha256" ]] \
      || fail "published asset checksum differs from the local exact artifact."
    [[ "$byte_identical" == true ]] \
      || fail "published artifacts require a successful byte-identity comparison."
    ;;
  *)
    fail "ARTIFACT_CLASS must be development, validation, release_candidate, or exact_published_release."
    ;;
esac

[[ "$byte_identical" == true || "$byte_identical" == false ]] \
  || fail "BYTE_IDENTICAL_TO_PUBLISHED_ASSET must be true or false."
[[ -z "$published_asset_sha256" || "$published_asset_sha256" =~ '^[0-9a-f]{64}$' ]] \
  || fail "PUBLISHED_ASSET_SHA256 must be empty or SHA-256."

/bin/mkdir -p "${RECEIPT_PATH:h}"
temporary_receipt=$(mktemp "${RECEIPT_PATH:h}/.artifact-provenance.XXXXXX")
cleanup() {
  /bin/rm -f -- "$temporary_receipt"
}
trap cleanup EXIT

/usr/bin/jq -n \
  --arg artifact_name "$artifact_name" \
  --arg artifact_class "$ARTIFACT_CLASS" \
  --arg creation_phase "$creation_phase" \
  --arg source_commit "$SOURCE_COMMIT" \
  --arg build_identity "$BUILD_IDENTITY" \
  --arg build_identity_sha256 "$build_identity_sha256" \
  --arg artifact_sha256 "$artifact_sha256" \
  --argjson artifact_size "$artifact_size" \
  --arg release_tag "$release_tag" \
  --arg release_commit "$release_commit" \
  --arg app_notarization_state "$app_notarization_state" \
  --arg dmg_notarization_state "$dmg_notarization_state" \
  --arg app_notarization_id "$app_notarization_id" \
  --arg dmg_notarization_id "$dmg_notarization_id" \
  --arg app_staple_state "$app_staple_state" \
  --arg dmg_staple_state "$dmg_staple_state" \
  --arg published_asset_sha256 "$published_asset_sha256" \
  --argjson byte_identical "$byte_identical" \
  '{
    schema_version: 1,
    artifact: {
      name: $artifact_name,
      class: $artifact_class,
      creation_phase: $creation_phase,
      sha256: $artifact_sha256,
      size_bytes: $artifact_size
    },
    source: {
      commit: $source_commit,
      build_identity: $build_identity,
      build_identity_sha256: $build_identity_sha256
    },
    notarization: {
      app: {state: $app_notarization_state, submission_id: (if $app_notarization_id == "" then null else $app_notarization_id end)},
      dmg: {state: $dmg_notarization_state, submission_id: (if $dmg_notarization_id == "" then null else $dmg_notarization_id end)}
    },
    stapling: {
      app: $app_staple_state,
      dmg: $dmg_staple_state
    },
    release: {
      tag: (if $release_tag == "" then null else $release_tag end),
      commit: (if $release_tag == "" then null else $release_commit end)
    },
    published_asset: {
      sha256: (if $published_asset_sha256 == "" then null else $published_asset_sha256 end),
      byte_identical: $byte_identical
    }
  }' >"$temporary_receipt"

/usr/bin/jq -e . "$temporary_receipt" >/dev/null
/bin/chmod 644 "$temporary_receipt"
/bin/mv -f -- "$temporary_receipt" "$RECEIPT_PATH"
trap - EXIT
echo "Artifact provenance receipt: $RECEIPT_PATH"
