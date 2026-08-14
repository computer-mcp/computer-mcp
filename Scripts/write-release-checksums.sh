#!/bin/zsh
set -euo pipefail

OUTPUT_DIR=${1:-}
CHECKSUM_PATH=${2:-}
typeset -a ASSETS=()
TEMP_CHECKSUM=""

fail() {
  echo "Release checksum assembly failed: $1" >&2
  exit 1
}

cleanup() {
  [[ -z "$TEMP_CHECKSUM" ]] || /bin/rm -f -- "$TEMP_CHECKSUM"
}
trap cleanup EXIT

[[ $# -ge 3 && -n "$OUTPUT_DIR" && -n "$CHECKSUM_PATH" ]] \
  || fail "usage: write-release-checksums.sh <output-dir> <checksum-path> <asset>..."
shift 2
ASSETS=("$@")
[[ -d "$OUTPUT_DIR" ]] || fail "output directory is missing."
OUTPUT_DIR=${OUTPUT_DIR:A}
CHECKSUM_PATH=${CHECKSUM_PATH:A}
[[ ${CHECKSUM_PATH:h} == "$OUTPUT_DIR" ]] \
  || fail "SHA256SUMS must be written directly inside the output directory."

typeset -A SEEN_NAMES=()
for asset in "${ASSETS[@]}"; do
  [[ -f "$asset" && ! -L "$asset" ]] || fail "release asset is missing or a symlink: $asset"
  asset=${asset:A}
  [[ ${asset:h} == "$OUTPUT_DIR" ]] \
    || fail "every release asset must be copied directly into the output directory: $asset"
  name=${asset:t}
  [[ "$name" != *[[:space:]]* ]] \
    || fail "release asset names must not contain whitespace: $name"
  [[ -z ${SEEN_NAMES[$name]:-} ]] || fail "duplicate release asset name: $name"
  SEEN_NAMES[$name]=1
done

TEMP_CHECKSUM=$(mktemp "$OUTPUT_DIR/.SHA256SUMS.XXXXXX")
for asset in ${(on)ASSETS}; do
  asset=${asset:A}
  digest=$(/usr/bin/shasum -a 256 "$asset" | /usr/bin/awk '{print $1}')
  [[ "$digest" =~ '^[0-9a-f]{64}$' ]] || fail "unable to hash release asset: $asset"
  /usr/bin/printf '%s  %s\n' "$digest" "${asset:t}" >>"$TEMP_CHECKSUM"
done
[[ -s "$TEMP_CHECKSUM" ]] || fail "SHA256SUMS would be empty."
/bin/mv -f "$TEMP_CHECKSUM" "$CHECKSUM_PATH"
TEMP_CHECKSUM=""
(
  cd "$OUTPUT_DIR"
  /usr/bin/shasum -a 256 -c "${CHECKSUM_PATH:t}"
)

echo "Release checksum assembly passed: ${#ASSETS[@]} root-level assets."
