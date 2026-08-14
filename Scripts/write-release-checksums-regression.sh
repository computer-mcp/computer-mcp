#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/computer-mcp-release-assets.XXXXXX")
OUTPUT_DIR="$TEMP_ROOT/dist"
VERIFIER="$ROOT_DIR/Scripts/write-release-checksums.sh"

cleanup() {
  /bin/rm -rf -- "$TEMP_ROOT"
}
trap cleanup EXIT

fail() {
  echo "Release checksum regression failed: $1" >&2
  exit 1
}

/bin/mkdir -p "$OUTPUT_DIR/ReleaseMetadata"
/usr/bin/printf '%s\n' app >"$OUTPUT_DIR/Computer-MCP-AppNotary.json"
/usr/bin/printf '%s\n' dmg >"$OUTPUT_DIR/Computer-MCP-DMGNotary.json"
/usr/bin/printf '%s\n' nested >"$OUTPUT_DIR/ReleaseMetadata/Nested.json"
/usr/bin/printf '%s\n' outside >"$TEMP_ROOT/Outside.json"

"$VERIFIER" \
  "$OUTPUT_DIR" \
  "$OUTPUT_DIR/SHA256SUMS" \
  "$OUTPUT_DIR/Computer-MCP-DMGNotary.json" \
  "$OUTPUT_DIR/Computer-MCP-AppNotary.json" \
  >"$TEMP_ROOT/stdout"
(
  cd "$OUTPUT_DIR"
  /usr/bin/shasum -a 256 -c SHA256SUMS >/dev/null
) || fail "a valid root-level asset set did not verify."
FIRST_NAME=$(/usr/bin/awk 'NR == 1 { print $2 }' "$OUTPUT_DIR/SHA256SUMS")
[[ "$FIRST_NAME" == "Computer-MCP-AppNotary.json" ]] \
  || fail "checksum entries are not deterministic."

expect_reject() {
  local fixture_name=$1
  local expected=$2
  shift 2
  if "$VERIFIER" "$@" >"$TEMP_ROOT/stdout" 2>"$TEMP_ROOT/stderr"; then
    fail "$fixture_name was accepted."
  fi
  /usr/bin/grep -Fq "$expected" "$TEMP_ROOT/stderr" \
    || fail "$fixture_name did not produce the expected diagnostic."
}

expect_reject nested-asset \
  'every release asset must be copied directly into the output directory' \
  "$OUTPUT_DIR" "$OUTPUT_DIR/SHA256SUMS" \
  "$OUTPUT_DIR/ReleaseMetadata/Nested.json"
expect_reject outside-asset \
  'every release asset must be copied directly into the output directory' \
  "$OUTPUT_DIR" "$OUTPUT_DIR/SHA256SUMS" "$TEMP_ROOT/Outside.json"
expect_reject missing-asset \
  'release asset is missing or a symlink' \
  "$OUTPUT_DIR" "$OUTPUT_DIR/SHA256SUMS" "$OUTPUT_DIR/Missing.json"
expect_reject duplicate-asset \
  'duplicate release asset name' \
  "$OUTPUT_DIR" "$OUTPUT_DIR/SHA256SUMS" \
  "$OUTPUT_DIR/Computer-MCP-AppNotary.json" \
  "$OUTPUT_DIR/Computer-MCP-AppNotary.json"
expect_reject misplaced-checksum \
  'SHA256SUMS must be written directly inside the output directory' \
  "$OUTPUT_DIR" "$TEMP_ROOT/SHA256SUMS" \
  "$OUTPUT_DIR/Computer-MCP-AppNotary.json"

/bin/ln -s "$OUTPUT_DIR/Computer-MCP-AppNotary.json" "$OUTPUT_DIR/ReceiptLink.json"
expect_reject symlink-asset \
  'release asset is missing or a symlink' \
  "$OUTPUT_DIR" "$OUTPUT_DIR/SHA256SUMS" "$OUTPUT_DIR/ReceiptLink.json"

echo "Release checksum regression passed."
